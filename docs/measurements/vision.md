# A8, A9, A10 results: Vision text and barcode recognition

Measured 2026-08-16/17. Probe `probes/vision/probe.swift`, run against the
synthetic fixture `probes/fixtures/fixture.png` (2940x1912) with
`fixture-truth.json` giving 22 tracked text strings, 588 characters, and their
typographic line boxes. Raw output in `run1.txt`, offline repeat in
`run-nonet.txt`.

| # | Assumption | Verdict |
|---|---|---|
| A8 | Vision OCR is fast enough to run on every capture | **TRUE, but too slow to be inline** |
| A9 | Vision gives boxes precise enough for selectable text | **PARTIAL. Per word, never per character** |
| A10 | Barcode/QR detection can share the same pass | **TRUE, +4.2 ms** |

---

## A8: speed and accuracy

Full 2940x1912 image, 20 runs each.

| recognition level | min | median | max |
|---|---|---|---|
| `.accurate` | 201.8 ms | **206.2 ms** | 215.8 ms |
| `.fast` | 18.7 ms | **19.2 ms** | 20.1 ms |

`.accurate` is **10.8x** the cost of `.fast`, an absolute gap of 187 ms.
Cold first call, model load included: 198.4 ms, one time only.

Accuracy against the 22 tracked strings:

| | `.accurate` | `.fast` (default settings) |
|---|---|---|
| lines returned | 26 | **0** |
| characters recognised | 655 | **0** |
| truth strings contained | **22/22, 100%** | 0/22 |
| truth strings matched as a whole line | **21/22, 95.5%** | 0/22 |
| mean top-candidate confidence | 1.000 | 0.000 |

Memory: current resident 139.2 MB, peak 174.3 MB for the OCR itself, 324.1 MB
peak across the whole probe.

### The landmine, and it is the most useful thing in this file

**`.fast` returns absolutely nothing on a normal screenshot, and reports no
error.** Zero observations, zero characters, confidence 0.000. It looks exactly
like an image with no text in it.

The cause, found by lowering one property and re-measuring:

```
default minimumTextHeightFraction on a fresh request: 0.03125   (= 1/32)
fixture height 1912 px, so the default floor is ~59.8 px of text height
the fixture's body text is 22-34 px tall
```

macOS UI text at 2x backing scale is 22 to 34 px. The default floor demands
60 px. So every normal screenshot falls under it.

Proof it is the floor and not a broken engine: a 1260x180 crop where the same
text is ~100 px tall, which is 0.556 of that image's height:

```
.fast              -> 1 line: "Interface Configuration"
.accurate          -> 1 line: "Interface Configuration"
inverted .fast     -> 1 line: "Interface Configuration"
inverted .accurate -> 1 line: "Interface Configuration"
```

`.fast` is not broken. It is filtered.

With the floor lowered, `.fast` becomes genuinely useful:

| configuration | lines | chars | whole-line truth | time |
|---|---|---|---|---|
| `.fast`, default floor | 0 | 0 | 0/22 | 19.0 ms |
| `.fast`, `minFrac=0.005`, correction off | 26 | 652 | **18/22** | **20.7 ms** |
| `.accurate`, default floor | 26 | 655 | 21/22 | 196.2 ms |
| `.accurate`, `minFrac=0.005` | 26 | 654 | **22/22** | 198.6 ms |

Note `.accurate` also improves, from 21/22 to a clean **22/22**, when the floor
is lowered. So the setting is required on both paths, not just the fast one.

**Design consequences, three of them:**

1. **`minimumTextHeightFraction` must be set explicitly to ~0.005 on every
   request.** Leaving the default is a silent, total OCR failure on `.fast` and
   a small accuracy loss on `.accurate`.
2. **OCR cannot run inline with the capture.** 196 ms would be felt. It runs as
   a background job, and the database row carries an OCR *state* (pending,
   done, failed, no text found), never just a text column. Without the state, an
   empty search result is indistinguishable from "not indexed yet".
