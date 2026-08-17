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

**Capture a long page** with `⌃⇧5`. Draw a region, then scroll that window
yourself while a small panel counts the height. Press `⌃⇧5` again, or click
Done, and the frames are joined into one tall image. Sticky headers and footers
are detected and appear once rather than being stamped through the middle.

*You* scroll, not the app, and that is on purpose: making the app scroll for you
would require the Accessibility permission, which Snapr does not want. If you
scroll faster than it can follow it skips a frame and says so, rather than
guessing and quietly dropping a paragraph.

**While selecting**

| | |
|---|---|
| Zoom loupe | A magnified pixel grid follows the cursor with the exact hex value |
| Pixel measurement | Arrow keys nudge each edge by exactly one pixel. Shift moves by ten |
| Edge snap | `A` suggests the element under the cursor. Press again to grow outward. See the note below |
| Colour picker | Click to take the exact pixel. Hold Shift to take the darkest pixel nearby, because nobody can hit a one-pixel target |
| Contrast | A live WCAG ratio and grade across the selection |

**A straight note about edge snap.** `A` offers a ladder, smallest first: the
element under the cursor, then the window under the cursor, then larger windows.

The **window** rungs are exact, because macOS reports the real frames. The
**element** rung is pixel-based and finds the control about **44%** of the time
on real windows, measured rather than guessed. It never suggests a wrong
rectangle, it stays silent instead, so when it misses you simply get the window.
Small toolbar icon buttons are its worst case: it tends to find the icon rather
than the button. `docs/design.md` sections 5.4 and 5.5 have the numbers.

**Annotate** with arrows, rectangles, text, numbered counters, pixelated blur and
highlight. Rectangles are filled or border only. One slider sets the size: line
width from a hairline to a marker pen, and for text the type size, because line
width means nothing for a label.

Anything already drawn can still be changed. Select it and the colour, width and
fill controls point at that shape instead of at the next one, so a box in the
wrong colour is one click to fix rather than an undo and a redraw.

Text goes back to idle when you finish a label, so typing one caption does not
start the next one.

Undo and redo, where a whole drag is one step. Crop. Copy, save, or drag the
image straight into another app.

**Finishing a screenshot** takes one key. `Esc` copies it to the clipboard and
closes the window. `Cmd+S` writes a timestamped PNG to Downloads and closes the
window, with no panel asking you to name it. Neither ever overwrites a file that
is already there. A small receipt appears for a few seconds naming the file;
click it to show the file in the Finder.

**Find it again.** Every capture is read with Apple's Vision framework, offline,
and indexed. Search returns matches from your oldest screenshots, not just the
recent ones. QR codes and barcodes are decoded in the same pass.

**Get the text out.** Three ways, depending on what you have:

| | |
|---|---|
| `⌃⇧T` | Drag a region and the text in it goes straight to the clipboard. No screenshot is kept |
| `⇧⌘C` in the editor | The text in the picture you are looking at |
| Right-click in the history | The text of a screenshot you took weeks ago, already recognised, so it is instant |

Text wins over barcodes: a QR code is copied only when there is no readable
text, so a page of prose never comes back with a URL glued to the end. If
nothing is found, your clipboard is left exactly as it was, and the app says so
rather than quietly replacing it with nothing.

In the editor this reads the picture **as you see it**, so text under a blur
stays unreadable and anything you cropped away is gone.

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
- An explicit `Cmd+S` writes an ordinary PNG to Downloads. A file you asked for
  is not part of the encrypted library.

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
| Copy text from area | `⌃⇧T` |
| Scrolling capture | `⌃⇧5` (press again to finish) |
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

No content-aware erase, no video or GIF recording, no
upload to any service, and no iCloud sync. Each of those was considered and left
out rather than forgotten.

## Layout

```
Sources/SnaprCore/     every decision. No AppKit, no ScreenCaptureKit, no Vision
Tests/SnaprCoreTests/  97 tests, 0.14 s, no app and no permission needed
SnaprMac/              the thin shell that touches macOS
docs/design.md         the design, and the measurements that produced it
CONTRACTS.md           the module boundaries
```

`docs/design.md` is worth reading before changing anything. Every decision in it
carries the measurement that caused it, including several that contradicted the
obvious choice.
