# Changelog

## Unreleased — Linux Slopjective-C (Objective-C 3.0) Port

Added a native Linux (`aarch64-unknown-linux-gnu` / `x86_64-unknown-linux-gnu`,
Debian 13) Objective-C 3.0 port in `Sources/xsComicLinux/` alongside the intact
macOS Objective-C / AppKit / Metal application (`Sources/xsComic/`,
`Tests/xsComicTests/`, `scripts/build-app.sh`, `scripts/run-tests.sh`,
`scripts/build-and-run.sh`, and `docs/guide.md` remain unchanged):

- added `Sources/xsComicLinux/XSCBase.{h,objc3}`: minimal
  `__attribute__((objc_root_class))` ARC root class (`XSCObject`) targeting the
  Slopjective-C `objc3c` (`v0.1.0-preview.1`, patched Clang 23.1.5, GNUstep 2.2
  ABI + `libobjc2`, zero GNUstep-Base) runtime, with `XSCString`, `XSCData`,
  `XSCError <Error>`, `XSCIndexList`, main-thread queue/timer dispatcher with
  event-loop wakeup hook, and background pthread pool; uses Objective-C 3.0
  `defer`, `Optional(T)`, `Result(T, E)`, exhaustive `match`, typed
  `throws(XSCError *)`, `tryValue` / `tryOptional`, and `handle` / `catch`;
- added `Sources/xsComicLinux/XSCArchive.{h,objc3}`: POSIX + `zlib` raw-DEFLATE
  + `libarchive` reader with zero-extraction `pread(2)` CBZ/ZIP (STORE,
  raw-DEFLATE, Zip64, zip-bomb bounds) and CBT/TAR (ustar/PAX/GNU LongName),
  in-process `libarchive` CBR/CB7 with 256 MiB spill directory cleanup, POSIX
  `opendir`/`readdir` scanning with `O_NOFOLLOW`, ASCII-fast + UTF-8 natural
  sorting (`qsort_r`), and adjacent-volume discovery;
- added `Sources/xsComicLinux/XSCImageStore.{h,objc3}`: native Linux decoders
  (`libjpeg-turbo`, `libpng`, `libwebp`, `giflib` with multi-frame composited
  animated GIFs, `libtiff`, `libavif`, `libheif`, built-in BMP), EXIF 1–8
  orientation parsing, 32×32 chroma-probed 8-bit `L8` grayscale repacking (4×
  RAM reduction), page-aligned anonymous `mmap` pixel buffers with
  `madvise(MADV_FREE)` volatile marking, bounded 12-entry / 64 MiB LRU cache
  with open-addressed hash table fast path, request coalescing, and 4-lane
  priority pthread decode pool;
- added `Sources/xsComicLinux/XSCReaderModel.{h,objc3}`: archive-order
  single/two-page LTR/RTL navigation, 8-ahead/2-behind + 2-turn backward
  prefetch predictor, zero-hop synchronous cache-hit fast path, 120 ms loading
  grace timer, and predictive adjacent-volume pre-warming;
- added `Sources/xsComicLinux/XSCGLCanvas.{h,objc3}` and
  `Sources/xsComicLinux/main.objc3`: SDL2 + OpenGL 3.3 Core + `SDL2_ttf`
  dark-chrome desktop shell with inline GLSL 330 Lanczos-3 / EXIF 1–8 /
  `GL_R8` `.rrr1` shader, focal-point zoom, drag panning, in-place animated GIF
  playback, toolbar, collapsible page sidebar, empty CTA, direct Jump-to-Page
  modal (`Ctrl+Shift+G` / `G`), XDG-persisted settings popover (`prefs.ini`),
  drag-and-drop, and deterministic `--screenshot` CLI PNG capture;
- added Debian 13 + pinned Slopjective-C SDK Docker toolchain
  (`docker/Dockerfile`, `scripts/docker-env.sh`), disjoint native-or-Docker
  Linux scripts (`scripts/build-linux.sh`, `scripts/run-linux-tests.sh`,
  `scripts/build-and-run-linux.sh`) targeting `build/linux/xscomic` (never
  colliding with macOS `build/product/xsComic.app`), a 183-assertion Linux test
  and benchmark suite (`Tests/xsComicLinuxTests/main.objc3`), Linux
  architecture documentation (`docs/linux.md`), and a reproducible audit record
  (`Metrics/linux-objc3.json`);
