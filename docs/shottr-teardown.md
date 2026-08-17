# Shottr 1.9.1 teardown

Two sources, kept separate so I can tell measured facts from published claims.

- **Measured** on this Mac, from `/Applications/Shottr.app`.
- **Published** from shottr.cc (landing page, KB, changelog, public feature-request
  vote list), gathered by a research agent.

---

## Part 1: Measured from the bundle

### Identity and size

| Fact | Value |
|---|---|
| Bundle id | `cc.ffitch.shottr` |
| Version | 1.9.1 (build 128) |
| Bundle size on disk | **6.6 MB** |
| Minimum macOS | 10.15 Catalina |
| Built with | Xcode 26, macOS 26.0 SDK |
| UI toolkit | AppKit + Storyboards, with some SwiftUI linked |
| `LSUIElement` | **false**, so it does have a Dock icon |
| URL scheme | `shottr://` |
| Document types | opens `public.png`, `public.jpeg`, `public.compuserve.gif` |

6.6 MB is the number to remember. It sets the bar for what "native and small"
means here.

### Entitlements: it is sandboxed

```
com.apple.security.app-sandbox                                  true
com.apple.security.files.user-selected.read-write               true
com.apple.security.network.client                               true
com.apple.security.print                                        true
com.apple.security.temporary-exception.mach-register.global-name
    com.apple.screencapture.interactive
```

Two things follow from this, and both are load-bearing for our design:

1. **A sandboxed app can still capture the screen.** It needs the Screen
   Recording TCC grant, not an entitlement.
2. The save folder is reached through a **security-scoped bookmark**, which is
   why `defaults read` shows `defaultFolderBookmark` as an opaque blob next to
   `defaultFolder`. Without the bookmark the grant dies on relaunch.

### Linked frameworks, the interesting ones

`ScreenCaptureKit`, `Vision`, `CoreImage`, `QuickLookThumbnailing`, `Carbon`
(for the global hotkeys), `Security` (Keychain), `ServiceManagement` (launch at
login), `UserNotifications`, `CryptoKit`.

Notably **no AVFoundation video recording path** in use. Confirms: no screen
recording feature.

A binary string reads `CGWindowListCreateImage for wallpaper failed`, so it
still uses the old CoreGraphics API for at least the wallpaper path, with
ScreenCaptureKit for the main capture.

### Architecture, read from Swift class names in the binary

This is effectively Shottr's own module list.

**Annotation objects**, all prefixed `Obj`:

`ObjArrow`, `ObjRectangle`, `ObjRectangleBasic`, `ObjOval`, `ObjLine`,
`ObjText`, `ObjCounter` (step numbers), `ObjFreehand`, `ObjHighlighter`,
`ObjConceal` (blur and pixelate), `ObjSpotlight`, `ObjMagnifier`, `ObjRuler`,
`ObjImage` (pasted overlay).

That is **14 object types** behind one `ProtoObject` protocol, with shared
`ObjectHandlers`, `FrameHandlers`, `Undo` and `Knob` (the resize handles).
The pattern is clear: one protocol, one object per tool, one shared handler
layer.

**Capture and imaging:**

`Capturer`, `RegionSelector`, `CrosshairView`, `ScrollCapturer`,
`VisionStitcher` (so scroll stitching is done with Vision, not a hand written
correlator), `ScreenLib`, `Framer`, `Backdrop`, `ElFit` (the element-fitting
that powers smart edge snapping), `ColorMagic`, `ColorPicker`, `Contrast`,
`OKLCH`, `CropTool`, `Ruler`.

**Windows:** `MainWindowController`, `PreviewWindowController` (the editor),
`PinWindowController` (floating pins), `LibViewController` +
`GalleryDelegate` + `IndexMachine` (a file indexer), `QuickLookWinController`,
`PrefWindowController` with five tabs: `PrefViewController`,
`PrefHotkeyViewController`, `PrefUploadViewController`,
`PrefAdvancedViewController`, `PrefLicenseViewController`.

**Plumbing:** `Exporter`, `Networker`, `Payments`, `Updater`, `Telemetry`,
`KeychainSwift`, `Secrets`, `Crypti`, `Notifier`, `WinNotifier`, `Announcer`,
`DataLayer`, `Settings`.

