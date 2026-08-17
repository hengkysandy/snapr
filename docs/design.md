# Snapr design

Version 0.1.0. Written 2026-08-17, after the probes, against what survived them.

Tier: Personal. Compute: none.

Every number in this document was measured on this machine, by a throwaway
binary built to fail on purpose. Nothing here is a guess. Where something is a
guess it says so.

---

## 1. What Snapr is

A precision screenshot toolkit for macOS with a **searchable, encrypted history
of every capture, indexed by its text**.

Shottr is the reference for the toolkit half. It has OCR and it has no history,
and its own public request list shows people keep asking for one. That gap is
the reason this app exists.

### In scope for 0.1.0

| Area | Features |
|---|---|
| Capture | area, fullscreen, active window, pick-a-window, delayed, repeat last area |
| Selection | freeze frame, live dimensions, zoom loupe, arrow-key pixel nudge, edge snap, colour pick, live WCAG contrast |
| Editor | arrow, box, text, step counter, blur, crop, undo/redo |
| Output | clipboard, save as PNG, drag out to any app |
| Library | every capture stored encrypted, OCR'd in the background, full-text searchable |

### Deliberately out

Scrolling capture and stitching, content-aware erase, S3 or any upload target,
magnifier callout, hand-drawn rendering, before/after GIF, video recording,
iCloud sync (a free Apple account has no CloudKit).

---

## 2. The shape

```
snapr/
  Package.swift            SwiftPM: SnaprCore and its tests. No AppKit.
  project.yml              XcodeGen: the one Mac app target
  Sources/SnaprCore/       every decision that does not need macOS
  Tests/SnaprCoreTests/    swift-testing, no app, no permissions, no simulator
  SnaprMac/                the thin shell that touches macOS
  SnaprMacTests/           XCTest, the seam between core and shell
  app                      one bash script for every command
  art/                     icon source and generated .icns
  docs/design.md           this file
  .app-signing             gitignored, the signing identity for this machine
```

**Why both SwiftPM and XcodeGen.** SwiftPM cannot build an app bundle. A
hand-maintained `.xcodeproj` is a large generated file nobody can read or merge.
XcodeGen gives a `project.yml` that can carry comments, and consumes the package
as a local dependency.

**SnaprCore imports no AppKit and no ScreenCaptureKit.** Anything that decides
*what should happen* lives there and is tested in a fraction of a second with no
permission, no display and no simulator. The measured proof this matters: the
FTS5 sanitizer has to survive 29 hostile inputs, and none of them need a screen.

---

## 3. Locked decisions

| Decision | Value | What breaks if it changes |
|---|---|---|
| App name | **Snapr** | Cheap on its own. The rows below are not |
| Bundle identifier | `com.hengkysandy.snapr.mac` | **Destructive.** Every TCC grant is keyed to it. Screen Recording drops on every machine |
| Keychain service | `com.hengkysandy.snapr.dbkey` | **Destructive.** The app finds no key, generates a fresh one, and the whole encrypted library becomes permanently unreadable |
| Support directory | `~/Library/Application Support/Snapr` | **Destructive.** Orphans the history and every blob |
| Repo | `hengkysandy/snapr`, private | Cheap |
| Apple account | **Free** | No CloudKit, no notarisation. The DMG needs Open Anyway |
| Sandbox | **Off** | A free account cannot ship to the App Store, so the sandbox costs a security-scoped bookmark per folder and buys nothing |

---

## 4. Capture

### 4.1 One-shot, no stream

**Measured (A3):** 50 consecutive `SCScreenshotManager.captureImage` calls at
2940x1912 gave min 11.8 ms, **median 13.4 ms**, max 49.4 ms. Shottr advertises
17 ms.

**So there is no pre-warmed `SCStream`.** That removes a whole subsystem. The
49 ms maximum is the cold first call, so the ScreenCaptureKit stack is warmed
once at launch with a single throwaway capture, and nothing more.

