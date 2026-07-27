# Guide to xsComic

This guide is the map of the program: what it does, how data moves through it,
why its boundaries exist, where the sharp edges are, and what to read before
changing it. The source comments contain the close reasoning; this document
supplies the system-level view.

## 1. Product behavior

xsComic opens a directory of images or an archive with one of these extensions:

| Family | Extensions | Reader |
| --- | --- | --- |
| 7-Zip | `.cb7`, `.7z` | macOS `/usr/bin/bsdtar` |
| RAR | `.cbr`, `.rar` | macOS `/usr/bin/bsdtar` |
| tar | `.cbt`, `.tar` | macOS `/usr/bin/bsdtar` |
| ZIP | `.cbz`, `.zip` | macOS `/usr/bin/bsdtar` |
| directory | any directory | direct filesystem scan |

Recognized page formats are AVIF, BMP, GIF, HEIC/HEIF, JPEG, PNG, TIFF, and
WebP. The extension admits a candidate; the Image I/O codecs installed with
macOS determine whether it actually decodes.

Pages are found recursively. Hidden entries, package contents, symbolic links,
non-regular files, and unsupported files are ignored. Relative paths are
natural-sorted once, so `page2.jpg` precedes `page10.jpg`.

The reader supports:

- single pages and two-page spreads;
- left-to-right and right-to-left ordering;
- a toggleable, lazy numbered-page sidebar;
- page jumping through **Reading → Jump to Page…** (`Command-Shift-G`) or by
  double-clicking the page indicator;
- fit-to-window (`Command-0`), actual size (`Command-1`), 10–800% custom zoom,
  trackpad pinch zoom, and pan/scroll while enlarged;
- automatic continuation to the next or previous usable sibling volume,
  enabled by default;
- an optional Azusa-inspired runtime icon, with the primary xsComic icon
  remaining the bundle/Finder icon.

On current macOS, the primary artwork is supplied as a full square and the
system applies the final rounded mask. Its source SVG therefore contains no
pre-rounded enclosure; adding one would produce a visibly inset
"icon-within-an-icon." A tiny compiled asset catalog identifies the artwork as
a current app icon, while the ICNS remains the fallback for older systems.
AppKit does not mask a runtime `applicationIconImage` override, so the alternate
path clips the alternate with the alpha of AppKit's current primary icon. This
inherits the platform's exact native corner geometry rather than freezing an
approximation in source. The SVG carries only the same 80.47% centered inset
that the system applies to the primary composition; it aligns the shared eyes,
hands, book, and feet while allowing hair and clothing to differ. Turning the
setting off clears the override and returns ownership to the system-rendered
primary icon.

Arrow-key semantics are centralized. In LTR, right advances. In RTL, left
advances by default; the RTL-only setting can swap those two keys. Menu commands
and view key events call the same mapping, preventing two definitions from
drifting.

## 2. The whole architecture

The program has three long-lived owners and two presentation layers:

```text
ComicBookReaderApp
  │ owns one ReaderModel for the one reader window
  ▼
ReaderModel ───────────────► ArchiveBook
  │ state/navigation          source pages + extracted-tree ownership
  │
  ├────────────────────────► PageImageStore
  │                           bounded decoded-image actor
  ▼
ReaderView ────────────────► PageCanvas
window/sidebar/toolbar       geometry + progressive image presentation
```

There is no service container, repository protocol, persistence layer, event
bus, or view-model hierarchy. Those abstractions would not decouple a second
implementation that actually exists. Each boundary corresponds instead to a
real ownership or concurrency boundary.

### Application lifetime

[`ComicBookReaderApp.swift`](../Sources/ComicBookReader/ComicBookReaderApp.swift)
owns the single `ReaderModel`, persisted settings, scenes, menu commands,
Finder-open handling, and the narrow AppKit call needed to change the runtime
icon.

The app intentionally has one reader window and one model. A second window
sharing that model would create surprising navigation and cache ownership; a
second independent model would double the memory budget. If multiwindow support
is ever added, model ownership must move inside each window scene rather than
being papered over in the view.

### Reader state machine

[`ReaderModel.swift`](../Sources/ComicBookReader/ReaderModel.swift) is
`@MainActor` because it is the UI's authoritative mutable state. It owns:

- current archive and zero-based presentation index;
- reading direction, page mode, and zoom;
- open/load generations and cancellation handles;
- cross-volume transitions;
- the bounded prefetch plan and its tiny backward-reading bias.

The model exposes presentation facts (`visiblePages`, status text, turn
availability) rather than making views rediscover page arithmetic.

Opening a book is transactional:

1. increment the load generation and cancel the superseded task;
2. load/extract/scan away from the main actor;
3. verify the generation before committing;
4. reset decoded pixels and replace the book together;
5. asynchronously dispose of the old extracted tree.

Cancellation saves work. Generation equality provides correctness even when an
underlying operation cannot stop immediately.

### Archive and filesystem ownership

[`ArchiveBook.swift`](../Sources/ComicBookReader/ArchiveBook.swift) distinguishes
borrowed and owned trees:

- an opened directory is borrowed and never removed;
- an archive is extracted into a unique system-temporary directory owned by
  that `ArchiveBook`;
- replacement or deinitialization removes only the owned tree.

Extraction runs in a child `bsdtar` process. This keeps archive parsers outside
the app's address space and avoids shipping a decompressor. Diagnostics are
drained concurrently to avoid a full pipe stalling the child. Task
cancellation terminates superseded extraction.

Adjacent volumes are enumerated only at a page boundary. There is no directory
watcher or persistent library index. Candidate archives and directories are
naturally ordered; unsupported, package, hidden, and empty candidates are
skipped.

### Decoded-image ownership

[`PageImageStore.swift`](../Sources/ComicBookReader/PageImageStore.swift) is an
actor with two hard retained-cache limits:

- 64 MiB of counted decoded pixels;
- 12 entries.

At most two decodes run concurrently through a small actor semaphore. Requests
are keyed by both URL and maximum pixel dimension, so a viewport preview cannot
masquerade as a native-resolution result. Identical demand and prefetch work is
coalesced. Failures are remembered in a bounded negative cache. A generation
counter rejects completions from an old book.

Eviction is LRU within retention ranks. The visible page and useful nearby
pages therefore outrank speculative pages without creating separate caches.
Animated GIFs are exceptional: prefetch gets a static first frame, while a
visible GIF uses `NSImage` to preserve animation and stays outside the byte
cache because its multi-frame memory cannot be counted honestly.

The 64 MiB figure bounds retained cached rasters, not total process memory.
Framework state, views, the visible `NSImage`, and up to two transient decoder
working sets also exist. That distinction matters when interpreting memory
tools.

### Presentation

[`ReaderView.swift`](../Sources/ComicBookReader/ReaderView.swift) is the stable
window scaffold: empty/loading/error states, toolbar, numbered sidebar, page
editor, and zoom controls. The sidebar contains numbers rather than thumbnails
because a thumbnail browser measurably enlarged the binary and created another
source of decoded-image pressure.

[`PageCanvas.swift`](../Sources/ComicBookReader/PageCanvas.swift) owns the
geometry whose values must agree: spread ordering, available viewport, fit
scale, decode target, scrolling, pinch state, and progressive page loading.
Keeping these in one file prevents subtle disagreement between independent
layout helpers.

Viewport requests are rounded to 256-pixel buckets. Custom zoom is represented
as fixed-point sixty-fourths for task/cache identity. These buckets trade a
small amount of overdecode for substantial reuse during continuous resize and
pinch gestures. A preview appears first; high zoom may refine it only to the
resolution the display can use.

## 3. Navigation and prefetch policy

The central workload assumption is sequential reading at a few page turns per
second. On every visible page or spread, the model describes one bounded
window:

- eight logical pages ahead;
- two logical pages behind;
- never more than the 12-entry/64 MiB cache can retain.

After two consecutive backward turns, the adaptive policy changes priority
inside that same window. It does not widen the window, allocate a model, keep
history, or run inference. Controlled builds measured its stripped executable
cost at 16 bytes, far below the 15 KiB ceiling, and replay tests cover the
policy against the static baseline.

Two-page mode advances by two presentation pages. RTL changes visual ordering
and turn-key mapping, not archive order. This separation is essential: archive
indices remain stable across direction changes and page jumps.

## 4. Why the implementation looks like this

### Platform-first, dependency-free

SwiftUI, AppKit, Image I/O, Foundation, Swift concurrency, and the system
`bsdtar` already provide the necessary behavior. A third-party archive or image
library would add shipped code, update obligations, build time, and supply-chain
surface. Avoiding dependencies is therefore a size, launch, maintenance, and
security decision at once.

### Extract, then read

Streaming individual archive entries sounds leaner, but it needs an archive
library resident in-process and complicates random page access, cancellation,
and format parity. Extracting once spends temporary disk space to obtain simple
filesystem URLs and predictable page access. This is an explicit disk-for-code
trade.

### Downsample before display

A compressed comic page can expand to tens of megabytes. Image I/O thumbnail
creation constrains the decoded dimensions before the page enters the cache.
Immediate decoding moves the cost into the off-main task rather than deferring
it to SwiftUI's render pass.

### Bounded speculation

Prefetch is useful only if it does not evict the page the user is looking at or
turn a small reader into a memory balloon. Count, byte, concurrency, and window
bounds are all independent because none implies the others.

### Comments instead of abstraction theater

The source is heavily annotated, but production remains six files. Comments
explain invariants and measured choices; types and helper functions express
real boundaries. There is deliberately no generic cache package, archive
protocol family, coordinator layer, or dependency-injection apparatus.

### Measurement as source

[`scripts/measure.sh`](../scripts/measure.sh) snapshots every build-affecting
input, makes it read-only, builds and packages it, runs correctness and opt-in
performance tests, inspects the Mach-O and archives, then publishes JSON only if
the live tree still has the same digest. Historical labels are immutable unless
replacement is explicit.

