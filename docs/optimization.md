# xsComic optimization record

This document records the starting point, the optimization design, and the
measurement procedure for Comic Book Reader. The goal is a responsive native
reader with a small distributed executable, fixed resource bounds, and no lost
reader functionality.

`Metrics/baseline.json` preserves measurements from the initial workspace
snapshot.
`Metrics/optimized.json` is the definitive clean optimized run from
2026-07-25 14:01 PDT.
`Metrics/features.json` is the clean feature-complete run from
2026-07-25 15:00 PDT. It adds source-size accounting to the same harness.
`Metrics/quality.json` is the structural code-quality run from
2026-07-25 15:51 PDT.
`Metrics/branding.json` records the approved primary branding assets from
2026-07-25 16:49 PDT.
`Metrics/alternate-icon.json` records the optional alternate-icon feature from
2026-07-25 18:08 PDT.
`Metrics/readability.json` is the heavily annotated readability pass from
2026-07-25 20:49 PDT.
`Metrics/release.json` is the organized, xsComic-branded release-preparation
run from 2026-07-25 21:31 PDT.
`Metrics/icon-mask.json` is the current-macOS icon-geometry correction from
2026-07-25 21:51 PDT.

## Summary

The optimized result moves archive and image work out of the UI path,
adds viewport-sized decoding and a strictly bounded cache, and packages a
stripped `-Osize` executable. Against the initial workspace snapshot:

- The 4,096-page directory scan median fell from 562.619 ms to 82.821 ms:
  85.28% less time, or 6.79 times the throughput.
- The signed executable fell from 379,536 bytes to 235,936 bytes: 143,600
  bytes, or 37.84%, smaller.
- The logical app bundle fell from 383,166 bytes to 239,628 bytes: 37.46%
  smaller.
- The decoded-image cache budget fell from 256 MiB to a strict 64 MiB and
  12-entry ceiling.
- The reader now prepares eight pages ahead and two pages behind.
- A two-consecutive-backward-turn predictor improves simulated constrained
  rereading; controlled stripped builds have priced it at only 16–24 bytes.
- The compatibility ZIP fell from 101,113 to 99,628 bytes: 1.47% smaller.
- At that optimized-control checkpoint, the smallest distribution was an
  83,904-byte `.tar.xz`, 15.78% smaller than its compatibility ZIP and 17.02%
  smaller than the initial snapshot's ZIP.

The `.tar.xz` comparison to the baseline ZIP is explicitly cross-container:
the initial snapshot did not preserve a tar/XZ package. Both optimized archives
contain the same signed app; the ZIP remains for broader convenience.

## Feature expansion budget

The second pass adds a page-index sidebar, inline and menu-driven page jumping,
bidirectional adjacent-volume continuation, Command-0 zoom-to-window, and
trackpad pinch zoom. The comparison below uses the optimized reader immediately
before those features as the control, so it isolates feature cost rather than
repeating the less reproducible initial baseline comparison.

| Metric | Optimized control | Feature-complete | Change |
| --- | ---: | ---: | ---: |
| Production Swift files | 5 | 5 | no change |
| Production source | 1,215 lines | 1,461 lines | +246 (+20.25%) |
| Production source bytes | 41,996 B | 50,809 B | +8,813 B (+20.99%) |
| Signed executable | 235,936 B | 282,320 B | +46,384 B (+19.66%) |
| Logical app bundle | 239,628 B | 286,012 B | +46,384 B (+19.36%) |
| Distribution ZIP | 99,628 B | 120,032 B | +20,404 B (+20.48%) |
| Distribution tar/XZ | 83,904 B | 100,560 B | +16,656 B (+19.85%) |
| Dynamic dependencies | 25 | 25 | no change |
| Image-cache budget | 64 MiB / 12 entries | 64 MiB / 12 entries | no change |
| Prefetch window | 8 forward / 2 back | 8 forward / 2 back | no change |
| Correctness tests | 25 | 29 | +4 |

The feature-complete implementation at this checkpoint remains five files and
has no new dependency, persistence layer, watcher, background directory index,
or unbounded collection. The sidebar is a lazy numbered index instead of a
thumbnail browser: an otherwise identical probe showed thumbnail loading added
4,448 executable bytes and would also retain extra decoded images. Adjacent
volumes are enumerated only on an attempted boundary turn.

Size probes also prevented attractive but expensive abstractions from being
accepted on intuition:

- `NavigationSplitView` plus `List` saved only 608 bytes when replaced with the
  explicit lazy stack; the split view was not the main cost.
- A native AppKit adapter for the editable page indicator produced a
  283,936-byte executable, 5,840 bytes larger than the equivalent SwiftUI
  editor in the same no-thumbnail candidate, while requiring substantially
  more source.
- The required magnification gesture accounts for about 5,136 executable bytes.
  It is retained; fit-mode pinches begin at the actual fitted scale to avoid a
  visible jump to 1:1.

These exploratory probes were same-machine release builds, not published
immutable snapshots. The named `Metrics/*.json` checkpoints are the definitive
artifact records.

The feature-complete 4,096-page scan median was 120.364 ms versus 82.821 ms in
the optimized control; 128-page CBZ opening was 130.286 ms versus 117.759 ms.
Those are 45.33% and 10.64% slower in separate short benchmark runs. No new
work was added to either normal hot path, and consecutive feature-candidate
runs ranged from 88.774 to 120.364 ms for the same scan, demonstrating
substantial host-load variance. The figures are recorded rather than
overinterpreted; deterministic resource limits and predictor replay results
are unchanged.

## Code-quality pass

The quality pass uses the feature-complete snapshot as its control. It
reworks ownership, geometry, cache invariants, and verification structure
without changing the reader's feature set or resource policy.

| Metric | Feature-complete | Quality pass | Change |
| --- | ---: | ---: | ---: |
| Production Swift files | 5 | 6 | +1 |
| Production source | 1,461 lines | 1,558 lines | +97 (+6.64%) |
| Production source bytes | 50,809 B | 52,875 B | +2,066 B (+4.07%) |
| Signed executable | 282,320 B | 277,680 B | -4,640 B (-1.64%) |
| Logical app bundle | 286,012 B | 281,372 B | -4,640 B (-1.62%) |
| Distribution ZIP | 120,032 B | 118,646 B | -1,386 B (-1.15%) |
| Distribution tar/XZ | 100,560 B | 100,216 B | -344 B (-0.34%) |
| Mach-O `__text` | 161,040 B | 159,584 B | -1,456 B (-0.90%) |
| Dynamic dependencies | 25 | 25 | no change |
| Correctness tests executed | 29 | 33 | +4 |