### 4.2 Every configuration pins sRGB

```swift
cfg.colorSpaceName = CGColorSpace.sRGB   // do not remove, see below
```

**Measured (A15.1)** on the default configuration, capturing swatches whose sRGB
values the probe chose:

| drew | read back, default config |
|---|---|
| 255, 0, 0 | **234, 52, 36** |
| 0, 255, 0 | **116, 251, 76** |

Worst channel error **116** on the default, **1** with sRGB pinned. The display
is wider than sRGB and the default capture returns display-native values. A
colour picker built on the default reports `#EA3424` for a pixel that is really
`#FF0000`, with no error anywhere. That one line is the only thing making the
picker honest, so it carries a comment saying so.

### 4.3 Capture first, then freeze

**Measured (A4).** The probe painted its own known-white backdrop and sampled
the exact centre pixel:

| approach | centre pixel |
|---|---|
| no exclusion | `rgb(140,140,140)` — the overlay leaked in. Control fired |
| `SCContentFilter(excludingWindows:)` | `rgb(255,255,255)` — clean |
| capture first, show a frozen image | `rgb(12,13,17)` — the real desktop |

Both work. **Capture-first is chosen** because it is correct by construction
rather than by remembering to pass a filter, and because it is what makes zoom,
pixel measurement and colour picking possible at all: they read from a still
image, not from a moving screen.

Known edge cases, carried forward from Shottr making the same thing
experimental: content that changes under the freeze, and a second display.

### 4.4 A missing grant is detected from the error, not from black pixels

**Measured (A1).** ScreenCaptureKit fails loudly:

```
SCStreamErrorDomain Code=-3801 "The user declined TCCs for application, window, display capture"
```

The assumption list predicted a silent black frame. It was wrong, and the
correction is a simplification: read `-3801` from `SCShareableContent`. The
black-frame check stays as a secondary signal because it still covers a sleeping
display and an over-eager filter, but it is no longer how the app learns it has
no permission.

`CGDisplayCreateImage` is **unavailable** in the macOS 26 SDK, not deprecated.
There is no legacy fallback path. Do not look for one.

### 4.5 Global hotkeys

**Measured (A6)** with `AXIsProcessTrusted() == false` confirmed in the same
run: `RegisterEventHotKey` returned noErr, a second registration of the same
combination was rejected with `-9878`, and the hotkey fired.

**Carbon global hotkeys need no Accessibility grant.** Snapr requests Screen
Recording and nothing else.

Two harness facts that cost a session and are worth keeping:

- Carbon hotkey events dispatch inside NSApplication's own loop. `Task.sleep`
  and hand-pumped `RunLoop.run(mode:before:)` both fail to deliver them.
  `NSApp.run()` is required.
- `osascript ... keystroke` does **not** trigger a Carbon hotkey. A posted
  `CGEvent` does. Any UI test that drives a shortcut must post a CGEvent.

Defaults, chosen not to collide with macOS or Shottr:

| Action | Shortcut |
|---|---|
| Capture area | `Cmd Shift 5` is taken by macOS, so `Ctrl Shift 4` |
| Capture fullscreen | `Ctrl Shift 3` |
| Capture active window | `Ctrl Shift 1` |
| Repeat last area | `Ctrl Shift R` |
| Open history | `Ctrl Shift H` |

---

## 5. The selection overlay

A borderless window per display at `.screenSaver` level showing the frozen
capture, dimmed, with the live selection cut out at full brightness.

### 5.1 The loupe and the picker are free

**Measured (A15.2),** reading from the already-captured `CGImage`:

| operation | median |
|---|---|
| one pixel | 0.0000 ms |
| darkest pixel in a 20x20 box | 0.0700 ms |
| a whole 17x17 magnified loupe frame | **0.0451 ms** |

371 loupe frames fit in one 16.7 ms frame. **No throttling, no caching, no
background queue.** The loupe, the hex readout and the contrast ratio all update
on every mouse-moved event.