- verified Debian 13.8 `aarch64` release (`-Oz -flto=thin -Wl,--gc-sections
  -Wl,--as-needed` + `strip`) footprint, sanitizers, and benchmarks: **284.0 KiB
  (290,848 bytes)** stripped `build/linux/xscomic` (16 direct shared libraries,
  0 unused), `183 passed, 0 failed` (with ASan + UBSan + LSan and TSan 3/3
  clean), 1.13 ms median 4,096-file dir scan, 0.035 ms median 128-page CBZ open,
  0.075 ms median 500-page CBZ open, 2.66 ms median cold 1024×1536 JPEG decode,
  47.7 ns/call median synchronous cache-hit lookup, and live Debian 13.6 ARM64
  GNOME desktop rendering.

## 2.0.0

Apple Silicon (`arm64`, macOS 14+) rewrite in Objective-C, AppKit, and Metal:

- dropped SwiftUI, Swift Concurrency, and Swift runtime linkage for a direct
  AppKit shell (`NSApplication`, `NSWindowController`, `NSToolbar`,
  `NSTableView`), cutting the Developer ID signed executable to 174 KB, the
  `.app` bundle to 218 KB, the stapled `.app.zip` to 101 KB, `.tar.xz` to 85 KB,
  and the themed DMG to 223 KB;
- replaced `NSImage`/SwiftUI rendering with `CAMetalLayer` and zero-copy
  `IOSurface` textures, an inline MSL Lanczos-3 downscaler with EXIF 1–8
  orientation, focal-point pinch zoom with no re-decodes on zoom/resize, and an
  `NSImageView` overlay only for multi-frame GIFs;
- switched off-screen cached pages to `kIOSurfacePurgeableVolatile`, added a
  32×32 chroma probe that repacks RGB-encoded grayscale pages to 8-bit `'L008'`
  via `vImage` (4× smaller), moved decoding to `CGImageSourceCreateImageAtIndex`,
  and added an `os_unfair_lock` synchronous cache-hit fast path (~596 ns);
- replaced upfront `bsdtar` extraction with `pread` random-access CBZ/ZIP
  (STORE, DEFLATE via `libcompression`, Zip64) and CBT/tar (<0.15 ms open, zero
  temp writes), in-process `/usr/lib/libarchive.2.dylib` for CBR/RAR and
  CB7/7z, and POSIX `opendir`/`readdir` with a flat byte arena and ASCII-fast
  natural sort (4,096 files in 1.83 ms);
- added predictive adjacent-volume pre-warming within 3 pages of volume
  boundaries and a 120 ms loading grace timer to prevent spinner flicker;
- replaced SwiftPM with direct `clang -arch arm64 -Oz -flto`, a single
  32-color 512×512 `Assets.car` (32 KB), binary `Info.plist`, and a 63-test
  Objective-C test/benchmark runner (`./scripts/run-tests.sh`).
- dropped Intel (`x86_64`) support; Intel Macs can stay on v1.0.0.

## 1.0.0

Initial xsComic release candidate:

- native macOS reader for CB7/7z, CBR/RAR, CBT/tar, CBZ/ZIP, and image folders;
- single-page and two-page LTR/RTL reading;
- bounded viewport-aware decoding, 64 MiB/12-entry cache, eight-page forward
  prefetch, two-page backward buffer, and tiny adaptive rereading bias;
- page sidebar, page jump, adjacent-volume continuation, keyboard navigation,
  fit/actual/custom zoom, pinch, and panning;
- primary xsComic icon and optional Azusa-inspired runtime icon;
- dependency-free SwiftPM build, byte-reproducible ZIP/tar packaging, themed
  drag-to-install DMGs, tests, benchmarks, and machine-readable footprint
  records;
- process-private archive extraction with traversal/symlink regression coverage
  and deterministic cleanup on replacement, failure, cancellation, and normal
  application exit;
- AGPL-3.0-or-later software and CC BY-SA 4.0 documentation/metrics, with
  branding expressly excluded from both license grants.
