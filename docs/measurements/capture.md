# Capture probe results

Measured 2026-08-17 on macOS 26.5.2 (build 25F84), Swift 6.3.3, Xcode 26
toolchain, MacBook with one 1470x956 logical display (2940x1912 backing).

Probe: `probes/capture/probe.swift`, built and signed by `build.sh`, installed
as `/Applications/SnaprProbe.app`, bundle id `com.hengkysandy.snapr.probe`.

| # | Assumption | Verdict |
|---|---|---|
| A1 | Screen Recording grant survives a rebuild on a free Apple Development cert | **TRUE** |
| A2 | macOS 26 does not re-prompt for Screen Recording on a schedule | **NOT PROVEN** |
| A3 | ScreenCaptureKit takes a fast one-shot still | **TRUE**, better than expected |
| A4 | Our overlay can be kept out of its own capture | **TRUE**, two ways |
| A5 | Window enumeration gives real titles and frames | **TRUE** |
| A6 | Global hotkeys work with no Accessibility grant | **TRUE** |
| A7 | Multi-display capture and coordinate mapping | **UNPROVABLE HERE**, one display |
| A16 | Free Apple Development cert gives a requirement with no cdhash | **TRUE** |

---

## A16 and A1: signing and the permission

The designated requirement produced by the free Apple Development certificate:

```
designated => identifier "com.hengkysandy.snapr.probe"
              and anchor apple generic
              and certificate leaf[subject.CN] = "Apple Development: ... (G4VC8JL3UR)"
              and certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */
```

Identity, not binary hash. Matches Clipd's result exactly.

### The rebuild test

`build.sh` writes a fresh UUID into `buildstamp.swift` on every build. This is
deliberate. Clipd's version of this probe changed only a comment, so `swiftc`
emitted a **byte-identical binary**, the CDHash never moved, and the harness
printed PASS while measuring nothing at all.

| Build | Signing | CDHash | Capture result |
|---|---|---|---|
| 1 | Apple Development | `2eca6a05217601aca688f8d30166c5948225b7f3` | REAL CONTENT |
| 2 | Apple Development | `f4352c2fd001c70b0b92ead8985aaef67429e05f` | REAL CONTENT, no re-grant |
| 3 | **ad-hoc** | `ce77151fb4441babdb8904f412eb07e06033b83a` | **DENIED** |

Build 3 is the fail-on-purpose control, and it fired. Its requirement is:

```
designated => cdhash H"ce77151fb4441babdb8904f412eb07e06033b83a"
```

So the probe **can** print FAIL, which is what makes builds 1 and 2 meaningful.

**Design consequence:** sign with the Apple Development certificate from the
first build, never ad-hoc. Put the loud warning in `./app` exactly as the
scaffolding doc describes.

---

## Three things measured that were not on the assumption list

### 1. Running a probe from the terminal measures the terminal, not the app

The same binary, same CDHash, launched two ways:

| Launched via | `CGPreflightScreenCaptureAccess()` | `AXIsProcessTrusted()` |
|---|---|---|
| `/Applications/SnaprProbe.app/Contents/MacOS/SnaprProbe` | **true** | **true** |
| `open -a /Applications/SnaprProbe.app` | **false** | **false** |

TCC attributes the check to the **responsible process**. Launched from a
terminal that already holds both grants, a brand new app with no grants at all
reported that it had them.

This is rule 4 in its purest form: the probe printed a pass while measuring
nothing. Every permission check from now on must be launched through
LaunchServices, and because `open` detaches stdout, the probe has to write its
results to a file.

### 2. `CGDisplayCreateImage` is gone, not deprecated

It does not compile against the macOS 26 SDK. The error is `unavailable`, with
a fix-it pointing at ScreenCaptureKit.

**Design consequence:** there is no legacy capture path to fall back to, and no
second API to differentially diagnose against. Shottr's binary still contains a
`CGWindowListCreateImage` string, which tells us it is built against an older
SDK than this one, not that the call is still available to us.

### 3. ScreenCaptureKit fails LOUDLY, which contradicts the A1 prediction

The assumption list predicted a silent black frame. It is not silent:

```
Error Domain=com.apple.ScreenCaptureKit.SCStreamErrorDomain Code=-3801
"The user declined TCCs for application, window, display capture"
```