Honest note: the predicted mistake, re-fetching `CFData` per sample, measured
0.0000 ms as well. Holding the pointer is clearer code but it is not faster.

### 5.2 Colour picking is forgiving

Nobody can hit a one-pixel target. `Shift` takes the darkest pixel inside the
20x20 box under the cursor, at 0.07 ms. Plain pick takes the exact pixel.
Formats offered: `#RRGGBB`, `rgb()`, and NSColor-style literals.

### 5.3 Live contrast

**Measured (A15.3)** against published WCAG values:

| pair | computed | published | naive, no gamma |
|---|---|---|---|
| black on white | 21.00:1 | 21.00 | 21.00:1 |
| mid grey on white | **3.95:1** | 3.95 | **1.90:1** |
| #767676 on white | **4.54:1** | 4.54 | **2.05:1** |

The naive column skips gamma linearisation, which is the usual mistake, and it
is wrong by more than 2x. The control fired, so the implementation is doing real
work rather than accidentally agreeing. It ships in SnaprCore with those four
cases as tests.

### 5.4 Edge snap

**Measured (A14)** against 11 ground-truth elements, two seeds each:

| technique | mean IoU | IoU > 0.9 | median ms |
|---|---|---|---|
| flood fill on colour similarity | **0.961** | 20/22 | **0.20** |
| naive ray walk | 0.795 | 12/22 | 0.00 |
| gradient edge scan | 0.837 | 16/22 | 0.08 |
| `VNDetectRectanglesRequest` | **0.533** | **2/22** | 19.63 |
| hybrid (flood + acceptance + hierarchy) | 0.961 | 20/22 | 10.35 |

**Three results decide the implementation.**

1. **Vision is the wrong tool and is rejected outright.** 0.533 mean IoU, 2 of
   22. It inflates every box by 15 to 30 px because it detects the shadow and
   the rounded corner, and it missed the checkbox entirely.
2. **Plain flood fill matches the hybrid exactly and is 50x faster.** The
   hybrid's extra machinery bought zero accuracy.
3. **The hybrid's one real job is refusing to snap.** On three flat-desktop
   seeds it returned NO SNAP, where naive flood returned a confident
   1.6-megapixel rectangle of nothing.

So: run flood fill (0.20 ms, cheap enough for every mouse move), then run the
acceptance test on the result. If it fails, **show no snap indicator at all**
rather than a wrong one. Press `A` again to grow to the parent, two or three
levels, no deeper: measured level-1 parents are often a large jump rather than
the visually obvious container.

When the seed lands inside a Vision text box, snap to the **text line** first
(measured IoU 0.995 against the true line), the grouped paragraph second
(IoU 0.795), and the flood component third. Those boxes already exist from the
OCR pass, so this is not new work.

**The limitation, stated rather than buried.** The fixture is synthetic and its
elements are flat solid colours. Real macOS windows have vibrancy, gradients,
shadows and a wallpaper showing through. 0.961 will fall on real windows. This
result proves the approach is worth building at 0.2 ms with a working rejection
path. It does not prove the accuracy number. **The snap is therefore always a
suggestion the user can ignore, never an automatic selection.**

### Measured on real windows after 0.1.0 shipped, and it is much worse

Full detail in `probes/edges/REAL-RESULTS.md`. The caveat above was right and
understated.

| | synthetic fixture | real windows, before | real windows, after a fix |
|---|---|---|---|
| controls hit | **20/22 (91%)** | **1/18 (6%)** | **8/18 (44%)** |
| false accepts | 0 | 0 | 0 |

The collapse was not the technique. The flood fill was finding **correct**
rectangles (394x322 for a control that is about 395x330) and the **acceptance
test was discarding them**, for two reasons:

1. `snap` grows the flood bounds by one pixel, and `sideSupport` then compared
   two touching pixels across a boundary that had already moved.
