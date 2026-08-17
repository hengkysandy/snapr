import AppKit
import Carbon.HIToolbox
import Foundation
import SnaprCore

/// Global hotkeys, through Carbon.
///
/// MEASURED (probe A6) with `AXIsProcessTrusted() == false` confirmed in the
/// same run: `RegisterEventHotKey` returned noErr and the hotkey fired.
/// **Carbon global hotkeys need no Accessibility grant.** Snapr asks the user
/// for Screen Recording and nothing else, which is one permission dialog
/// instead of two.
///
/// MEASURED in the same run: registering the same combination twice returns
/// `-9878`. Registration is exclusive, so a shortcut another app already holds
/// simply fails. That status is returned per action rather than swallowed, so
/// the settings UI can tell the user which shortcut is taken instead of showing
/// a binding that quietly never fires.
///
/// Two harness facts worth keeping, both of which produced "registration
/// returned noErr, no key arrived", which looks exactly like a permission
/// failure:
///
/// - Carbon hotkey events dispatch inside NSApplication's own loop.
///   `Task.sleep` and a hand-pumped `RunLoop.run(mode:before:)` both fail to
///   deliver them. `NSApp.run()` is required.
/// - `osascript ... keystroke` does NOT trigger a Carbon hotkey. A posted
///   `CGEvent` does. Any UI test driving a shortcut must post a CGEvent.
@MainActor
final class HotkeyManager {

    /// The status `RegisterEventHotKey` returns when the combination is already
    /// held by something else. MEASURED (probe A6).
    nonisolated static let alreadyRegistered: OSStatus = -9878

    /// `'SNPR'`. The signature scopes our hotkey ids so they cannot collide
    /// with another framework's inside the same application event target.
    private static let signature = OSType(0x534E5052)

    private let onAction: (HotkeyAction) -> Void
    private var refs: [EventHotKeyRef] = []
    /// Our own ids, so `unregisterAll` cleans up the shared dispatch table and
    /// does not strand entries belonging to a manager that was replaced.
    private var ownedIDs: [UInt32] = []
    private var handlerInstalled = false

    init(onAction: @escaping (HotkeyAction) -> Void) {
        self.onAction = onAction
    }

    /// Register every shortcut and report what happened to each one.
    @discardableResult
    func register(_ hotkeys: [HotkeyAction: HotkeySpec]) -> [HotkeyAction: OSStatus] {
        unregisterAll()
        installHandlerIfNeeded()

        var results: [HotkeyAction: OSStatus] = [:]
        // Sorted so the same conflicting set always fails on the same action.
        // Without an order, two actions bound to one combination would take
        // turns winning between launches and the settings UI would flicker.
        for action in hotkeys.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let spec = hotkeys[action] else { continue }
            let id = HotkeyDispatch.reserveID()
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(spec.keyCode, spec.modifiers,
                                             EventHotKeyID(signature: Self.signature, id: id),
                                             GetApplicationEventTarget(), 0, &ref)
            results[action] = status
            if status == noErr, let ref {
                refs.append(ref)
                ownedIDs.append(id)
                HotkeyDispatch.handlers[id] = { [weak self] in self?.onAction(action) }
            } else {
                HotkeyDispatch.release(id)
                // Loud, and never swallowed. A binding that silently does not
                // exist is indistinguishable from a broken app.
                Log.hotkey.error("""
                    register failed action=\(action.rawValue, privacy: .public) \
                    status=\(status, privacy: .public)\
                    \(status == Self.alreadyRegistered ? " (combination already taken)" : "", privacy: .public)
                    """)
            }
        }
        let ok = results.values.filter { $0 == noErr }.count
        Log.hotkey.info("registered \(ok, privacy: .public) of \(results.count, privacy: .public)")
        return results
    }

    func unregisterAll() {
        for ref in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
        for id in ownedIDs { HotkeyDispatch.release(id) }
        ownedIDs.removeAll()
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        // The C callback is a plain function pointer, so it cannot capture
        // anything. Swift 6 also rejects reading plain global mutable state
        // from it. Both problems are solved the same way: the state lives on
        // the main actor, and the callback hops into that isolation with
        // `MainActor.assumeIsolated`. This is sound because Carbon dispatches
        // hotkey events on the main thread, inside NSApplication's own loop.
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotkeyID = EventHotKeyID()
            let status = GetEventParameter(event,
                                           EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID),
                                           nil,
                                           MemoryLayout<EventHotKeyID>.size,
                                           nil,
                                           &hotkeyID)
            guard status == noErr else { return status }
            MainActor.assumeIsolated {
                HotkeyDispatch.fire(hotkeyID)
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// The bridge between a C function pointer and Swift concurrency.
///
/// It is a type and not a property of `HotkeyManager` because the Carbon
/// callback has no `self` to reach through. Everything here is main-actor
/// isolated, which is what makes `MainActor.assumeIsolated` in the callback a
/// statement of fact rather than a hope.
@MainActor
private enum HotkeyDispatch {
    static var handlers: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1

    static func reserveID() -> UInt32 {
        let id = nextID
        nextID &+= 1
        // Zero is a usable id but reads like "unset" in a log line, so it is
        // skipped rather than debugged later.
        if nextID == 0 { nextID = 1 }
        return id
    }

    static func release(_ id: UInt32) {
        handlers[id] = nil
    }

    static func fire(_ hotkeyID: EventHotKeyID) {
        guard let handler = handlers[hotkeyID.id] else {
            // Another component in the process may own this hotkey. Not an
            // error, but silence here would hide a stale registration.
            Log.hotkey.debug("hotkey id=\(hotkeyID.id, privacy: .public) has no handler")
            return
        }
        handler()
    }
}