The added production file is `PageCanvas.swift`, a deliberate responsibility
boundary: window/sidebar/toolbar state remains in `ReaderView`, while spread
geometry, progressive image presentation, decode sizing, scrolling, and pinch
zoom live together in the canvas. This is the main source-count increase. The
split remained only after the packaged artifacts measured smaller than the
control.

The production cleanup also:

- collapses actual size into the existing custom scale of one, removing a
  second representation of the same zoom state;
- computes fit geometry once, including only real inter-page spacing, and
  derives pinch scale from the largest dimensions across every visible page;
- replaces the image view's independent page/failure flags with one phase,
  making impossible UI states unrepresentable;
- makes the single shared reader's single-window ownership explicit;
- removes a redundant result-task handle and validates page numbers before
  subtraction, including `Int.min`;
- eliminates a cache-eviction temporary allocation, bounds negative-cache
  entries intrinsically, protects visible detail requests with the preview's
  retention rank, and tightens canceled coalesced-request handling;
- uses checked `Sendable` conformance for immutable archive books, honors
  cancellation around natural sorting, and skips package, empty, and unrelated
  directories while searching for the next usable volume.

The verification code received the same treatment. Image and ZIP fixtures now
live in shared test support; the ZIP helper drains diagnostics while the child
process is running. Build and measurement scripts share one path-safety/lock
module. Output and scratch paths must be disjoint, historical metric labels
refuse accidental replacement, and the metrics harness reads cache/prefetch
policy values emitted from production constants instead of duplicating them.

Two attractive additions failed the size gate. Waiting on retired decode-task
handles before temporary-file cleanup added 4,160 executable bytes, so the
existing generation/cancellation design and host POSIX file semantics remain.
A focus-loss observer for the page editor added 80 executable bytes and 544
bytes of `__text` for a minor convenience, so explicit submit and Escape remain
the editor's state transitions.

The quality run's timing medians were also lower: 118.038 ms for the 4,096-page
scan, 129.025 ms for 128-page CBZ opening, 24.375 ms for cold preview decode,
and 1.051 µs for a cache hit. The corresponding feature-control values were
120.364 ms, 130.286 ms, 25.557 ms, and 1.125 µs. These short runs were not
interleaved, so the exact artifact-size reductions are treated as definitive
while timing changes are recorded as encouraging, environment-sensitive
observations.

## Annotated readability pass

This pass uses the immediately preceding alternate-icon snapshot as its
control. It deliberately accepts a large repository-source increase in return
for source that explains itself, while holding the shipped program to the same
size and runtime limits.

| Metric | Alternate-icon control | Readability pass | Change |
| --- | ---: | ---: | ---: |
| Production Swift files | 6 | 6 | no change |
| Production source | 1,571 lines | 2,679 lines | +1,108 (+70.53%) |
| Production source bytes | 53,500 B | 109,761 B | +56,261 B (+105.16%) |
| Signed executable | 281,888 B | 281,888 B | no change |
| Logical app bundle | 411,925 B | 411,925 B | no change |
| Distribution ZIP | 207,599 B | 207,622 B | +23 (+0.011%) |
| Distribution tar/XZ | 188,704 B | 188,700 B | -4 (-0.002%) |
| Mach-O `__text` | 161,936 B | 162,016 B | +80 (+0.049%) |
| Dynamic dependencies | 25 | 25 | no change |
| Correctness tests executed | 33 | 33 | no change |
| Cache / prefetch policy | 64 MiB, 12 entries, 8 ahead / 2 back | same | no change |

Comments disappear before code generation. The 80-byte `__text` movement comes
from the one intentional production refinement in this pass: an ordinary
launch now trusts the bundle-provided primary icon instead of reopening and
decoding its ICNS. The primary file is loaded only when a running user switches
back from the alternate icon. Mach-O alignment absorbed those instructions, so
the signed executable and logical bundle did not grow. The 23-byte ZIP and
4-byte tar/XZ movements are compression-level consequences, not added files.

The annotations follow the program's actual ownership boundaries:

- `ComicBookReaderApp` explains scene lifetime, durable settings, command
  routing, and the narrow runtime-icon bridge.
- `ReaderModel` states the archive-order/page-spread equations, transactional
  replacement protocol, generation checks, and the bounded predictor.
- `ArchiveBook` documents borrowed versus owned filesystem trees, extraction
  cancellation, natural sorting, and cleanup.
- `PageImageStore` records cache and in-flight-memory bounds separately,
  coalescing and stale-result rules, retention-aware LRU, GIF accounting, and
  the two-permit decode gate.
- `ReaderView` and `PageCanvas` explain lazy UI construction, edit-focus events,
  viewport-to-decode arithmetic, bucketed zoom, progressive loading, and native
  pinch/pan composition.
- Tests describe the invariant each fixture protects; build scripts narrate
  their safety and reproducibility transactions. A 127-byte `.swift-format`
  policy preserves four-space indentation and intentional paragraph comments.

The audit also turned prose discrepancies into small maintenance fixes. The
predictor snapshot now includes assets; external SwiftPM scratch ownership is
bound to directory device/inode identity; app bundles are assembled and signed
beside the published product before replacement; the launcher honors its output
override, identifies the exact executable path, and checks sustained startup;
and vectorization validates nonempty Potrace paths before an atomic file rename.
These changes affect development machinery, not the distributed executable.

The same-source predictor A/B was 261,552 B static versus 261,568 B adaptive:
a **16-byte** file delta and 160-byte `__text` delta, or 0.10% of the 15 KiB
ceiling. The replay remained 21 winning, zero losing, and 139 tied cases.

Timing medians were 82.094 ms for the 4,096-page scan, 119.360 ms for 128-page
CBZ opening, 16.600 ms for cold preview decode, and 0.790 µs for a cache hit.
The immediate control measured 79.746 ms, 114.848 ms, 16.746 ms, and 0.797 µs.
Those short, non-interleaved changes are +2.94%, +3.93%, -0.87%, and -0.88%;
no measured hot-path code or resource policy changed, so they are recorded as
environment-sensitive variation rather than attributed to comments.

## Release-preparation pass

This pass reorganizes repository-only material and completes the xsComic
release identity. `script/` and `scripts/` became one `scripts/` directory,
optimization history moved under `docs/`, and a small root README now points to
the project guide, release procedure, and measurement record. Documentation is
excluded from the source digest and app bundle, so the new manual has zero
distributed-byte cost.

The user-facing window, bundle, and archive names now consistently say
`xsComic`; the internal `ComicBookReader` Swift module and executable remain
stable to avoid a source-wide mechanical rename. `VERSION` is the one release
version source. The build script validates version/build/bundle-ID inputs and
supports Developer ID signing with hardened runtime and timestamp while keeping
ad-hoc signing as the credential-free local default.