2. Real controls are rounded and anti-aliased, so the change in brightness is
   spread over two or three pixels rather than landing in a single step.

`sideSupport` now compares a three-pixel band inside the edge against a band
outside it. Both rejection tests still pass, which is the hard part: the same
test has to refuse empty desktop and accept a soft-edged control.

**What still fails: small toolbar icon buttons.** The flood returns the icon
(16x26) rather than the button (about 60x34), because `modalColour` samples a
5-pixel radius and every one of those pixels is glyph.

**Design consequence, and it changes the product claim.** Pixel-based element
snap is a *useful assist*, not a headline feature. It must not be advertised as
one on its own.

### 5.5 Window frames, which make the snap key worth pressing

Pixel element snap alone finds the control 8 times in 18, and it stays silent
the rest of the time. **A key that does nothing more than half the time is a key
people stop pressing.**

`SCShareableContent` reports window frames **exactly**, at no extra permission
cost, and `listWindows()` already fetches them. So the snap key offers a ladder,
smallest first, built by `SnapLadder` in the core:

1. the element under the cursor, if the pixel snap accepted one
2. its parents, from the same flood
3. the window under the cursor, which is exact
4. larger windows under the cursor, outermost last

When the element snap misses, rung 1 is simply the window, so the key always
does something correct.

**Verified on the running app.** A single press at one point produced:

```
snap rungs=4 fromElement=true sizes=1946x154 -> 1446x1250 -> 2200x1236 -> 2940x1846
```

The last three are System Settings, Terminal and Chrome at exactly twice their
point frames, so the point-to-pixel conversion is right. Three further points
where the pixel snap failed (`fromElement=false`) still returned a rung each.
Before this, all three would have beeped and done nothing.

Two limitations, written down rather than discovered later:

- **The ladder does not know z-order.** A point can sit inside the frame of a
  window that is behind another one, and that rung will then select a rectangle
  showing the front window's pixels. The rectangle is still a real window's
  geometry, so the result is odd rather than wrong.
- **The screen-origin subtraction in `windowFrames(on:)` is zero on a single
  display**, so a mistake there would be invisible here. That is gap A7 again.

The remaining technique that would make *element* snapping exact is
`AXUIElementCopyElementAtPosition`, which returns the true control frame because
the OS already knows it. It needs the Accessibility grant, which this design
deliberately avoids, so it is a trade for the owner to make.

---

## 6. Storage

### 6.1 Design 2, chosen on integrity

**Measured (A12),** 200 screenshots from 250 KB to 8 MB:

| metric | blob inside SQLCipher | AES-GCM files + SQLCipher index |
|---|---|---|
| insert, median | 6.12 ms | **0.81 ms** |
| insert, p95 | 39.0 ms | **5.64 ms** |
| total on disk | 529.5 MB | **504.3 MB** |
| 30 grid thumbnails | 29.6 ms | 27.2 ms |

Speed is not what decided it. **Corruption handling is:**

| | one corrupted byte |
|---|---|
| AES-GCM sealed file | **threw on all four cases**: body flip, tag flip, truncation, wrong key |
| blob inside SQLCipher | **read back 1,600,000 bytes with no error at all** |

A screenshot library that silently hands back garbage is exactly the failure
this project exists to avoid. AEAD overhead is 28 bytes per blob.

**Layout:**

```
~/Library/Application Support/Snapr/
  index.db                SQLCipher. Metadata, OCR text, FTS5. No image bytes
  blobs/<uuid>.snapr      AES-GCM sealed PNG, the full capture
  thumbs/<uuid>.snapr     AES-GCM sealed PNG, ~320 px on the long edge
```

### 6.2 Thumbnails are stored, not derived

**Measured:** decoding the full original per grid tile costs 31 to 35 ms.
Reading a stored thumbnail costs ~1 ms. **A 32x to 37x difference.** About 16
thumbnails fit in a 16.7 ms frame either way, so the grid scrolls comfortably,
but the obvious shortcut costs 30x and is not taken.