**Design consequence, and it is a simplification:** detect a missing grant by
reading error `-3801` from `SCShareableContent`, not by inspecting pixels for
blackness. Keep the black-frame check anyway, because it still covers the other
causes (a display that went to sleep, a filter that excluded everything), but it
is no longer the primary signal. The loud banner is still required, because the
user still has to be told, but the app will always know.

---

## A3: capture speed

50 consecutive one-shot captures at 2940x1912, `captureResolution = .best`,
cursor excluded, via `SCScreenshotManager.captureImage`.

| | |
|---|---|
| min | **11.8 ms** |
| median | **13.4 ms** |
| max | 49.4 ms |

Shottr advertises 17 ms. This is faster.

**Design consequence:** no pre-warmed `SCStream` is needed. A plain one-shot
capture per hotkey press is fast enough to feel instant. That removes a whole
subsystem from the design. The 49 ms maximum is the cold first call, so warming
the ScreenCaptureKit stack once at launch is worth doing, but nothing more.

---

## A4: keeping our own overlay out of the capture

The probe paints its own pure white full-screen backdrop, puts a 45% black
overlay on top, then captures and samples the exact centre pixel. A known
correct answer, so the result is a number rather than an impression.

| Capture | Centre pixel | Meaning |
|---|---|---|
| No exclusion | `rgb(140, 140, 140)` | The overlay leaked in. This is the control, and it fired |
| `SCContentFilter(excludingWindows:)` | `rgb(255, 255, 255)` | Kept out cleanly |
| Capture first, then show a frozen image | `rgb(12, 13, 17)` | The real desktop, both our windows gone |

Cost of the freeze-frame capture: 49.1 ms (a cold call).

**Design consequence:** use **capture-first**. Both work, but capture-first is
correct by construction rather than by remembering to pass the right filter, and
it is also what makes the selection feel instant and lets the user zoom and
measure inside a still image while selecting. This matches what Shottr's hidden
`areaCustomGrabber` does, and the fact they made it experimental rather than
default is a hint that it has edge cases worth watching (a screen that changes
under the freeze, and a second display).

---

## A5: window enumeration

`SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)`

- windows returned: 21
- with a non-empty title: **21**
- applications returned: available

Titles, frames, window layer and owning application are all present. Titles are
redacted to zero length without the grant, and redaction is not an error, so the
count of non-empty titles is the real measurement.

**Note on privacy:** the probe logs `titleChars=<n>`, never the title itself.
Window titles are user content.

---

## A6: global hotkeys with no Accessibility grant

Measured with `AXIsProcessTrusted() == false`, confirmed in the same run.

| | |
|---|---|
| `RegisterEventHotKey` | `0` (noErr) |
| Same hotkey registered twice | `-9878`, rejected. Registration **is** exclusive |
| Times the hotkey fired | **2** |

**TRUE. Carbon global hotkeys need no Accessibility permission.**

### Two harness bugs found before the platform answered anything

Both produced "registration returned noErr, no key arrived", which is
indistinguishable from a permission failure:

1. `Task.sleep` suspends without draining the Carbon event queue.
2. Hand-pumping `RunLoop.current.run(mode:before:)` is **also** not enough.
   Carbon hotkey events are dispatched inside NSApplication's own event loop.
   Only `NSApp.run()` works.

### And one fact worth keeping for every future UI test

`osascript ... keystroke "8" using {command down, control down, option down,
shift down}` does **not** trigger a Carbon global hotkey. A `CGEvent` posted
directly does, at either `.cghidEventTap` or `.cgSessionEventTap`. Both fired,
hence a count of 2.

So a UI test that drives a global shortcut must post a CGEvent, not use
System Events. An `osascript` keystroke that appears to do nothing is not
evidence that the shortcut is broken.

---

## A2 and A7: not proven, and written down rather than hoped over

**A2, scheduled re-prompting.** Not measurable in one sitting. macOS 15
introduced periodic re-consent for screen recording. Whether macOS 26 still does
it, and on what schedule, cannot be observed without waiting. This goes into the
design's "still unproven" section and into the shipped documentation.

**A7, multi-display.** This machine has one display. Capture, coordinate
mapping across displays with different backing scale factors, and a display with
a negative origin are all unmeasured. The failure mode is a selection on the
second display capturing the wrong region of the first.

Both are real gaps. Rule 19: a known gap that is written down is a bug report
waiting to be useful. A known gap that is not written down is a claim you did
not mean to make.

---

---

## A15: continuous colour sampling. Added 2026-08-17, second session

Probe mode `colour`, source in `colour.swift`. The probe paints swatches whose
sRGB values it chose, captures them, reads them back and subtracts. A known
correct answer, so the result is a number.