This ceremony exists because source lines, executable bytes, compressed bytes,
cache policy, and wall-clock timings answer different questions. The
[optimization record](optimization.md) explains how to compare them.

## 5. Code-reading route

For a first reading:

1. `ComicBookReaderApp.swift` — lifetime, settings, commands, file-open events.
2. `ReaderModel.swift` — coordinate systems, transitions, prefetch plan.
3. `ArchiveBook.swift` — input validation and filesystem ownership.
4. `PageImageStore.swift` — decoding, coalescing, cache invariants.
5. `ReaderView.swift` — declarative window composition.
6. `PageCanvas.swift` — geometry and progressive pixels.
7. tests — executable specifications for every important boundary.
8. `scripts/measure.sh` — evidence and release artifact construction.

The tests are grouped by the production owner they exercise:

| Test file | Principal contract |
| --- | --- |
| `ArchiveBookTests.swift` | discovery, ordering, archives, cleanup, cancellation |
| `ReaderModelTests.swift` | page arithmetic, keys, adjacent volumes, zoom |
| `PageImageStoreTests.swift` | decode sizing, coalescing, failure and cache bounds |
| `PrefetchReplayTests.swift` | fixed window and adaptive-policy evidence |
| `PerformanceTests.swift` | directory, CBZ, decode, and cache-hit benchmarks |
| `TestSupport.swift` | small image/archive fixtures shared by tests |

## 6. Change guide

When changing archive handling, preserve the borrowed/owned distinction and
test both cancellation and cleanup. Never recursively remove a caller-owned
directory.

When changing navigation, write the rule once in `ReaderModel`; invoke it from
menus and key handlers. Test LTR/RTL, single/double, first/last, and odd page
counts.

When changing image loading, account separately for request identity, decode
concurrency, transient memory, retained bytes, entry count, negative-cache
count, and stale completions. A bound on one is not a bound on the others.

When changing presentation geometry, keep fit scale and requested decode size
derived from the same maximum page rectangle. Test narrow, wide, one-page, and
two-page viewports.

When changing performance policy, first add a replay or benchmark that states
the expected win, then use `measure.sh` for the shipped cost. Do not use source
LOC as a proxy for executable size.

## 7. Technical errata and security notes

These are current design limits, not hidden promises:

- Archive support is whatever `/usr/bin/bsdtar` on the running macOS release
  can decode. Extension recognition does not guarantee every RAR/7z variant.
- Archives are fully extracted. A very large or adversarial archive can consume
  substantial temporary disk before page discovery completes. The decoded
  image cache does not bound extracted bytes.
- xsComic is not currently App-Sandboxed. Direct Developer ID distribution can
  use the hardened runtime, but sandboxing would require a separate,
  functionality-preserving design for user-selected directories, adjacent
  volumes, security-scoped access, and the `bsdtar` child process.
- Image codecs are supplied by macOS. A format listed here may vary across OS
  releases, and malformed images exercise platform decoders.
- Natural ordering is locale-aware through the platform comparison routine.
  Extremely unusual mixed-script names can therefore order differently under
  different locale settings.
- GIF cache accounting intentionally excludes the animated visible object.
  Static previews remain bounded; a pathological animated GIF can use more
  memory than its encoded size suggests.
- Temporary extraction is cleaned on book replacement and normal object
  teardown. A forced process kill can leave a uniquely named directory under
  the system temporary area until the operating system or user cleans it.
- Adjacent-volume continuation examines only siblings of the current source.
  It is on-demand and deliberately does not maintain a library database.
- Historical wall-clock metrics are meaningful only on the recorded machine,
  architecture, macOS, and Swift toolchain. Artifact byte counts are the more
  reproducible comparison.
- The checked-in build emits an ad-hoc signature by default. That is suitable
  for local validation, not a public Gatekeeper release.

## 8. Further reading

- [Apple: `kCGImageSourceThumbnailMaxPixelSize`](https://developer.apple.com/documentation/imageio/kcgimagesourcethumbnailmaxpixelsize)
  explains the decode-size cap used for previews.
- [Apple: `kCGImageSourceShouldCacheImmediately`](https://developer.apple.com/documentation/imageio/kcgimagesourceshouldcacheimmediately)
  explains why decode work is forced before display.
- [Apple: Swift `Task`](https://developer.apple.com/documentation/swift/task/)
  documents cooperative cancellation and task lifetime.
- [Apple: `MagnifyGesture`](https://developer.apple.com/documentation/swiftui/magnifygesture)
  is the native pinch primitive used by the canvas.
- [libarchive](https://www.libarchive.org/) documents the archive engine behind
  the system `bsdtar` command.
- [Apple: Creating distribution-signed code for macOS](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/)
  describes manual signing for external build systems.
- [Apple: Notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
  covers hardened runtime, Developer ID, tickets, and Gatekeeper.

## 9. A compact statement of intent

xsComic should remain easy to hold in one head. New code earns its place by
preserving reader behavior, making an invariant more explicit, improving a
measured hot path, or buying enough security/correctness to justify its exact
cost. The target is not the fewest possible lines. It is the smallest coherent
program whose behavior and risks a casual human reader can verify.