Note `LibViewController` and `IndexMachine` exist, with strings
`Preparing to index your files...`, `Finishing indexing`,
`Screenshot Library is disabled`. So a screenshot library **does exist in the
binary**, indexing a folder rather than owning a database. The website
describes a library as a missing feature. Treat the shipped state as unclear.

### Capture verbs, from the URL scheme handler strings

`grabArea`, `grabAreaRepeat`, `grabWindow`, `grabWindowInteractive`,
`grabFullscreen`, `grabDelayed`, `grabScrolling`, `grabScrollingUp`,
`grabScrollingManual`, `ocr`, `colorPicker`, `pin`.

### Registered global hotkeys on this machine

Read from `defaults read cc.ffitch.shottr`. Uses the `KeyboardShortcuts` SPM
package, stored as Carbon key code plus Carbon modifier mask.

| Action | Carbon | Decoded |
|---|---|---|
| `window` | key 18, mod 768 | Cmd+Shift+1 |
| `ocr` | key 19, mod 768 | Cmd+Shift+2 |
| `area` | key 25, mod 2816 | Cmd+Shift+Option+9 |
| `scrolling` | key 29, mod 2816 | Cmd+Shift+Option+0 |
| `fullscreen` | 0 | **not assigned** |

Carbon modifier bits: cmd 256, shift 512, option 2048, control 4096.
These are this user's customized values, not the defaults.

### Every preference key, with what it reveals

```
afterGrabCopy / afterGrabSave / afterGrabShow   what happens after a capture
areaCaptureMode = editor                        editor or thumbnail
areaCustomGrabber = 0                           the hidden screen-freezing grabber
captureCursor = auto                            include / exclude / auto
snappingMode = 2                                object snapping strength
colorFormat = HEX                               HEX / HEX no hash / OKLCH
contrastType = wcag2                            wcag2 or apca
saveFormat = Auto                               Auto picks PNG or JPEG per content
downscaleOnSave = 0                             retina 2x downscale
realPixels = 0                                  logical points vs physical pixels
expandableCanvas = 1                            draw outside the image bounds
headlessTextRendering = 1
scrollingMax = 20000                            max stitched height in px
scrollingSpeed = 2
scrollingReverseAutoscroll = 0
scrollingManualEnabled = 0
primaryOCRLang = en-US
ocrRemoveBreaks = 0
windowShadow = transparent                      window capture background mode
windowSolidColor = #404448
customBackdropColor / customGradFrom / customGradTo
defaultColor = #FF0C01                          annotation colour
defaultFolder + defaultFolderBookmark           security-scoped bookmark
copyOnEsc = 1 / saveOnEsc = 0
alwaysOnTop / preferLargeWindow / notificationType
uploadMode = none
uploadS3Bucket / Endpoint / Region / Prefix / PublicUrl / PresignExpiration
uploadS3SharingMode / token
kc-vault                                        an encrypted blob in prefs
allowTelemetry / GATelemetry / localEventCounter
Shottr.ObjArrow: size / Shottr.ObjRectangle: handdrawn / Shottr.ObjText: style
```

The last line is worth copying: per-tool settings are namespaced
`Shottr.<ClassName>: <property>`, so each annotation object owns its own
defaults with no central registry.

---

## Part 2: Published on shottr.cc

### Capture modes

| Mode | Notes |
|---|---|
| Fullscreen | The site recommends capture-everything-then-crop as the main workflow |
| Area | Shift for a square. Esc mid-select cancels with no window |
| Repeat area | Retakes the last region, no reselect |
| Active window | Frontmost window |
| Any window | Separate hotkey. In area mode, Space switches to a window picker |
| Scrolling down | Auto-scroll and stitch. Default max 20,000 px, up to 200,000 |
| Scrolling up | Reverse |
| Scrolling manual | Fallback where auto-scroll fails |
| Delayed | Fixed 3 s, or a custom delay through the URL scheme |
| Add capture | Appends a new shot onto the current canvas |
| OCR only | Text and QR straight to clipboard, no image kept |
| Load from clipboard / open file | Cmd+Shift+V, Cmd+Shift+O |

