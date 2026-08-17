# A14 follow-up: edge snap on REAL macOS windows

Measured 2026-08-17, after 0.1.0 shipped. Probe `probes/edges/realsnap/main.swift`,
running the **shipping** `EdgeSnap` code unmodified against real captures of
Snapr's own windows. Raw output in `real-results.txt`.

Our own UI on purpose: it is real AppKit rendering with real vibrancy, rounded
corners and anti-aliasing, and it contains none of the user's content, so the
overlay images are safe to keep.

**This closes the caveat the design left open**, and the caveat was right:

> "That fixture is synthetic and its elements are flat solid colours. Real macOS
> windows have vibrancy, gradients, drop shadows and a wallpaper showing
> through. 0.961 will fall on real windows."

It did not fall. It collapsed, and then a bug fix recovered about half of it.

---

## The headline

| | synthetic fixture | real windows, before | real windows, after |
|---|---|---|---|
| controls hit | **20/22 (91%)** | **1/18 (6%)** | **8/18 (44%)** |
| false accepts | 0 | 0 | 0 |

**Edge snap is a genuinely weaker feature than the synthetic probe suggested.**
It is now useful rather than broken, and it is still nowhere near 91%.

---

## The first measurement was wrong, and it is rule 4 again

The first pass seeded a uniform 475-point grid across each window and reported a
**1% accept rate**. That number is meaningless. Most of a window is empty
background, where refusing to snap is the **correct** answer, so the grid was
measuring "how much of a window is empty", not "does the snap work".

The rewrite seeds on named controls whose positions were read off the rendered
window, so a refusal is a real miss. Same code, honest question.

---

## What the diagnosis found, and it was not what I expected

The obvious suspect was the colour tolerance. It was not. Sweeping it from 8 to
96 changed nothing useful:

```
tolerance   controls hit   false accepts
8           0/7            0/1
24          0/7            0/1
96          0/7            0/1
```

The give-away was in the rectangles themselves. Printing the flood result **even
on a refusal** (the first version only printed it on success, which hid this
completely) showed:

| control | flood found | actually is | verdict |
|---|---|---|---|
| tile 1 thumbnail | **394x322** | ~395x330 | refused, support **0.02** |
| search field | **1410x50** | ~1410x45 | refused, support **0.01** |
| colour swatch | 66x34 | ~70x34 | accepted |

**The flood fill was finding the right rectangles and the acceptance test was
throwing them away.**

### Two causes, both real

1. **An off-by-one between `snap` and `sideSupport`.** `snap` grows the flood
   bounds by one pixel before returning, because on the synthetic fixture that
   one pixel landed exactly on the element's hard border. `sideSupport` then
   compared two touching pixels across a boundary that had already moved, so it
   was comparing two pixels of background against each other. No step, support
   0.02, correct answer discarded.

2. **Real controls have no hard edge.** They are rounded, anti-aliased and
   often semi-transparent over vibrancy, so the change in brightness is spread
   over two or three pixels instead of landing in one step. The synthetic
   fixture had hard one-pixel borders, which is precisely the case a
   two-pixel test handles and real UI never is.

### The fix

`sideSupport` now compares a **band** of three pixels just inside the edge
against a band just outside it, instead of two touching pixels.

```
history window : 0/7  -> 3/7
editor window  : 1/11 -> 5/11
false accepts  : 0    -> 0     (the negative cases still refuse)
```

All 70 existing core tests still pass, including `flatScreenIsRejected` and
`desktopBesideWindowIsRejected`. That mattered: the acceptance test has to
refuse empty desktop and accept a soft-edged control at the same time, and those
pull in opposite directions.

### The regression test, and the control that corrected me

The first synthetic reproduction used an edge ramp with steps of 10 shades. The
test passed, and then its own control failed: the **old** two-pixel test scored
**1.00** on that ramp, so it would have accepted it too, so the test proved
nothing about the bug.

Steps of **three** reproduce it, because 3 is below the threshold of 4. Real
vibrancy moves a shade or two per pixel, which is exactly what slips under a
single-step test. That is now `softEdgedControlIsAccepted`, with the control
assertion kept in so the test cannot quietly stop testing anything.

---

## What still does not work, stated plainly

**Small toolbar icon buttons.** The flood returns the icon, not the button:

| control | flood found | actually is |
|---|---|---|
| select button | 16x26 | ~60x34 |
| box button | 27x21 | ~60x34 |
| line width "4" | 15x20 | ~50x34 |
| copy button | 17x23 | ~60x34 |

The cause is the seed, not the fill. `modalColour` samples a 5-pixel radius
around the cursor, and in the middle of an icon button every one of those pixels
belongs to the **glyph**. So the fill floods the glyph and stops at its
anti-aliased edge, which is a real boundary, just not the one the user meant.

**Large flat regions that reach the window edge**, such as the title bar and the
header strip, still flood to the whole image and are refused by the border rule.
Refusing is better than a wrong answer, but the user gets nothing.

---

## Recommendation, and it is a product decision rather than a bug

44% on real controls is not a feature anyone should discover by accident.

1. **Ship the fix.** It is strictly better, costs nothing, and has no false
   accepts. Done.
2. **Do not describe edge snap as the marquee feature it was going to be.** The
   README and design were written against 0.961 on a synthetic fixture. Both
   have been corrected to carry the real number.
3. **The technique that would actually work is the accessibility API.**
   `AXUIElementCopyElementAtPosition` returns the true frame of the control
   under the cursor, because the OS already knows it. Snapr deliberately avoids
   the Accessibility grant (A6 proved hotkeys do not need it), so adopting this
   means asking for a second permission. That is a real trade and belongs to the
   repository owner, not to a probe.
4. **A free intermediate step exists.** `SCShareableContent` already returns
   exact window frames, at no extra permission cost, and `listWindows()` already
   fetches them. Snapping the selection to a **window** would be exact rather
   than 44%, and "select this window" is the most common case by a wide margin.
   This is the obvious next piece of work.
