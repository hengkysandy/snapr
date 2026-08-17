# Snapr

A precision screenshot tool for macOS with a **searchable, encrypted history**.

Every capture is read for text in the background and stored encrypted on your
Mac. Search it by what was written on the screen, not by when you took it.

Requires macOS 15 or later. Apple Silicon and Intel.

---

## What it does

**Capture** an area, the full screen, a window, on a delay, or repeat your last
area. The selection runs over a frozen still of the screen, so nothing moves
under you while you aim.

**While selecting**

| | |
|---|---|
| Zoom loupe | A magnified pixel grid follows the cursor with the exact hex value |
| Pixel measurement | Arrow keys nudge each edge by exactly one pixel. Shift moves by ten |
| Edge snap | `A` snaps the selection to the element under the cursor. Press again to grow outward |
| Colour picker | Click to take the exact pixel. Hold Shift to take the darkest pixel nearby, because nobody can hit a one-pixel target |
| Contrast | A live WCAG ratio and grade across the selection |

**Annotate** with arrows, boxes, text, numbered steps, pixelated blur and
highlight. Undo and redo. Crop. Copy, save as PNG, or drag the image straight
into another app.

**Find it again.** Every capture is read with Apple's Vision framework, offline,
and indexed. Search returns matches from your oldest screenshots, not just the
recent ones. QR codes and barcodes are decoded in the same pass.

## Privacy

- **Nothing leaves your Mac.** There is no network code in this app. Text
  recognition runs offline; that was verified by re-running the recognition
  benchmark under `sandbox-exec` with all network access denied and getting
  identical timings.
- **The history is encrypted.** Screenshots are sealed with AES-GCM and the
  index is a SQLCipher database. The key is generated on first launch and lives
  in your login Keychain.
- **Nothing sensitive is logged.** The app never writes OCR text, window titles,
  filenames you chose, or the colours you picked into any log. It logs counts,
  sizes and durations.
- An explicit `Cmd+S` writes an ordinary PNG. A file you asked for is not part
  of the encrypted library.

## Installing

Download the DMG and drag Snapr to Applications.

### The first launch will be blocked, and that is expected

Snapr is signed with a free Apple Development certificate. **Apple only allows
notarisation with a paid Developer Program membership**, so on any Mac that did
not build it, Gatekeeper refuses the first launch.

To get past it:

1. Try to open Snapr. macOS will refuse.
2. Open **System Settings**, then **Privacy & Security**.
3. Scroll down. There is an **Open Anyway** button. Press it.

Recent versions of macOS removed the old Control-click shortcut, so this is now
the sanctioned route. If you prefer the terminal:

```sh
xattr -dr com.apple.quarantine /Applications/Snapr.app
```

### Then grant Screen Recording

macOS will not let any app read the screen without it. Snapr asks on first
capture and opens the right settings pane. **Quit and reopen Snapr after
granting it**, because macOS only re-reads the permission at launch.

Snapr does **not** need Accessibility. Its global shortcuts use Carbon hotkeys,
which need no such grant. If anything asks you for Accessibility on Snapr's
behalf, something is wrong.

## Default shortcuts

| Action | Shortcut |
|---|---|
| Capture area | `⌃⇧4` |
| Capture full screen | `⌃⇧3` |
| Capture window | `⌃⇧1` |
| Delayed capture (3s) | `⌃⇧2` |
| Repeat last area | `⌃⇧R` |
| Open history | `⌃⇧H` |

Control-Shift rather than Command-Shift, because `⌘⇧3`, `⌘⇧4` and `⌘⇧5` belong
to the macOS screenshot service and cannot be taken. All of them are editable in
Settings, and Snapr tells you when a combination is already owned by something
else instead of silently doing nothing.

## Building it yourself

```sh
brew install xcodegen
sudo xcode-select -s /Applications/Xcode.app        # once per machine
security find-identity -v -p codesigning
echo 'Apple Development: you@example.com (TEAMID)' > .app-signing

./app up        # build, install to /Applications, launch
./app test      # core tests, then the integration tests
./app sig       # confirm the signature survives rebuilds
./app dmg       # a Release DMG in dist/
```

### Why `.app-signing` is not optional

Under ad-hoc signing the designated requirement is pinned to the binary hash,
which changes on every build. macOS drops the Screen Recording grant with it,
and the app then **launches, looks perfectly healthy, and captures nothing**.

A real Apple Development certificate gives a requirement built from the
identifier and the certificate, with no hash in it, which survives rebuilds.
`./app sig` checks exactly that, and `./app` prints a loud warning rather than
falling back quietly.

A free Apple ID is enough for this. You do not need the paid membership to build
and run Snapr, only to notarise it for other people.

## What it deliberately does not do

No scrolling capture, no content-aware erase, no video or GIF recording, no
upload to any service, and no iCloud sync. Each of those was considered and left
out rather than forgotten.

## Layout

```
Sources/SnaprCore/     every decision. No AppKit, no ScreenCaptureKit, no Vision
Tests/SnaprCoreTests/  70 tests, 0.12 s, no app and no permission needed
SnaprMac/              the thin shell that touches macOS
docs/design.md         the design, and the measurements that produced it
CONTRACTS.md           the module boundaries
```

`docs/design.md` is worth reading before changing anything. Every decision in it
carries the measurement that caused it, including several that contradicted the
obvious choice.