Area capture does **not** freeze the screen by default. The freezing grabber is
experimental and hidden behind `shottr://settings/areaCustomGrabber/enable`.

### The tools that are actually differentiators

Not the arrows and boxes, everyone has those. These:

- **True zoom, not a loupe.** Cmd+2 zoom to selection, Q and W zoom to the
  selection corners, Cmd+0 for 100%, Z+drag, Space+drag to pan. The stated core
  differentiator.
- **Pixel measurement with the arrow keys.** Press Up or Down and move the mouse
  to measure vertically, Left or Right for horizontal, click to imprint the
  number onto the image. Shift gives the outer size. It can measure the gap
  between two objects.
- **Smart edge snapping.** Press `A` after selecting to snap to detected content
  edges. Hold Option while selecting for a live preview. Click one marquee edge
  to adjust only that edge. Cmd+Click selects a contiguous single-colour object.
- **Colour picking without precision.** Tab copies the colour under the cursor.
  Shift+Tab picks the darkest pixel in a 20x20 area, which is how you sample
  text colour without hitting an antialiased edge. `C` averages a selection.
- **Live WCAG contrast ratio** shown above the selection marquee, Option+Click to
  switch between WCAG 2.0 and APCA.
- **Erase, not blur.** Content-aware removal that makes an object look like it
  was never there, plus a text-only mode that hides only text and leaves the
  rest.
- **Before and after GIF.** Overlay the after image, press 5 for transparency,
  align, export a two-frame animation.
- **Magnifier callout** drawn into the image, new in 1.9.
- **Hand-drawn style** for text, arrow, oval, rectangle. Cmd+R randomizes it.

### Export

Clipboard as PNG (not TIFF), save to one chosen folder, Save As, PNG and JPEG
only, an Auto format that picks PNG for text-heavy and JPEG for graphics-heavy,
retina downscale on save, drag out to other apps, print, GIF for the two-frame
comparison. Shottr Cloud upload needs a token. S3-compatible upload added in
1.9, direct from app to bucket, presigned links for private buckets.

Timestamp filenames only. **No configurable filename template.**

### Pricing and distribution

Free forever with a nag after 30 days. Basic $12 one-time, five computers,
required for commercial use. Friends Club $30. FastSpring. Not on the Mac App
Store. Also `brew install shottr`.

### What it does not do, per its own public request list

- No video or GIF screen recording. The clearest gap against CleanShot X.
- No screenshot history, organizer, or restore of a previous shot.
- No configurable filename template, no sequential numbering.
- No WebP, AV1 or PDF export. No multi-page PDF for scrolling captures.
- No background removal. No image rotation. No aspect-ratio constraint on crop.
- No layered or re-editable save format. Annotations flatten on save.
- No multi-select of annotations, no rotation, no polygon, no dashed lines.
- No macOS Share sheet. No third-party upload targets at all: no iCloud, Imgur,
  Dropbox, Google Drive, FTP.
- No localization. English only, deliberately.
- No explicit z-order control on annotations.
- Raster tools (crop, blur, erase, measure, colour pick) do **not** work on
  appended captures or overlays until you Rasterize, which is irreversible.

### Known weak spots

- Scrolling capture fails in Terminal, VS Code and Finder column view, because
  they emulate scrolling non-natively. Scroll-modifier apps (MOS, Scroll
  Reverser, Smooze) interfere with it.
- Screen Recording permission is the number one support issue, because macOS
  ties the grant to the app bundle path.
- Cloud uploads are public to anyone with the URL, by design, and are not
  guaranteed beyond a year.

---

## Part 3: What I have not verified

Listed so it is not quietly assumed later.

- I never opened Shottr's own UI. The first click hit Amphetamine's menu bar
  icon by mistake, its menu opened, Escape dismissed it, nothing changed. The
  second click was declined. So **every editor behaviour above is published or
  inferred, not observed**.
- Whether the screenshot Library in the binary is reachable in the shipped 1.9.1
  build, or is dead code. The binary and the website disagree.
- The real default global hotkeys. This machine's values are customized.
- Whether ScreenCaptureKit or CGWindowList is used for the main capture path.
  Both are linked.