3. **Two-tier OCR is affordable.** `.fast` at 20.7 ms with 82% whole-line
   accuracy can run almost immediately to make a capture searchable within a
   frame or two, with `.accurate` at 198 ms replacing it shortly after. This is
   optional, and it doubles the state machine, so it is not in v1.

### Offline: confirmed, and by an external control

Re-running the whole probe under `sandbox-exec` with `(deny network*)`
(`nonet.sb`, driven by `run.sh`) gives the same numbers: `.accurate` median
**197.2 ms**, `.fast` median 19.0 ms. Vision does no network work.

### Fail on purpose: confirmed

A solid black 2940x1912 image returns **0 observations, 0 characters, 48.1 ms**.
It did not invent text. A hit therefore means something.

---

## A9: bounding boxes, and the feature this cuts down

Conversion is `NormalizedRect.toImageCoordinates(size, origin: .upperLeft)`.

Line-level accuracy is excellent. Truth boxes are typographic (ascender top,
advance width); Vision returns a slightly padded ink box, so a few pixels of
difference is expected and correct:

| id | truth (x,y,w,h) | vision (x,y,w,h) | dx | dy | dw | dh |
|---|---|---|---|---|---|---|
| title | 1300, 318, 278, 28 | 1299, 316, 282, 31 | -1 | -2 | 4 | 3 |
| sidebar-1 | 480, 500, 98, 26 | 479, 499, 103, 26 | -1 | -1 | 5 | 0 |
| label-1 | 1000, 736, 151, 26 | 1000, 734, 158, 26 | 0 | -2 | 7 | 0 |
| fieldtext-3 | 1384, 998, 173, 26 | 1372, 994, 188, 30 | -12 | -4 | 15 | 4 |

Worst observed offset is 12 px horizontal on a comma-separated string. Good
enough to draw a highlight over a line.

### The limit, measured by counting boxes

For each line, ask `boundingBox(for:)` for every character range and count the
**distinct** boxes returned:

```
 13 chars,  1 words,  1 distinct boxes   "192.168.1.113"
 11 chars,  2 words,  3 distinct boxes   "Subnet Mask"
 46 chars,  7 words,  8 distinct boxes   "Settings apply to the selected interface only."
 68 chars, 12 words, 13 distinct boxes   "is renewed. If the router does not respond wit..."

lines returning more than one distinct box: 18/26
```

**The distinct-box count tracks the word count, never the character count.**
Ask for one character and you get the box of the word it sits in.

**Design consequence, and it removes a feature from the plan:** a caret placed
between two letters of the same word is not available from Vision. Selectable
text in the editor is **word-level at best**. Selection snaps to word
boundaries, and the UI must make that obvious rather than pretend to be a text
editor and then behave strangely. Do not promise character selection.

---

## A10: barcode and QR in the same pass

One `VNImageRequestHandler`, two requests.

| | text only (`.accurate`) | text + barcode |
|---|---|---|
| median, 20 runs | 194.7 ms | 199.0 ms |

**Added cost: +4.2 ms, 2.2%.** In the offline repeat the difference was inside
the noise (-4.7 ms), which is the same conclusion stated more strongly: barcode
detection is free relative to text recognition.

Correctness:

- A generated QR (`CIQRCodeGenerator`, 324x324, payload `SNAPR-PROBE-A10`)
  decoded to **exactly** that payload, symbology `qr`, confidence 1.000.
- Composited into the fixture, one handler returned **26 text lines and 1
  barcode** together, located at top-left pixel (86, 1736, 108, 110).
- **Fail path confirmed:** the fixture's deliberate 220x220 black-and-white
  noise block returned **nothing**. The detector did not hallucinate a QR out of
  high-frequency noise.

**Design consequence:** always run barcode detection alongside text. It costs
2% of a pass that is already happening in the background, and it makes "there is
a QR code in this screenshot" a searchable fact for free.

---

## Privacy note that applies to every one of these numbers

The fixture is synthetic on purpose. No real screenshot of the user's machine
was given to any probe, and no probe logs recognised text from a real capture.
The counts above are counts of a string this repository generated.