### 6.3 The key

One 256-bit key in the Keychain under service `com.hengkysandy.snapr.dbkey`,
generated on first launch. It keys both SQLCipher (`PRAGMA key`) and the
AES-GCM blobs.

Two implementation details that cost time on the previous app:

- **`PRAGMA key`, not `sqlite3_key()`.** The C function is only declared when
  `SQLITE_HAS_CODEC` is defined at the header level, which a binary target does
  not do for consumers.
- **`PRAGMA key` must be the first statement after opening**, or SQLCipher
  writes plaintext.

Encryption is verified on disk by tests, not trusted:

```sh
xxd -l 16 index.db                  # must NOT read "SQLite format 3"
strings index.db | grep <known>     # must return nothing
```

A wrong key must **throw**, not return zero rows. An empty history looks exactly
like data loss, and that failure has to be loud.

### 6.4 Explicit saves are plain PNG

The library is encrypted. `Cmd+S` to Downloads writes an ordinary PNG, because a
file the user asked for is not the library.

---

## 7. OCR

### 7.1 It cannot run inline

**Measured (A8):** `.accurate` on a full 2940x1912 capture is **206 ms median**,
174 MB peak resident. That would be felt on every capture.

So OCR is a background job on a serial queue, off the capture path. The user
gets their editor immediately.

### 7.2 The row carries a state, not just a text column

```swift
enum OCRState { case pending, running, done, failed, noTextFound }
```

Without the state, an empty search result is indistinguishable from "not indexed
yet". That is the exact shape of the bug the previous app shipped.

### 7.3 The landmine that must not be forgotten

```swift
request.minimumTextHeightFraction = 0.005   // NOT the default
```

**Measured:** the default is `0.03125`, one thirty-second. On a 1912-px-tall
screenshot that demands ~60 px glyphs. macOS UI text at 2x is 22 to 34 px.

**With the default, `.fast` returns zero observations, zero characters and
confidence 0.000 on every normal screenshot, and reports no error.** It looks
exactly like an image with no text.

| configuration | lines | whole-line accuracy | time |
|---|---|---|---|
| `.fast`, default floor | **0** | 0/22 | 19.0 ms |
| `.fast`, floor 0.005 | 26 | 18/22 | 20.7 ms |
| `.accurate`, default floor | 26 | 21/22 | 196.2 ms |
| `.accurate`, floor 0.005 | 26 | **22/22** | 198.6 ms |

The floor is required on **both** paths. It also takes `.accurate` from 21/22 to
a clean 22/22.

0.1.0 runs `.accurate` only. The two-tier arrangement (`.fast` immediately, then
`.accurate`) is affordable and is deliberately deferred, because it doubles the
state machine for a benefit measured in a fraction of a second.

### 7.4 Barcodes come along free

**Measured (A10):** adding `VNDetectBarcodesRequest` to the same handler costs
**+4.2 ms, 2.2%**. A generated QR decoded exactly. The fixture's deliberate
black-and-white noise block returned **nothing**, so the detector does not
hallucinate. Always on.

### 7.5 Vision is offline

Confirmed by re-running the whole probe under `sandbox-exec` with
`(deny network*)`. Identical timings. No capture ever leaves the machine.

---

## 8. Search

**Measured (A13)** over 5000 documents, 3.21 MB of OCR text:

| | |
|---|---|
| index build | 21 ms for 5000 rows |
| index size, contentless FTS5, encrypted | 1.32 MB |
| worst query (common word, 3857 hits) | **2.0 ms** |
| rare phrase in the oldest row | 0.010 ms |

### 8.1 The bug shape this rules out

The previous app scanned the newest 500 rows in memory:

```
newest-500 window contains the target row: NO
scan-newest-500  -> 0 hits, and says nothing was found
FTS5 MATCH       -> 1 hit
```

A search that returns zero looked identical to a search that found nothing.

