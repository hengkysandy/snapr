import CoreGraphics
import Foundation
import SnaprCore
import Vision

/// Reads text out of every capture, in the background, one at a time.
///
/// MEASURED (probe A8): `.accurate` recognition on a full 2940x1912 capture is
/// **206 ms median** and 174 MB peak resident. That is far too slow to run
/// inline with a capture, so it never does. The user gets the editor at once
/// and the row carries an `OCRState` until this service catches up.
///
/// The service itself is `@MainActor`, so its queue, its callback and its
/// running flag need no lock. All the Vision work runs in a detached task off
/// the main actor, and `isProcessing` keeps exactly one shot in flight, which
/// is what keeps the 174 MB a peak rather than a multiple of it.
///
/// **API note.** This uses the modern value-type Vision API
/// (`RecognizeTextRequest`, `DetectBarcodesRequest`, `ImageRequestHandler`),
/// not the older `VNRecognizeTextRequest` classes. Two reasons, both measured:
/// `minimumTextHeightFraction` only exists on the value-type API (the class API
/// spells the same thing `minimumTextHeight`), and every number in probe A8 and
/// A10 was measured through this API.
@MainActor
final class OCRService {

    /// Called on the main actor after each shot reaches a terminal state, so
    /// the history window can refresh one row.
    var onFinished: ((UUID, OCRState) -> Void)?

    private let library: Library

    private var isRunning = false
    /// One pass at a time, on purpose. Two concurrent `.accurate` passes would
    /// double a 174 MB peak for no throughput gain, because Vision is already
    /// using the whole neural engine for one of them.
    private var isProcessing = false
    /// Kept in order, with a set beside it so `enqueue` cannot add the same id
    /// twice while it waits.
    private var pending: [UUID] = []
    private var queued: Set<UUID> = []
    /// The shot currently in flight. The startup sweep runs asynchronously, so
    /// without this an id can be swept up while it is already being processed,
    /// and the row would flip back to `.running` after it had finished.
    private var inFlight: UUID?

    /// How many unfinished rows to pick up at startup in one go.
    private let startupBatch = 500

    init(library: Library) {
        self.library = library
    }

    /// Starts the worker and picks up anything already unfinished.
    ///
    /// The startup sweep is not optional. A crash in the middle of a Vision
    /// pass leaves a row in `.running`, and without this sweep that row would
    /// stay unsearchable forever while looking perfectly normal in the grid.
    func start() {
        guard !isRunning else { return }
        isRunning = true

        let library = self.library
        let batch = startupBatch
        Task.detached(priority: .utility) {
            let ids = (try? library.pendingOCR(limit: batch)) ?? []
            await MainActor.run { [weak self] in
                guard let self else { return }
                Log.ocr.info("startup sweep queued \(ids.count, privacy: .public) shots")
                for id in ids { self.enqueue(id) }
            }
        }
        pump()
    }

    /// Stops taking new work. A pass already in flight finishes and writes its
    /// result, because abandoning it would leave the row stuck in `.running`.
    func stop() {
        isRunning = false
    }

    func enqueue(_ id: UUID) {
        guard !queued.contains(id), inFlight != id else { return }
        queued.insert(id)
        pending.append(id)
        pump()
    }

    // MARK: - Private