Against the immediately preceding readability checkpoint:

| Metric | Readability pass | Release preparation | Change |
| --- | ---: | ---: | ---: |
| Production Swift files | 6 | 6 | no change |
| Production source | 2,679 lines | 2,679 lines | no change |
| Production source bytes | 109,761 B | 109,741 B | -20 B |
| Signed executable | 281,888 B | 281,872 B | -16 B |
| Logical app bundle | 411,925 B | 411,883 B | -42 B |
| Distribution ZIP | 207,622 B | 207,515 B | -107 B |
| Distribution tar/XZ | 188,700 B | 188,652 B | -48 B |
| Mach-O `__text` | 162,016 B | 162,016 B | no change |
| Dynamic dependencies | 25 | 25 | no change |
| Correctness tests executed | 33 | 33 | no change |
| Cache / prefetch policy | 64 MiB, 12 entries, 8 ahead / 2 back | same | no change |

The tiny reductions come from shorter user-facing strings and archive metadata;
there is no new runtime logic in a measured hot path. The release median timings
were 99.096 ms for the 4,096-page scan, 119.186 ms for 128-page CBZ opening,
18.496 ms for cold preview decode, and 0.946 µs for a cache hit. As with earlier
non-interleaved runs, these figures are recorded rather than attributed to
repository organization.

The packaged primary icon was independently checked against the repository
ICNS byte for byte, expanded successfully into all ten required iconset
members, referenced by `CFBundleIconFile`, covered by a valid strict code
signature, and present in both archive formats. The app also passed a sustained
launch smoke test under its final `xsComic.app` name.

Source-digest schema v4 adds `VERSION` to the v3 input set. The release digest
is `8d7dc55b549c136311ec9a40588a05c1f21ea71851751f021dc1a93d77186ec2`.

## Current-macOS icon correction

Current macOS applies the rounded-square mask to the supplied full-square icon
artwork. The earlier xsComic mark also drew its own navy rounded enclosure, so
the system produced a visibly inset "icon within an icon." This pass removes
only that redundant enclosure and enlarges the unchanged character and pixel
signature by eight percent. The same geometry correction applies to the
alternate icon.

The ICNS generator now writes its compact PNG chunks directly, while asking
Apple's asset compiler only for the two legacy compressed-ARGB records used by
non-Retina 16- and 32-pixel icons. `iconutil` then independently unpacks the
completed file and the build refuses publication unless all ten named
renditions are present. This preserves correct legacy rendering and keeps the
large fallback planes palette-compressed.

| Metric | Release preparation | Corrected icon | Change |
| --- | ---: | ---: | ---: |
| Primary ICNS source | 116,528 B | 73,859 B | -42,669 B (-36.62%) |
| Signed executable | 281,872 B | 281,872 B | no change |
| Logical app bundle | 411,883 B | 368,797 B | -43,086 B (-10.46%) |
| Distribution ZIP | 207,515 B | 176,739 B | -30,776 B (-14.83%) |
| Distribution tar/XZ | 188,652 B | 158,112 B | -30,540 B (-16.19%) |
| Mach-O `__text` | 162,016 B | 162,016 B | no change |
| Correctness tests executed | 33 | 33 | no change |
| Cache / prefetch policy | 64 MiB, 12 entries, 8 ahead / 2 back | same | no change |

The source digest is
`b0a723f85aaabc54ea9dc4a41d48cfca6e503e14504ab62e88c530616e083d57`.
All ten primary renditions and both final vector compositions were visually
inspected; the smallest legacy records were expanded with nearest-neighbor
scaling so palette or channel corruption could not hide behind interpolation.

The timing medians were 90.234 ms for the 4,096-page scan, 121.425 ms for
128-page CBZ opening, 17.453 ms for cold preview decode, and 0.810 µs for a
cache hit. No runtime source changed, so these non-interleaved differences are
host variation rather than an icon effect.

### System icon plate

The compact ICNS alone still enters the legacy-icon path on current macOS,
which places its full square canvas inside a second system plate. The app now
also ships a 140,472-byte `Assets.car` and declares `CFBundleIconName`. It is
generated from the same ten renders, in RGBA form because Apple's asset
compiler does not reliably accept the indexed large planes used inside the
ICNS. The ICNS remains present as the older-system fallback.

This is deliberately a packaging-only expense: the executable, launch path,
and runtime memory policy are unchanged. The final signed app was copied under
a fresh bundle identifier and rendered through `NSWorkspace`; that system
render shows one correctly filled rounded plate, rather than judging the raw
source image or trusting the asset compiler's exit status.

| Metric | Compact fallback only | System-native icon | Change |
| --- | ---: | ---: | ---: |
| Modern icon catalog | 0 B | 140,472 B | +140,472 B |
| Signed executable | 281,872 B | 281,872 B | no change |
| Logical app bundle | 368,797 B | 509,551 B | +140,754 B (+38.17%) |
| Distribution ZIP | 176,739 B | 286,185 B | +109,446 B (+61.92%) |
| Distribution tar/XZ | 158,112 B | 243,348 B | +85,236 B (+53.91%) |
| Mach-O `__text` | 162,016 B | 162,016 B | no change |
| Correctness tests executed | 33 | 33 | no change |
| Cache / prefetch policy | 64 MiB, 12 entries, 8 ahead / 2 back | same | no change |

The final source digest is
`3dc5648f695a8614db8df4c9ae0e9d7f4d76b51a81e463451b3c86c955803cf9`.
Benchmark medians were 90.305 ms for the 4,096-page scan, 113.668 ms for
128-page CBZ opening, 18.319 ms for cold preview decode, and 0.827 µs for a
cache hit. The prefetch replay retained 21 wins and zero losses.

### Runtime alternate mask

`NSApplication.applicationIconImage` is a different contract from a bundle app
icon: AppKit treats the assigned `NSImage` as final artwork and does not apply
the current system plate. The alternate SVG now clips its otherwise unchanged
composition to one compact continuous-corner path. When the setting is turned
off, the app clears the override instead of loading the raw primary ICNS, so
the modern catalog resumes control and supplies the system-rendered primary.

The clip costs one SVG path and no resident framework or raster icon family.
An AppKit decode verified a fully transparent corner; an application-icon
round trip verified that clearing the override restores the exact original
bundle image bytes rather than retaining the alternate.

The mask alone initially left the alternate composition at full canvas scale,
whereas the system shrinks the entire primary composition into its plate. A
single centered 0.8046875 transform now reproduces that inset without changing
any internal proportions. At 1,024 pixels, the two book tops align at about
`y=565`, hands occupy roughly `y=655...724`, feet run from about `y=746...849`,
and eye heights differ by only a few pixels. Hair and clothing are intentionally
excluded from this comparison.

