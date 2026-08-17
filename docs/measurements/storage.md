# A11, A12, A13 results: storage, encryption and search

Measured 2026-08-17. Probe `probes/storage/`, SwiftPM package depending on
`sqlcipher/SQLCipher.swift` 4.17.0. Full raw output in `run-output.txt`.
Total probe runtime 17.4 s.

| # | Assumption | Verdict |
|---|---|---|
| A11 | SQLCipher builds from SwiftPM and actually encrypts | **TRUE** |
| A12 | Encrypted screenshot storage is fast enough for a scrolling grid | **TRUE**, and it picked the design |
| A13 | FTS5 over OCR text finds old rows, not just recent ones | **TRUE**, with a required sanitizer |

---

## A12: the design comparison

200 real-sized screenshots, 250 KB to 8 MB each.

| metric | D1: PNG blob inside SQLCipher | D2: AES-GCM files + SQLCipher index |
|---|---|---|
| total on disk | 529.5 MB | **504.3 MB** |
| insert, median | 6.12 ms | **0.81 ms** |
| insert, p95 | 39.0 ms | **5.64 ms** |
| 30 grid thumbnails | 29.6 ms | 27.2 ms |
| per thumbnail | 1.00 ms | 0.94 ms |

Both designs are fast enough for the grid. About 16 thumbnails fit in one
16.7 ms frame either way, so scrolling is comfortable and this is **not** the
deciding factor.

### The pre-rendered thumbnail, measured rather than assumed

Decoding the full original for each grid tile instead of a stored thumbnail:

| | D1 | D2 |
|---|---|---|
| 30 tiles, full decode | 1004.9 ms | 1119.4 ms |
| per tile | 31.47 ms | 35.09 ms |
| **speedup from a stored thumbnail** | **32.1x** | **36.9x** |

**Design consequence:** store a small pre-rendered thumbnail as its own blob.
The obvious shortcut costs 30x and it is now a number, not an opinion.

### The result that actually decided it, and it is about integrity, not speed

Corruption handling. Four cases per design.

| | corrupted bytes |
|---|---|
| **D2** AES-GCM sealed file | **threw on all four**: body bit-flip, tag bit-flip, truncation, wrong key. Every one surfaced as `authenticationFailure` |
| **D1** blob inside SQLCipher | **FAIL.** Flipping one bit at byte offset 81997 inside a 1.57 MB database page read the blob back as **1,600,000 bytes with no error at all** |

AEAD overhead is 28 bytes on a 4126-byte payload.

**Chosen: Design 2.** It is 7.5x faster to insert, slightly smaller on disk, and
authenticated encryption converts silent corruption into a loud, catchable
failure. A screenshot library that hands back garbage without saying so is
exactly the class of silent failure this project exists to avoid.

---

## A13: FTS5 search over OCR text

5000 synthetic OCR documents, average 672 characters (~3.21 MB of text). A
unique phrase `zarquon vexilliform anomaly` planted in **document 1 only**, the
oldest row.

| | |
|---|---|
| index build | **21 ms for 5000 rows** (0.004 ms/row) |
| index size on disk (contentless FTS5, encrypted) | 1.32 MB for 3.21 MB of text |
| finding the phrase in the oldest row | **1 hit, 0.060 ms** |

### The bug shape this specifically rules out

The previous app searched by scanning the newest 500 rows in memory.

```
newest-500 window contains rowid 1: NO
scan-newest-500       -> 0 hits, and says nothing was found
FTS5 MATCH            -> 1 hit
```

That is the difference the old bug hid: a search that returns zero looks
identical to a search that found nothing.

### Query timings, 5000 rows

| query | hits | median |
|---|---|---|
| common word `button` | 3857 | 1.996 ms |
| common word `the` | 3827 | 1.898 ms |
| prefix `connect*` | 3816 | 2.006 ms |
| AND of two common words | 2996 | 1.744 ms |
| rare phrase, oldest row | 1 | **0.010 ms** |
| prefix `z*` | 1 | 0.009 ms |
| top-50 by rank | — | 1.599 ms |

Under 2 ms at the worst. As-you-type search is comfortable.

### The fail-on-purpose control fired

`MATCH '"quilliflange nonesuch tesseract"'` returned **0 hits in 0.015 ms**, and
the same three words in reversed order also returned 0, so phrase order is
respected. A hit means something.

---

## The most useful thing A13 found, and it was not on the assumption list

**23 of 29 realistic user inputs make FTS5 throw.**

Every query is a bound parameter, so SQL injection was never the risk. FTS5
**expression parsing** is. A user typing a single apostrophe gets
`SQLITE_ERROR fts5: syntax error near "'"`.

Inputs that throw: empty string, a single space, an apostrophe, a double quote,
an unclosed quote, `*` alone, a leading `*`, `^`, `-` alone, `word -`, `- word`,
`col:`, `(`, `()`, bare `AND`, trailing `AND`, bare `NOT`, unclosed `NEAR`,
`%`, `_`, `\`, `{}`, and a null-ish string.

None crashed the process. Every one surfaced as a catchable `SQLiteError`. But
a search field that throws when the user types an apostrophe is broken.

### The sanitizer, measured against all 29 inputs

> Never pass raw user text to `MATCH`. Split on non-alphanumerics, quote each
> token, append `*` to the last token for as-you-type prefix search. An empty
> token list means skip the query entirely rather than run an empty one.

```
(empty string)          -> (empty, skip query)
normal words            -> "button" "toolbar"*        2996 hits
SQL metachars           -> "DROP" "TABLE" "ocr"*         0 hits
single quote            -> "it" "s"                      0 hits
leading asterisk        -> "button"*                  3857 hits
emoji                   -> "button"*                  3857 hits
```

```
after sanitizing, inputs that still throw: NONE
sanitizer still finds the oldest row:      YES
```

**Design consequence:** the sanitizer is not optional polish, it is the only
thing standing between the search field and a thrown error on an apostrophe.
It ships in the core module with its own test covering all 29 inputs.

---

## Cleanup

The probe's work directory reached 1524 MB (503 MB staging PNGs, 503 MB
encrypted blobs, plus databases). It is under `probes/storage/work` and
`probes/storage/.probe-scratch`, both gitignored. Delete after reading.