    private func pump() {
        guard isRunning, !isProcessing, !pending.isEmpty else { return }
        let id = pending.removeFirst()
        queued.remove(id)
        isProcessing = true
        inFlight = id

        let library = self.library
        Task.detached(priority: .utility) {
            let outcome = await OCRService.process(id: id, library: library)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isProcessing = false
                self.inFlight = nil
                self.onFinished?(id, outcome)
                self.pump()
            }
        }
    }

    /// Runs one shot end to end, off the main actor. `nonisolated static` so it
    /// cannot reach main-actor state by accident.
    private nonisolated static func process(id: UUID, library: Library) async -> OCRState {
        // Already finished, so do nothing. The startup sweep reads its list
        // asynchronously, and by the time that list arrives a shot on it may
        // already have been read. Without this check the row would flip back to
        // `.running`, which shows in the history window as a finished shot
        // becoming unfinished again.
        do {
            let current = try library.shot(id: id).ocrState
            if current.isTerminal { return current }
        } catch {
            Log.ocr.error("could not read shot before ocr: \(String(describing: error), privacy: .public)")
            return .failed
        }

        // Mark the row before the slow part, so a crash is visible as
        // `.running` and the startup sweep can pick it up again.
        do {
            try library.setOCR(id: id, state: .running, text: nil, barcodes: [])
        } catch {
            Log.ocr.error("could not mark shot running: \(String(describing: error), privacy: .public)")
            return .failed
        }

        let started = CFAbsoluteTimeGetCurrent()
        do {
            // The decode is wrapped in an autoreleasepool because the decoded
            // image is most of the 174 MB and it must be gone before the next
            // shot starts.
            let image: CGImage = try autoreleasepool {
                let png = try library.fullPNG(id: id)
                guard let decoded = ImageBridge.image(from: png) else {
                    throw OCRError.imageDecodeFailed
                }
                return decoded
            }

            let result = try await OCRService.recognise(image)
            let elapsed = CFAbsoluteTimeGetCurrent() - started

            // `.noTextFound` and `.failed` are deliberately different answers.
            // One is a blank screenshot, the other is a bug to look at. Folding
            // them together is the exact shape of the bug this app avoids.
            let state: OCRState = result.text.isEmpty ? .noTextFound : .done
            try library.setOCR(id: id,
                               state: state,
                               text: result.text.isEmpty ? nil : result.text,
                               barcodes: result.barcodes)
            // Counts and durations only. Redact.text gives a character count,
            // never the characters.
            Log.ocr.info("""
                ocr \(state.rawValue, privacy: .public) \
                lines=\(result.lineCount, privacy: .public) \
                text=\(Redact.text(result.text), privacy: .public) \
                barcodes=\(result.barcodes.count, privacy: .public) \
                in \(Redact.ms(elapsed), privacy: .public)
                """)
            return state
        } catch {
            // Vision errors carry a reason, never capture content, so the kind
            // is safe to log and is the only useful thing here.
            Log.ocr.error("ocr failed: \(String(describing: error), privacy: .public)")
            try? library.setOCR(id: id, state: .failed, text: nil, barcodes: [])
            return .failed
        }
    }

    private enum OCRError: Error {
        case imageDecodeFailed
    }

    private struct Recognition {
        var text: String
        var lineCount: Int
        var barcodes: [String]
    }

    /// One `ImageRequestHandler`, two requests.
    ///
    /// MEASURED (probe A10): adding barcode detection to the handler that is
    /// already doing text costs **+4.2 ms, 2.2%**. A deliberate
    /// black-and-white noise block returned nothing, so the detector does not
    /// hallucinate a QR out of noise. It is always on.
    private nonisolated static func recognise(_ image: CGImage) async throws -> Recognition {
        var textRequest = RecognizeTextRequest()

        // 0.1.0 runs `.accurate` only. MEASURED (A8): 206 ms median against
        // 19 ms for `.fast`, but `.fast` scores 18/22 whole lines against
        // 22/22. The two-tier arrangement is affordable and is deliberately
        // deferred, because it doubles the state machine.
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = true

        // MEASURED (probe A8), and this single line is the difference between
        // working OCR and none at all. The default is 0.03125 (one thirty
        // second). On a 1912 px tall screenshot that demands about 60 px of
        // glyph height, while macOS UI text at 2x backing scale is 22 to 34 px.
        //
        // With the default, recognition returns ZERO observations, zero
        // characters and confidence 0.000, and reports no error. It looks
        // exactly like an image with no text in it. Lowering the floor also
        // took `.accurate` from 21/22 to a clean 22/22 on the fixture.
        //
        // Do not remove this line and do not restore the default.
        textRequest.minimumTextHeightFraction = 0.005

        let barcodeRequest = DetectBarcodesRequest()

        let handler = ImageRequestHandler(image)
        let (textResults, barcodeResults) = try await handler.perform(textRequest, barcodeRequest)

        var lines: [String] = []
        lines.reserveCapacity(textResults.count)
        for observation in textResults {
            // Top candidate only. The alternatives are for a correction UI that
            // 0.1.0 does not have, and indexing them would multiply the stored
            // text for no search benefit.
            if let best = observation.topCandidates(1).first, !best.string.isEmpty {
                lines.append(best.string)
            }
        }

        let barcodes = barcodeResults.compactMap { $0.payloadString }

        return Recognition(text: lines.joined(separator: "\n"),
                           lineCount: lines.count,
                           barcodes: barcodes)
    }
}