| Metric | Rounded alternate control | Proportion-aligned alternate | Change |
| --- | ---: | ---: | ---: |
| Signed executable | 281,872 B | 281,872 B | no change |
| Mach-O `__text` | 162,000 B | 162,000 B | no change |
| Logical app bundle | 509,958 B | 510,037 B | +79 B (+0.02%) |
| Distribution ZIP | 286,385 B | 286,396 B | +11 B |
| Distribution tar/XZ | 243,576 B | 243,568 B | -8 B |
| Correctness tests executed | 33 | 33 | no change |
| Cache / prefetch policy | 64 MiB, 12 entries, 8 ahead / 2 back | same | no change |

The proportion-alignment source digest is
`7a442fb03cf590dacd0b40dc19c3cbe1e02313c426bd761b9bdd948ad968141d`.
Benchmark medians were 90.073 ms for the 4,096-page scan, 122.024 ms for
128-page CBZ opening, 19.688 ms for cold preview decode, and 0.815 µs for a
cache hit. The runtime path did not change; these timing movements are host
variation. The prefetch replay retained 21 wins and zero losses.

### Native runtime corner geometry

The hand-authored alternate mask matched the primary plate's outer bounds but
only approximated its continuous-corner radius. Keeping a traced curve would
also freeze one macOS version's geometry in source. The runtime path now uses
the alpha of `NSApplication.applicationIconImage`—the system-rendered primary
already present in the process—as the alternate's destination-in mask.

Composition is bounded to a selected-only 256-point image, sufficient for the
Dock and app switcher. No file lookup, persistent cache, second catalog, or
additional framework is involved. The SVG becomes simpler: it retains the
proportion-aligning inset but no longer contains any platform mask.

| Metric | Traced-radius control | Native runtime mask | Change |
| --- | ---: | ---: | ---: |
| Signed executable | 281,872 B | 281,872 B | no change |
| Mach-O `__text` | 162,000 B | 162,400 B | +400 B |
| Logical app bundle | 510,037 B | 509,630 B | -407 B (-0.08%) |
| Distribution ZIP | 286,396 B | 286,383 B | -13 B |
| Distribution tar/XZ | 243,568 B | 243,808 B | +240 B (+0.10%) |
| Correctness tests executed | 33 | 33 | no change |
| Cache / prefetch policy | 64 MiB, 12 entries, 8 ahead / 2 back | same | no change |

The native-mask source digest is
`6a23a5fa46739f3154425d82aa9caab40032380d25b6585d26c832f8f2a7a9cf`.
The benchmark process was under visibly higher host load: medians were 128.316
ms for the 4,096-page scan, 127.531 ms for 128-page CBZ opening, 25.727 ms for
cold preview decode, and 1.095 µs for a cache hit. The changed code is reachable
only from the settings toggle and none of these benchmark paths; the figures
are retained as measured rather than misattributed to the icon path. Prefetch
replay remained at 21 wins and zero losses.

| Metric | System-primary control | Rounded runtime alternate | Change |
| --- | ---: | ---: | ---: |
| Signed executable | 281,872 B | 281,872 B | no change |
| Mach-O `__text` | 162,016 B | 162,000 B | -16 B |
| Logical app bundle | 509,551 B | 509,958 B | +407 B (+0.08%) |
| Distribution ZIP | 286,185 B | 286,385 B | +200 B (+0.07%) |
| Distribution tar/XZ | 243,348 B | 243,576 B | +228 B (+0.09%) |
| Correctness tests executed | 33 | 33 | no change |
| Cache / prefetch policy | 64 MiB, 12 entries, 8 ahead / 2 back | same | no change |

The runtime-mask source digest is
`e0536ae8d6abad903df53c05e90694c4913d4b8515170ba766763a043331570e`.
Benchmark medians were 88.909 ms for the 4,096-page scan, 117.151 ms for
128-page CBZ opening, 16.928 ms for cold preview decode, and 0.819 µs for a
cache hit. The prefetch replay again retained 21 wins and zero losses.

## Measurement status

### Drag-to-install disk images

The release packager now produces themed, architecture-specific, read-only
LZFSE disk images without adding bytes or work to the installed application.
The background is a 41,766-byte JPEG; Finder stores the background reference,
window geometry, and optically corrected icon positions in `.DS_Store`.

| DMG | Bytes |
| --- | ---: |
| x86_64 | 392,478 |
| ARM64 | 389,284 |

Both images passed `hdiutil verify`; their mounted apps retained the expected
architecture and valid signature, and their Applications aliases resolve to
`/Applications`. Exact geometry, hashes, and source identity are recorded in
[`../Metrics/dmg.json`](../Metrics/dmg.json).

### Publication architecture comparison

The release-cleanup pass rebuilt and remeasured the native Intel product, then
cross-built the same source for ARM64. Both records share source digest
`401d1431b92055099bbbd91ec9dde12130b5327e8ada2fde39fd425286f1a9e0`.

| Distribution measure | x86_64 | ARM64 | ARM64 difference |
| --- | ---: | ---: | ---: |
| signed executable | 281,872 B | 300,928 B | +19,056 B |
| logical app bundle | 509,630 B | 528,686 B | +19,056 B |
| ZIP | 299,685 B | 295,793 B | -3,892 B |
| tar/XZ | 255,516 B | 244,264 B | -11,252 B |
| retained symbols | 611,768 B | 649,712 B | +37,944 B |
| `__text` section | 162,400 B | 161,908 B | -492 B |
| dynamic dependencies | 25 | 25 | 0 |

The larger ARM64 Mach-O compresses better, so both ARM distribution archives
are smaller despite the larger uncompressed executable. The ARM app, plist,
signature, ZIP, tar/XZ, linkage, and architecture were inspected successfully.
Each archive includes the complete AGPL text and the licensing/branding
notices; those files add nothing to the installed app bundle.
Runtime tests and timings are intentionally absent: this Intel host cannot
execute ARM64. See
[`../Metrics/release-x86_64.json`](../Metrics/release-x86_64.json) and
[`../Metrics/release-arm64.json`](../Metrics/release-arm64.json).

The baseline was captured before production-source edits, but the repository
had no commits and its exact source tree was not preserved as a digest. Archive
timing came from that source; distribution sizes came from the pre-existing
signed app bundle found in the workspace, with a lean repackage used for the
ZIP number. A later source reconstruction did not reproduce those artifact
sizes, so the baseline is explicitly observational rather than bit-for-bit
reproducible. `Metrics/baseline.json` records those limitations instead of
implying stronger provenance.

