import Foundation

/// One annotation on a capture.
///
/// A single struct with a kind, not a class hierarchy. Shottr's binary shows 14
/// `Obj*` classes behind one `ProtoObject` protocol, which is the shape you get
/// after years of features. Snapr has 6 kinds and they differ only in how they
/// draw, so a hierarchy would be three files of ceremony around one switch.
public struct Annotation: Identifiable, Equatable, Sendable, Codable {

    public enum Kind: String, Sendable, Codable, CaseIterable {
        case arrow
        case box
        case text
        case counter
        case blur
        case highlight

        public var label: String {
            switch self {
            case .arrow: return "Arrow"
            case .box: return "Box"
            case .text: return "Text"
            case .counter: return "Step"
            case .blur: return "Blur"
            case .highlight: return "Highlight"
            }
        }

        /// Single-key shortcuts in the editor. Chosen to avoid the arrow keys,
        /// which are the pixel-nudge feature.
        public var shortcut: String {
            switch self {
            case .arrow: return "a"
            case .box: return "b"
            case .text: return "t"
            case .counter: return "s"
            case .blur: return "e"
            case .highlight: return "h"
            }
        }
    }

    public var id: UUID
    public var kind: Kind
    /// For arrow, `from` and `to` are the two ends. For everything else they
    /// are opposite corners of the bounding box.
    public var from: PixelPoint
    public var to: PixelPoint
    public var colour: SRGB
    public var lineWidth: Int
    /// Text content, for `.text`. Never written to any log.
    public var text: String
    /// Step number, for `.counter`. Assigned by `AnnotationStack`.
    public var counterValue: Int
    public var fontSize: Int

    public init(id: UUID = UUID(),
                kind: Kind,
                from: PixelPoint,
                to: PixelPoint,
                colour: SRGB = SRGB(r: 255, g: 59, b: 48),
                lineWidth: Int = 4,
                text: String = "",
                counterValue: Int = 0,
                fontSize: Int = 28) {
        self.id = id
        self.kind = kind
        self.from = from
        self.to = to
        self.colour = colour
        self.lineWidth = lineWidth
        self.text = text
        self.counterValue = counterValue
        self.fontSize = fontSize
    }

    public var boundingBox: PixelRect {
        PixelRect(x0: min(from.x, to.x), y0: min(from.y, to.y),
                  x1: max(from.x, to.x) + 1, y1: max(from.y, to.y) + 1)
    }

    /// Hit testing with slop, so a thin arrow is still clickable.
    public func hitTest(_ p: PixelPoint, slop: Int = 8) -> Bool {
        switch kind {
        case .arrow:
            return distanceToSegment(p, from, to) <= Double(lineWidth + slop)
        case .box, .blur, .highlight, .text, .counter:
            return boundingBox.inset(by: -slop).contains(p)
        }
    }

    private func distanceToSegment(_ p: PixelPoint, _ a: PixelPoint, _ b: PixelPoint) -> Double {
        let dx = Double(b.x - a.x), dy = Double(b.y - a.y)
        let lenSq = dx * dx + dy * dy
        if lenSq == 0 {
            return hypot(Double(p.x - a.x), Double(p.y - a.y))
        }
        var t = (Double(p.x - a.x) * dx + Double(p.y - a.y) * dy) / lenSq
        t = max(0, min(1, t))
        let cx = Double(a.x) + t * dx, cy = Double(a.y) + t * dy
        return hypot(Double(p.x) - cx, Double(p.y) - cy)
    }

    public mutating func translate(dx: Int, dy: Int) {
        from.x += dx; from.y += dy
        to.x += dx; to.y += dy
    }
}

/// The annotation list with undo and redo.
///
/// Undo stores whole snapshots rather than inverse operations. A capture holds
/// a handful of annotations, so a snapshot is a few hundred bytes, and inverse
/// operations are where undo bugs live.
public struct AnnotationStack: Equatable, Sendable {
    public private(set) var annotations: [Annotation] = []
    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []
    private let maxUndo = 64

    public init() {}

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// Next step number. Counts only counters that are still present, so
    /// deleting step 2 of 3 renumbers rather than leaving a gap.
    public var nextCounterValue: Int {
        annotations.filter { $0.kind == .counter }.count + 1
    }

    private mutating func checkpoint() {
        undoStack.append(annotations)
        if undoStack.count > maxUndo { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    public mutating func add(_ a: Annotation) {
        checkpoint()
        var a = a
        if a.kind == .counter && a.counterValue == 0 {
            a.counterValue = nextCounterValue
        }
        annotations.append(a)
    }

    public mutating func remove(id: UUID) {
        guard annotations.contains(where: { $0.id == id }) else { return }
        checkpoint()
        annotations.removeAll { $0.id == id }
        renumberCounters()
    }

    public mutating func update(_ a: Annotation) {
        guard let i = annotations.firstIndex(where: { $0.id == a.id }) else { return }
        checkpoint()
        annotations[i] = a
    }

    /// Update without a checkpoint, for the many intermediate states of a drag.
    /// Call `beginInteractive` once at mouse-down instead.
    public mutating func updateInteractive(_ a: Annotation) {
        guard let i = annotations.firstIndex(where: { $0.id == a.id }) else { return }
        annotations[i] = a
    }

    public mutating func beginInteractive() { checkpoint() }

    public mutating func clear() {
        guard !annotations.isEmpty else { return }
        checkpoint()
        annotations.removeAll()
    }

    public mutating func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(annotations)
        annotations = previous
    }

    public mutating func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotations)
        annotations = next
    }

    /// Topmost hit wins, because that is what the user can see.
    public func hitTest(_ p: PixelPoint, slop: Int = 8) -> Annotation? {
        annotations.reversed().first { $0.hitTest(p, slop: slop) }
    }

    private mutating func renumberCounters() {
        var n = 1
        for i in annotations.indices where annotations[i].kind == .counter {
            annotations[i].counterValue = n
            n += 1
        }
    }
}
