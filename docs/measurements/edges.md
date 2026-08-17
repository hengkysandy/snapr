# A14 results: smart edge snap

Measured 2026-08-17. Probe `probes/edges/probe.swift`, run against the synthetic
fixture `probes/fixtures/fixture.png` (2940x1912) with `fixture-truth.json`
giving 11 ground-truth element rectangles. Overlay drawn to `snap.png`.

**Verdict: A14 is TRUE, and the winning technique is not the one I expected.**

Scoring is IoU (intersection over union) against ground truth. 1.000 is a
perfect match. Two seeds per target: a single point inside the element, and a
deliberately sloppy drag rectangle.

| Technique | mean IoU | IoU > 0.9 | median ms |
|---|---|---|---|
| T1 flood fill on colour similarity | **0.961** | **20/22** | **0.20** |
| T2 naive 4-direction ray walk | 0.795 | 12/22 | 0.00 |
| T3 iterative gradient edge scan | 0.837 | 16/22 | 0.08 |
| T4 `VNDetectRectanglesRequest` | **0.533** | **2/22** | 19.63 |
| T5 hybrid (flood + adaptive tolerance + edge support + hierarchy) | **0.961** | **20/22** | 10.35 |

Plus a one-off cost of **28.2 ms** to decode the PNG and build the luma plane,
paid once per screenshot, not per snap.

## The three results that decide the design

### 1. Vision is the wrong tool for this, by a wide margin

`VNDetectRectanglesRequest` returned 26 observations in 19.6 ms and scored
**0.533 mean IoU, 2 of 22 above 0.9**. It missed the checkbox entirely (IoU
0.001, it returned the whole window) and it inflates every box by 15 to 30 px on
each side, because it detects the shadow and the rounded corner as part of the
rectangle.

This is worth stating plainly because Vision is the obvious first thing to
reach for, it is Apple's own API, and it is the worst of the five.

### 2. Plain flood fill matches the hybrid exactly, and is 50x faster

T1 and T5 have the **same** mean IoU (0.961) and the **same** hit count (20/22).
The hybrid's adaptive tolerance, edge-support test and parent hierarchy bought
**zero accuracy** on this fixture, at 50x the cost (10.35 ms versus 0.20 ms).

So the extra machinery has to justify itself somewhere else, and it does:

### 3. The hybrid's only real job is refusing to snap

Six deliberate no-element seeds:

| seed | hybrid | naive flood would have returned |
|---|---|---|
| flat desktop, lower band | **NO SNAP** (touches image border) | `0,620 2940x1292`, 1.6 M px |
| flat desktop, upper band | **NO SNAP** | `0,50 2940x570` |
| flat desktop, right of window | **NO SNAP** | `0,620 2940x1292` |
| inside empty content pane | SNAP `940,352 1580x1228` | same |
| paragraph text, line 2 | SNAP `940,352 1580x1228` | same |
| paragraph text, rough drag | SNAP `940,352 1580x1228` | same |

Three of six rejected correctly, by the border-touch rule. The naive flood
happily returns a 1.6-megapixel rectangle of empty desktop and reports nothing
wrong. **That is the whole value of the hybrid: it turns a confidently wrong
answer into no answer.**

**Design consequence:** run T1 flood for the snap itself (0.20 ms, so it can run
on every mouse move), and run the hybrid's acceptance test on the result before
showing it. If the test fails, show no snap indicator at all rather than a
wrong one.

## Text is a separate case, and the probe found it

The last three negatives are not really failures. `940,352 1580x1228` is the
content pane, which genuinely is the element under those points. But a user
pressing snap while pointing at a paragraph wants the paragraph, not the pane.

`VNRecognizeTextRequest(.fast)` gives 26 line boxes in 38.5 ms, and the line
under the seed point scored **IoU 0.995** against the ground-truth line.
Grouping lines that overlap horizontally and sit within 30 px vertically gives a
paragraph block at **IoU 0.795**.

**Design consequence:** when the seed lands inside a Vision text box, snap to
the text line first, the grouped block on a second press, and only then the
flood component. Text lines are already computed by the OCR pass (A8), so the
38.5 ms is not new work on the snap path.

## The hierarchy works, with one honest caveat

Pressing snap again should grow the selection. It does:

```
checkbox         L0 1002,1102 34x34 (IoU 1.000) | L1 window | L2 whole screen
sidebar-selected L0 444,378 472x62 (IoU 1.000)  | L1 sidebar | L2 content area
field-0          L0 778x64 (0.967) | L1 782x68 (0.968) | L2 window | L3 screen
```

Caveat: level 1 is often a **large** jump, not the visually obvious parent. For
the title bar, L1 is `0,50 2940x1530`, the whole desktop band, IoU 0.043. So
"press again to grow" is honest, but it is not a tidy view hierarchy. Two or
three levels is all that is useful; do not build a deep breadcrumb on it.

## The limitation that matters most, stated rather than hidden

**This fixture is synthetic and its elements are flat solid colours.** Real
macOS windows have vibrancy, translucency, gradients, drop shadows, rounded
corners and a wallpaper showing through. Flood fill on colour similarity is at
its easiest here and will be at its hardest there.

So this result proves the approach is **worth building**, at a cost of 0.2 ms
per snap, with a rejection path that already works. It does **not** prove
0.961 mean IoU against real windows. That number will fall. The design must
therefore treat the snap as a suggestion the user can ignore, never as an
automatic selection, and the acceptance test must stay in.

## Rejected outright

`VNDetectRectanglesRequest`. Measured, scored, 0.533. Not used.