The source digest in the optimized snapshot is
`fc2247f402d7759db52e7ca39b952c6ce1f89fc0cb208aefb6f3ef099d7ad953`.
The feature-complete source digest is
`38e1b6f3c7bb51ccae30f9ee50b2cbd3218d6a328eb567e76e7448a9a04e25c5`.
The quality-pass source digest is
`de2cc13c365c904b658ebcb274a0a2fcbfc9cf3f9d194152d157a39247960b7f`.
The branding source digest is
`8e53b28b819114db736a747ed47a1bcbfcbb1cfdf283ca5eb0d79428702414e9`.
The alternate-icon source digest is
`9d3aa5b30cc621fba3bf0abec78781e8d08d5973513370204460c652f2331ea6`.
The readability-pass source digest is
`a8078e027fd780435d9b96cf42e606a608ea3e5398ecab341078281d0bd37c73`.
The release-preparation source digest is
`8d7dc55b549c136311ec9a40588a05c1f21ea71851751f021dc1a93d77186ec2`.
The corrected-icon source digest is
`b0a723f85aaabc54ea9dc4a41d48cfca6e503e14504ab62e88c530616e083d57`.
The system-native icon source digest is
`3dc5648f695a8614db8df4c9ae0e9d7f4d76b51a81e463451b3c86c955803cf9`.
The rounded runtime-icon source digest is
`e0536ae8d6abad903df53c05e90694c4913d4b8515170ba766763a043331570e`.
The proportion-aligned icon source digest is
`7a442fb03cf590dacd0b40dc19c3cbe1e02313c426bd761b9bdd948ad968141d`.
The native runtime-mask source digest is
`6a23a5fa46739f3154425d82aa9caab40032380d25b6585d26c832f8f2a7a9cf`.
The machine-readable sources of truth are `Metrics/baseline.json`,
`Metrics/optimized.json`, `Metrics/features.json`, `Metrics/quality.json`,
`Metrics/branding.json`, `Metrics/alternate-icon.json`, and
`Metrics/readability.json`, `Metrics/release.json`, and
`Metrics/icon-mask.json`, `Metrics/icon-fit.json`, and
`Metrics/runtime-icon-mask.json`, and `Metrics/icon-proportions.json`. They
also include `Metrics/native-runtime-mask.json`. These records intentionally use
metric schema versions 1 and 2: version 1 is the legacy observational baseline
shape; version 2 is the reproducible optimized harness.

The readability record uses source-digest schema v3. It differs from v2 only
by excluding `.DS_Store`, which cannot affect a build; opening a source or asset
directory in Finder therefore no longer invalidates its runtime measurement.
The release record uses source-digest schema v4, which adds the release
`VERSION` file to the hashed and snapshotted build inputs.

The reproducible snapshots used:

- macOS 26.5.1
- x86_64
- Apple Swift 6.3.2
- macOS 14.0 minimum deployment target

Timing results should only be compared on the same machine, architecture,
operating system, and Swift toolchain.

### Distribution size

| Metric | Baseline | Optimized | Change |
| --- | ---: | ---: | ---: |
| Signed executable | 379,536 B | 235,936 B | -143,600 B (-37.84%) |
| Retained symbol executable, not distributed | not captured | 488,512 B | — |
| Bundle, logical files | 383,166 B | 239,628 B | -143,538 B (-37.46%) |
| Bundle, allocated | 380 KiB | 240 KiB | -140 KiB (-36.84%) |
| Distribution ZIP | 101,113 B | 99,628 B | -1,485 B (-1.47%) |
| Distribution tar/XZ | not captured | 83,904 B | — |
| Dynamic dependencies | 23 | 25 | +2 |
| Mach-O `__TEXT` segment | 102,400 B | 167,936 B | +65,536 B |
| Mach-O `__text` section | 74,704 B | 130,608 B | +55,904 B |
| Mach-O `__DATA_CONST` | 8,192 B | 8,192 B | no change |
| Mach-O `__DATA` | 8,192 B | 12,288 B | +4,096 B |
| Mach-O `__LINKEDIT` | 278,528 B | 65,536 B | -212,992 B (-76.47%) |

The total executable is smaller even though executable code grew. The optimized
reader does more work—bounded caching, cancellation, decoding, and prefetch
scheduling—but stripping non-runtime nlist, local, and debug symbols removes
enough `__LINKEDIT` material to more than compensate. The dependency count
includes macOS platform frameworks; the project still has no third-party
runtime dependency.

This is not a self-contained microcontroller binary. AppKit, SwiftUI, Image I/O,
the Swift runtime, and `/usr/bin/bsdtar` are supplied by the compatible host
platform and are not included in the executable byte count.

### Runtime and build metrics

| Metric | Baseline | Optimized | Change |
| --- | ---: | ---: | ---: |
| 4,096-page directory scan median | 562.619 ms | 82.821 ms | -85.28% |
| Directory scan fastest / slowest | 536.727 / 575.225 ms | 80.363 / 85.567 ms | — |
| 128-page CBZ open median | not captured | 117.759 ms | — |
| 1,600×1,200 PNG to 768 preview, cold | not captured | 16.717 ms | — |
| Cached image lookup | not captured | 0.762 µs | — |
| Preview decoded bytes | not captured | 1,769,472 B | — |

Build-and-package time remains in the optimized JSON as a diagnostic but is
not compared with the baseline's differently scoped one-off build timing.
Archive and image timings use repeated samples and report medians.
Optimized process-footprint numbers are deliberately omitted because the
baseline process sample was not controlled comparably for window state and
cache contents. The 64 MiB and 12-entry store limits are deterministic policy
measurements, not sampled resident-memory estimates. Repeated local timing
runs varied with host load; the table reports the definitive immutable-snapshot
run rather than selecting a faster sample.

### Correctness coverage

The initial snapshot passed six tests. The optimized snapshot executed 25
tests with zero failures and four opt-in benchmarks skipped. The four
benchmarks then passed in explicit benchmark-mode runs.

The feature-complete snapshot executed 29 tests with zero failures and the same
four opt-in benchmarks skipped. Explicit benchmark-mode runs then passed all
four. New coverage validates natural adjacent-volume selection, disabled and
enabled boundary behavior in both directions, final-page placement, empty
directory rejection, page-number validation, and spread alignment.

The quality snapshot executed 33 tests with zero failures and four opt-in
benchmarks skipped. Explicit benchmark-mode runs then passed all four. The new
tests cover concurrent decode coalescing, visible-detail retention under a
full cache, unrelated-directory skipping at volume boundaries, continuation
disabled at a boundary, extreme page-number input, and fit scale across
differently sized spread pages.

The retained functionality includes archive and folder opening, natural page
ordering, all supported image extensions, single and double page modes,
left-to-right and right-to-left behavior, keyboard navigation, fit,
actual-size, and custom zoom, Finder document opening, and temporary-file
cleanup.

