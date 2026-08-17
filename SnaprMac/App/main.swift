import AppKit

// No @main and no @NSApplicationMain.
//
// MEASURED on the capture probe: Carbon global hotkey events are dispatched
// inside NSApplication's own event loop. Neither `Task.sleep` nor a hand-pumped
// `RunLoop.current.run(mode:before:)` delivers them, and both failure modes
// look exactly like a permission problem: registration returns noErr and no key
// ever arrives. `NSApplication.shared.run()` is the only thing that works.
//
// Writing the entry point out by hand keeps that visible.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Accessory, not regular. Snapr lives in the menu bar and must not steal focus
// from the window the user is about to capture.
app.setActivationPolicy(.accessory)
app.run()