### 8.2 The sanitizer is not optional

**Measured: 23 of 29 realistic inputs make FTS5 throw.** Every query is already
a bound parameter, so SQL injection was never the risk. FTS5 **expression
parsing** is. A user typing a single apostrophe gets
`SQLITE_ERROR fts5: syntax error near "'"`.

Throwing inputs include: the empty string, a single space, an apostrophe, a
double quote, `*` alone, a leading `*`, `^`, `-`, `col:`, `(`, `()`, bare `AND`,
bare `NOT`, `%`, `_`, `\`, `{}`.

The rule, and it lives in SnaprCore with all 29 inputs as tests:

> Never pass raw user text to `MATCH`. Split on non-alphanumerics, quote each
> token, append `*` to the last token for as-you-type prefix search. An empty
> token list means skip the query, not run an empty one.

```
after sanitizing, inputs that still throw: NONE
sanitizer still finds the oldest row:      YES
```

---

## 9. Signing, and the one rule

**Measured (A16 and A1).** The free Apple Development certificate produces:

```
designated => identifier "com.hengkysandy.snapr.probe"
              and anchor apple generic
              and certificate leaf[subject.CN] = "Apple Development: ..."
              and certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */
```

Identity, **no cdhash**. The grant survives rebuilds. Confirmed across three
builds with three different CDHashes, including a **fail-on-purpose ad-hoc
build** whose requirement was `designated => cdhash H"ce77..."` and which was
**denied**. The control fired, which is what makes the two passes mean anything.

So `./app` warns **loudly** when `.app-signing` is missing rather than quietly
falling back to ad-hoc. Under ad-hoc the app builds, launches, looks perfectly
healthy and captures nothing after the next rebuild.

`./app sig` exists to check exactly one thing: that the requirement contains the
identifier and the certificate and does **not** contain a `cdhash`.

### The trap that invalidates any permission measurement

**Measured.** The same binary, same CDHash, launched two ways:

| launched via | `CGPreflightScreenCaptureAccess()` |
|---|---|
| the binary inside the bundle, from a terminal | **true** |
| `open -a` | **false** |

TCC attributes the check to the **responsible process**. Launched from a
terminal that already holds the grant, a brand new app with nothing granted
reported that it had it. **Every permission check must be exercised through
LaunchServices**, and because `open` detaches stdout, any diagnostic has to land
in a file.

---

## 10. Shipping

Release build, staged with a symlink to `/Applications`, `hdiutil create` with
`UDZO`.

A free account **cannot notarise**. Notarisation needs a Developer ID
certificate, which needs the paid membership. There is no free path. So on any
Mac that did not build it, Gatekeeper refuses the first launch and the user goes
to System Settings, Privacy and Security, **Open Anyway**. This is stated in the
README rather than discovered.

`codesign -dvvv` on the published DMG exposes the certificate email and Team ID.
Anyone can read it. **That is the repository owner's decision to make before the
first public release, not after.**

---

## 11. Still unproven, written down rather than hoped over

| # | Gap | Failure mode if it is wrong |
|---|---|---|
| A2 | Whether macOS 26 re-prompts for Screen Recording on a schedule. macOS 15 introduced periodic re-consent. Not measurable in one sitting | The app stops capturing until the user re-grants, and it must say so clearly rather than produce black frames |
| A7 | Multi-display. **This machine has one display.** Capture, coordinate mapping across different backing scale factors, and a display with a negative origin are all unmeasured | A selection on the second display captures the wrong region of the first |
| — | Edge snap accuracy on **real** macOS windows rather than flat synthetic ones | The snap suggests a wrong rectangle. Mitigated by design: it is a suggestion with an acceptance test, never automatic |
| — | Behaviour when the screen changes under the freeze frame | The user annotates a stale image without realising |

A known gap that is written down is a bug report waiting to be useful. A known
gap that is not written down is a claim nobody meant to make.