## Optimization design

### Reader features

- The sidebar reuses the model's existing page array and renders rows through
  `LazyVStack`. It owns no duplicate page model and performs no image decoding.
- Page jumping is one validated, one-based model operation shared by sidebar
  rows, Command-Shift-G, and the toolbar editor. Two-page mode aligns a chosen
  page to its containing spread.
- The page indicator remains inert text until double-clicked or invoked from
  the menu. Invalid and out-of-range input does not mutate reader state.
- Adjacent-volume discovery filters sibling entries to supported archives and
  usable image directories, skips hidden, package, empty, and unrelated
  entries, and uses the same natural ordering as pages. It reuses the existing
  cancellable asynchronous open path, including generation protection, cache
  reset, error preservation, and temporary-file cleanup.
- Cross-volume continuation is an `AppStorage` Boolean enabled by default.
  Forward continuation starts at page one; backward continuation starts at the
  final valid page or spread. Disabling it restores hard book boundaries.
- Pinch zoom reuses the existing custom-zoom and resolution-refinement path.
  The model retains one bounded maximum-size aggregate for the visible page or
  spread—not a volume-sized metadata table—to translate fit-to-window into a
  smooth initial scale. Existing two-axis scrolling supplies panning once the
  page exceeds the viewport.
- Command-0 and the zoom menu both select the existing fit mode; no second
  fit-to-window state or layout implementation was introduced.

### Archive discovery and opening

- Archive loading runs outside the main actor.
- Generation tokens prevent an older, slower open from replacing a newer book.
- Superseded work is canceled, and temporary extraction directories are
  cleaned without blocking the UI.
- Directory enumeration computes each relative natural-sort key once instead
  of rebuilding it during every comparison. This is the principal reason the
  4,096-page scan is 6.79 times faster in the definitive run.
- Enumeration checks cancellation periodically rather than adding a check to
  every item.
- `bsdtar` writes standard error through an already-open descriptor to a
  unique temporary file outside the archive-controlled extraction tree rather
  than a finite pipe. Verbose failures cannot deadlock archive opening, and
  only the first 64 KiB is converted into the diagnostic message.
- A canceled open polls at 5 ms granularity, sends `SIGTERM`, waits up to
  100 ms, and falls back to `SIGKILL` before reaping `bsdtar` and removing its
  partial extraction. A FIFO regression test proves a blocked subprocess
  completes as `CancellationError` within 500 ms.

### Image decoding and presentation

- Image decoding uses Image I/O outside the main actor.
- Fit and low-zoom views request a viewport-appropriate thumbnail instead of
  decoding an original-size bitmap that the display will immediately shrink.
- Decode dimensions are bucketed, avoiding churn from inconsequential window
  size and scale changes.
- Actual-size and high-zoom views can refine the preview to the resolution the
  display can use.
- GIF prefetches decode a static downsampled first frame. Once a GIF is
  visible, the view replaces that preview with native `NSImage` handling so
  multi-frame behavior is not silently lost. Native GIFs are visible-only and
  excluded from the store because one rendered frame cannot honestly account
  for an animation's memory.
- Duplicate requests share one pending decode. Known-bad URL-and-resolution
  requests are negatively cached within the same fixed entry ceiling.
- A visible detail request inherits the retention rank of its viewport preview,
  so progressive refinement cannot be rejected as lower priority than
  speculative work.
- At most two image decodes run concurrently. Obsolete page and resolution
  work is canceled, preventing rapid navigation from building an unbounded
  decode backlog.

### Bounded page cache

The image store has two independent hard limits:

- 67,108,864 decoded bytes (64 MiB)
- 12 decoded entries

The count limit covers the worst normal double-page window exactly:

```text
2 visible + 8 upcoming + 2 previous = 12 entries
```

Retention ranks protect visible and near-future pages before distant work.
Eviction never admits a lower-ranked incoming page by discarding a
higher-ranked resident. Book replacement cancels pending work and clears all
cache, failure, ordering, and byte-accounting state.

### Static prefetch window

The default policy is deterministic:

- eight logical pages after the visible page or spread;
- two physical pages before the current index;
- nearest pages first within each priority group.

For a page-mode step `s` of one or two, the next forward visible range is a
subset of the eight-page forward window, and the next backward visible range
is a subset of the two-page backward window. Once resident, this static window
therefore covers every immediate legal turn. A predictor can only help when
background refill is incomplete or decoded-byte pressure prevents the whole
window from residing.

## Tiny predictor experiment

The predictor is intentionally smaller than a general model:

- Source-level state is one `UInt8`, logically holding `0`, `1`, or `2`
  consecutive successful backward turns. Class layout may absorb it into
  existing padding or round the instance size to its alignment.
- Opening a book, changing page mode, or moving forward resets it to zero.
- A failed boundary turn does not train it.
- The first backward turn retains the default policy.
- Beginning with the second consecutive backward turn, the same window of up
  to ten prefetch candidates is reordered previous-first.
- It adds no page candidate, allocation, task, timer, history array,
  persistence, or cache capacity.

The structural quality-pass A/B release experiment changed only this
production predictor logic. With identical `-Osize`, no-debug-info, and strip
settings, that checkpoint's stripped executable grew by exactly **24 bytes**.
This consumed 0.16% of the allowed 15 KiB experiment budget.

```text
Static stripped executable:    257,368 B
Predictor stripped executable: 257,392 B
Delta:                              +24 B
```

Its `__text` contribution was 160 bytes (159,424 B to 159,584 B); file and
section deltas differ because Mach-O layout and padding differ. The
feature-complete, earlier optimized-control, and current readability pairs each
had a 16-byte file delta, so every controlled run remains far below the budget.

The control is preserved as the `CBR_STATIC_PREFETCH` compile-time condition;
`./scripts/measure-predictor.sh` builds, strips, compares, and budget-checks
both variants from the same read-only source snapshot.

### Replay method

`PrefetchReplayTests` is part of the test target only and contributes no code
to the distributed executable. It models the store's retention ranking and
eviction rule with:

- five procedural traces: forward, single-page correction, reread, sustained
  reverse, and ping-pong;
- single-page and double-page steps;
- cache capacities of 4, 6, 8, and 12 entries;
- background refill budgets of 0, 1, 2, and 10 completed decodes per turn.

That is 160 trace/configuration cases. A demand miss represents a visible page
that is not resident when requested; a stalled turn is a turn with at least one
such miss. Refill budgets are decoder-service quanta, not wall-clock latency.

Correctness assertions prove that the static and adaptive policies:

- select identical candidate sets;
- retain exactly the bounded visible, two-back, and eight-forward window;
- contain no duplicates or out-of-range page indexes;
- are order-for-order identical before the second backward turn.

