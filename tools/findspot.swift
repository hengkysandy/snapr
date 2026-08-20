// Find a point where a named app really is the FRONTMOST window.
//
// Build:  swiftc -O -parse-as-library tools/findspot.swift -o /tmp/findspot
// Use:    /tmp/findspot Chrome        ->  "470 476", or "NONE"
//
// Why this exists. Half the measurements taken while building scrolling capture
// were wrong, and every one was wrong the same way: something else was in front
// of the window being measured. A synthetic scroll goes to whatever window is
// under the pointer, not to whatever has focus, so a probe that clicks at a
// guessed point and hopes will happily measure the wrong application and report
// it as a bug in this one. It did, for an hour.
//
// `SCShareableContent` lists windows that have no visible pixels at all, so
// enumerating it is not enough either. This walks the list in z-order and
// returns a point that no window ahead of the target covers.
//
// Not part of the app. Nothing in Snapr links this.

import Foundation
import ScreenCaptureKit
@main struct P {
    static func main() async {
        let want = CommandLine.arguments[1]
        guard let c = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        else { print("NONE"); return }
        let ws = c.windows.filter { $0.frame.width > 300 && $0.frame.height > 300 }
        guard let target = ws.first(where: { ($0.owningApplication?.applicationName ?? "").contains(want) })
        else { print("NONE"); return }
        let ahead = ws.prefix(while: { $0.windowID != target.windowID })
        var best: CGPoint?
        var bestArea = 0.0
        // Scan a grid inside the target and keep the point furthest from any
        // window that is in front of it.
        for gx in stride(from: 0.08, through: 0.92, by: 0.04) {
            for gy in stride(from: 0.08, through: 0.92, by: 0.04) {
                let p = CGPoint(x: target.frame.minX + target.frame.width * gx,
                                y: target.frame.minY + target.frame.height * gy)
                if ahead.contains(where: { $0.frame.contains(p) }) { continue }
                // Prefer a point with room around it.
                let margin = min(min(p.x - target.frame.minX, target.frame.maxX - p.x),
                                 min(p.y - target.frame.minY, target.frame.maxY - p.y))
                if margin > bestArea { bestArea = margin; best = p }
            }
        }
        if let b = best {
            print(String(format: "%.0f %.0f", b.x, b.y))
        } else {
            print("NONE")
        }
    }
}