### A15.1 The default capture configuration reports the wrong colour

| swatch | drew | read, **default config** | read, **pinned sRGB** |
|---|---|---|---|
| pure red | 255, 0, 0 | **234, 52, 36** | 255, 1, 1 |
| pure green | 0, 255, 0 | **116, 251, 76** | 0, 255, 0 |
| pure blue | 0, 0, 255 | 0, 0, 245 | 0, 0, 255 |
| white | 255, 255, 255 | 255, 255, 255 | 255, 255, 255 |
| black | 0, 0, 0 | 0, 0, 0 | 0, 0, 0 |
| mid grey | 128, 128, 128 | 128, 128, 128 | 128, 128, 128 |
| #123456 | 18, 52, 86 | 27, 51, 84 | 18, 52, 87 |
| #ABCDEF | 171, 205, 239 | 178, 204, 236 | 171, 205, 239 |
| **worst channel delta** | | **116** | **1** |

The captured image's colour space is `<none>` by default and
`kCGColorSpaceSRGB` when pinned. This machine's display is "Color LCD", wider
than sRGB, and the default capture hands back display-native values.

**A colour picker built on the default configuration would report `#EA3424` for
a pixel that is really `#FF0000`.** Nothing errors. Nothing looks obviously
wrong. The user pastes the wrong hex into a design tool and never finds out.
This is the exact silent failure the probe was written to catch, and it fired.

**Design consequence, non-negotiable:** every `SCStreamConfiguration` in the app
sets `colorSpaceName = CGColorSpace.sRGB`, and the picker is only honest because
of that one line. It gets a comment saying so, because it looks removable.

Residual error with sRGB pinned is 1 unit on 2 of 8 swatches, which is rounding
in the gamut conversion, not a systematic offset.

### A15.2 The loupe is essentially free

Read from an already-captured `CGImage`:

| operation | median | max |
|---|---|---|
| single pixel | 0.0000 ms | 0.0039 ms |
| darkest pixel in a 20x20 box (the forgiving pick) | 0.0700 ms | 0.0991 ms |
| a whole 17x17 magnified loupe frame | **0.0451 ms** | |

**371 loupe frames fit inside one 16.7 ms frame budget.** The colour picker,
the loupe and the live contrast readout can all update on every mouse move with
no throttling and no caching.

**The predicted mistake did not fire, and that is reported rather than hidden.**
Re-fetching the `CFData` on every sample instead of holding the pointer measured
0.0000 ms median. `CFDataGetBytePtr` on an already-materialised `CFData` is
cheap. So that particular optimisation is not needed. Holding the pointer is
still the clearer code, but it is not buying speed.

### A15.3 WCAG contrast maths, with a control that must disagree

| pair | computed | published | naive, no gamma |
|---|---|---|---|
| black on white | 21.00:1 | 21.00 | 21.00:1 |
| white on white | 1.00:1 | 1.00 | 1.00:1 |
| mid grey on white | **3.95:1** | 3.95 | **1.90:1** |
| #767676 on white (the AA boundary) | **4.54:1** | 4.54 | **2.05:1** |

All four match published values. The naive column skips gamma linearisation,
which is the mistake nearly every hand-rolled contrast function makes, and it
disagrees by more than 2x on the grey cases. The control fired, so the correct
implementation is doing real work rather than accidentally agreeing.

### A15.4 Out of bounds

Sampling past the right edge returns the sentinel `-1,-1,-1` rather than reading
stray memory or returning a plausible colour. **PASS.**

### One harness bug worth recording

The first run reported a channel delta of 240 for the eighth swatch under
**both** configurations, which reads as a catastrophic platform failure. It was
not. At 200-point cells, eight swatches span 3200 backing pixels on a
2940-pixel-wide display, so the last swatch centre was off screen and the probe
sampled out of bounds. Its own sentinel value was being reported as a colour
error. Cell size dropped to 150 and the number became 0.

Rule 4 again: the loudest number in the output was the harness, not the
platform. Only the fail-on-purpose case in A15.4 made the sentinel legible.

---

## Cleanup owed

`/Applications/SnaprProbe.app` holds a real Screen Recording grant. Removing the
folder is tidiness. **Revoking the grant is the security step**:

```sh
tccutil reset ScreenCapture com.hengkysandy.snapr.probe
rm -rf /Applications/SnaprProbe.app
rm -f ~/snapr-probe.log
```