### Replay result

| Metric | Static | Predictor | Change |
| --- | ---: | ---: | ---: |
| Demand misses | 9,884 | 9,087 | -797 (-8.06%) |
| Stalled turns | 7,164 | 6,719 | -445 (-6.21%) |
| Prefetch decodes | 46,105 | 46,649 | +544 (+1.18%) |
| Winning / losing / tied cases | — | 21 / 0 / 139 | no modeled regression |

The improvement is confined to reread and sustained-reverse traces in both
page modes. Forward reading, one-back correction, and ping-pong traces are
unchanged. In the detailed replay run, immediately rejected prefetch decodes
fell from 26,707 to 26,190 (-1.94%), although total attempted prefetch decodes
rose slightly.

The tradeoff is deliberate: 1.18% more modeled background decode work buys
6.21% fewer stalled turns under constrained reverse navigation. The predictor
is retained because the corpus showed no losing case and the controlled binary
cost has remained 16–24 bytes. If a future A/B exceeds 15,360 bytes, or a
refreshed replay introduces common-pattern regressions, remove it and keep the
static policy.

Replay is a scheduling model, not proof of a wall-clock improvement on every
image format or machine. Real decode latency depends on dimensions, codec,
filesystem, and host framework behavior.

## Distribution-size work

- The release target uses Swift `-Osize`.
- Release packaging omits debug information.
- The copied app executable is stripped with `xcrun strip -S -x -N`; SwiftPM's
  original build artifact is left untouched. A matching pre-strip executable
  is retained outside the app and distribution archives for crash diagnostics.
- The stripped Mach-O is structurally validated with `dyld_info` before
  signing. Imports, exports, fixups, Objective-C metadata, and linked libraries
  matched the conservative stripped control in the release experiment.
- The app is ad-hoc signed only after stripping.
- Archive staging runs in UTC, fixes member timestamps, and uses sorted path
  lists. The ZIP uses `/usr/bin/zip -9 -X -D -y`: maximum zlib compression, no
  nonessential extra fields or redundant directory records, and preserved
  bundle symlinks.
- A second distribution uses standard ustar with XZ level 9, sorted members,
  fixed timestamps, and canonical owner fields to preserve the identical
  signed bundle in a smaller reproducible archive.
- Benchmarks and replay code live only in the test target.

The installed executable, logical app bundle, allocated bundle size, ZIP, and
tar/XZ are intentionally kept as separate metrics. Filesystem allocation
rounds small files to blocks, while compressed sizes depend on container,
entropy, and signing data.

### Size experiments not shipped

- Explicit linker `dead_strip` and `dead_strip_dylibs` flags did not reduce the
  already stripped release result.
- Whole-module link-time optimization was not usable with this SwiftPM/toolchain
  configuration.
- `-Ounchecked` and reflection-metadata removal were rejected: their small
  potential savings were not worth weakening safety or risking SwiftUI and
  Observation behavior.
- Replacing platform codecs or `bsdtar` with bundled implementations would
  increase the distributed executable and duplicate facilities already
  guaranteed by the compatible host.

## Reproducing the full measurement

From the repository root:

```sh
CBR_OUTPUT_DIR=build/local-readability \
CBR_SCRATCH_PATH=build/swiftpm-local-readability \
./scripts/measure.sh local-readability
```

The command uses a new label because existing historical labels are immutable
unless `--replace` is explicitly supplied. Overrides are optional. The default
measurement product and scratch directories are `build/metrics-product` and
`build/swiftpm-metrics`.

The script:

1. copies measured inputs to a digest-verified, read-only source snapshot;
2. cleans its selected SwiftPM scratch path;
3. builds a release executable with `-Osize` and no debug information;
4. copies, strips, validates, and ad-hoc signs the app;
5. creates deterministic compatibility ZIP and smaller tar/XZ packages;
6. runs the release correctness suite;
7. runs the opt-in archive, image, and replay benchmarks;
8. records production Swift file count, LOC, source bytes, and logical,
   allocated, compressed, Mach-O, and dependency sizes;
9. records the environment and canonical source-manifest SHA-256;
10. rechecks the live tree and atomically publishes the selected metrics file.

The source manifest covers relative paths, content hashes, and executable bits
for package, production, test, and measurement inputs. Builds and tests run
from that immutable snapshot. The harness checks both snapshot and live tree
after every phase and immediately before atomic publication, aborting instead
of recording mixed-revision results if the live tree changes.

Mutable output and scratch paths use a shared exact-canonical-path lock
namespace, and predictor measurements share the repository timing lock.
Source-overlapping paths and any output/scratch overlap are rejected. An
external scratch path must be empty on first use; the harness claims it with a
persistent sibling marker bound to the directory's device/inode identity before
ever passing it to `swift package clean`. Snapshot-child mode is private,
requires the complete inherited state, and revalidates real, non-symlink lock
directories throughout the run.

The central commands are:

```sh
swift package --scratch-path build/swiftpm-local-readability clean
swift build -c release -debug-info-format none \
  --scratch-path build/swiftpm-local-readability
xcrun strip -S -x -N \
  "build/local-readability/Comic Book Reader.app/Contents/MacOS/ComicBookReader"
codesign --force --sign - "build/local-readability/Comic Book Reader.app"
CBR_BENCHMARK=1 swift test -c release -debug-info-format none \
  --scratch-path build/swiftpm-local-readability
stat -f %z \
  "build/local-readability/Comic Book Reader.app/Contents/MacOS/ComicBookReader"
size -m \
  "build/local-readability/Comic Book Reader.app/Contents/MacOS/ComicBookReader"
otool -L \
  "build/local-readability/Comic Book Reader.app/Contents/MacOS/ComicBookReader"
```

`scripts/measure.sh` invokes benchmark filters separately, but the abbreviated
test command above shows the required configuration.

To reproduce the predictor size delta:

```sh
./scripts/measure-predictor.sh
```

The script uses separate clean scratch directories, compiles the static
control with `-DCBR_STATIC_PREFETCH`, strips both executables identically, and
fails if the file delta exceeds 15,360 bytes.

## Readability-pass verification record

- The immutable snapshot executed 33 tests with zero failures. Four benchmark
  definitions were skipped in ordinary mode; all three performance benchmarks
  and the predictor replay then passed explicitly.
- The signed executable is 281,888 bytes, the logical app bundle is 411,925
  bytes, the ZIP is 207,622 bytes, and the tar/XZ is 188,700 bytes.
- The production target is six Swift files, 2,679 lines, and 109,761 bytes.
  Runtime limits remain 64 MiB, 12 entries, eight pages ahead, and two behind.
- The same-source static/adaptive A/B was 261,552/261,568 bytes: a 16-byte file
  delta and 160-byte `__text` delta, using 0.10% of the 15 KiB ceiling.
- Swift formatting passed in strict mode; every shell script passed `zsh -n`;
  the ZIP and tar/XZ validated; the app passed strict deep code-signature
  verification; and `dyld_info -validate_only` accepted the executable.
- SHA-256 values are
  `e4b730f7154a7a5e4aac33f72dab5089a82c5807316dec9c429b40b3a25ce479`
  for the executable,
  `3359e4accbcca25dbe5a3452d0a475ba1888aff996511961fd3cc1af994f38b2`
  for the ZIP, and
  `2c03c081ba88946d5661e1fc2f4ea896a51f8e4b1d1c5651ff1672768d914a0a`
  for the tar/XZ.
- The exact measured source digest is
  `a8078e027fd780435d9b96cf42e606a608ea3e5398ecab341078281d0bd37c73`
  under source-digest schema v3.

## Branding checkpoint records

- `Metrics/branding.json` added the approved primary ICNS and repository brand
  sources without changing executable bytes or `__text`. Against the quality
  checkpoint, the bundle became 398,202 bytes, the ZIP 202,301 bytes, and the
  tar/XZ 183,760 bytes; the increase is artwork, not code.
- `Metrics/alternate-icon.json` added the persistent alternate-icon setting and
  shipped its 9,275-byte SVG directly. The executable became 281,888 bytes,
  `__text` 161,936 bytes, the bundle 411,925 bytes, the ZIP 207,599 bytes, and
  the tar/XZ 188,704 bytes.
- Both immutable snapshots executed 33 tests with zero failures and retained
  the same 25 platform dynamic dependencies and bounded runtime policy.

## Quality-pass verification record

- The immutable snapshot executed 33 tests with zero failures. Four opt-in
  benchmark definitions were skipped in ordinary mode, then all three
  performance benchmarks and the predictor replay passed explicitly.
- That checkpoint's executable is 277,680 bytes. Its ZIP is 118,646 bytes and
  its tar/XZ is 100,216 bytes.
- The production target is six Swift files, 1,558 lines, and 52,875 source
  bytes. These values and the production runtime policy are captured in
  `Metrics/quality.json`.
- The static/adaptive predictor A/B was 257,368/257,392 bytes: a 24-byte file
  delta and 160-byte `__text` delta, using 0.16% of the 15 KiB ceiling.
- The ZIP passed `unzip -t`; the tar/XZ listed cleanly; the app passed strict
  deep code-signature verification and its executable passed
  `dyld_info -validate_only`.
- SHA-256 values are
  `50423a6e622b165785c1552d790a3a7ad656047d73b2e78ff33760f91d01eaa3`
  for the executable,
  `dd8b196a7a53eda99c8a22619c6ca4801f7b2187a75c364c945f12209a172b4e`
  for the ZIP, and
  `b3962fb96bbfd07ec7f356e270536d59874b02b938e98a25c95ccc5e3d350abb`
  for the tar/XZ.
- The exact signed package launched and remained running. Core Graphics
  confirmed a 900×532 on-screen `Comic Book Reader` window; the smoke-test
  instance was then closed.
- Production compilation completed without warnings. The exact measured source
  digest is
  `de2cc13c365c904b658ebcb274a0a2fcbfc9cf3f9d194152d157a39247960b7f`.

## Feature-complete verification record

- The immutable measurement snapshot executed 29 tests with zero failures;
  four opt-in tests were skipped in ordinary mode and then all four passed in
  benchmark mode.
- That checkpoint's executable is 282,320 bytes. Its ZIP is 120,032 bytes and
  its tar/XZ is 100,560 bytes.
- The production target is five Swift files, 1,461 lines, and 50,809 source
  bytes. These values are captured in `Metrics/features.json`.
- That checkpoint's static/adaptive predictor A/B was 261,976/261,992 bytes: the
  predictor still costs 16 bytes, or 0.10% of its 15 KiB ceiling.
- The checkpoint ZIP passed `unzip -t`; the tar/XZ listed cleanly; the app passed
  strict deep code-signature verification and its executable passed
  `dyld_info -validate_only`.
- SHA-256 values are
  `aad1ae2d8edb9753c8ca4280aa8601c76b64ed406242afd2cccc5e0f725f57ee`
  for the executable,
  `28b27d62595c79df69371388baaea6b1cb8b3a0e3eb0f2b8e9786ccab0f7996c`
  for the ZIP, and
  `0a7fe2d938be2d51c8b1f208a4162f3376f289d86637a7ad6ea081007e2d9860`
  for the tar/XZ.
- The signed app launched with a two-volume test corpus. Core Graphics then
  confirmed that the checkpoint package created a 900×532 on-screen reader
  window. macOS denied Accessibility and screen-capture access, so the new
  controls were not claimed as visually automated; their shared model paths
  are covered by the release tests above.

## Optimized-control verification record

- A clean scratch release build from a read-only source snapshot produced the
  recorded source hash and size snapshot.
- The complete suite executed 25 tests with zero failures. It covers real ZIP
  extraction, corrupt and empty archives, natural ordering, cancellation,
  every declared image extension, image downsampling and caching, visible GIF
  handling, open/navigation state, both page modes, both reading directions,
  key mappings, zoom, errors, and cleanup.
- All archive, image, and predictor benchmarks passed in benchmark mode.
- The distribution ZIP passed `unzip -t`; the tar/XZ listed and extracted
  cleanly; both extracted executables retained execute permission and passed
  `codesign --verify --deep --strict`.
- Two independent restagings reproduced the shipped ZIP and tar/XZ byte for
  byte, including SHA-256 hashes.
- Final SHA-256 values are
  `092f6d9b6f84a917d1ee4d09d1c88a16cde977a93aff4436b6a4f3da6a1dd992`
  for the shipped executable,
  `9cf661086b2c39d9d8db45b2487f6ba4c18b8e0c578c7b534f77289efc650814`
  for the ZIP, and
  `d8186a248ed47ab371c6d30ccbb00ea660823ecec4e3c83c6ef26b0f62411f31`
  for the tar/XZ.
- The actual `-N` candidate launched and opened a 12-page folder. UI smoke
  checks exercised the GIF page, single/double mode, forward/backward page
  turns, RTL reversal, Fit/1:1/125%/100% zoom, CBZ opening, and graceful exit.
- The exact final packaged app then repeated CBZ launch, display, page turn,
  1:1 zoom, and graceful exit successfully.
- The debug launcher produced an unstripped debug binary with symbols.
- The final static/predictor A/B was 215,952/215,968 bytes, a 16-byte delta.
- Predictor replay reported 21 winning, zero losing, and 139 tied cases.
