# Changelog

## 2.0.0

Full Apple Silicon (arm64) rewrite in pure Objective-C + AppKit + Metal with
zero third-party dependencies (requires macOS 14+ on Apple Silicon):

- **Native Objective-C + AppKit shell**: dropped SwiftUI, Swift Concurrency, and
  Swift runtime linkage for direct `NSApplication` / `NSWindowController` /
  `NSToolbar` / `NSTableView` UI, cutting the signed arm64 binary to ~156 KB
  (from 283 KB) and the complete `.app` bundle to ~200 KB (from 511 KB; `.tar.xz`
  ~80 KB, `.zip` ~96 KB);
- **Direct Metal rendering (`CAMetalLayer`)**: zero-copy `IOSurface` →
  `MTLTexture` binding with inline MSL Lanczos-3 downscaling, EXIF 1–8
  orientation, 120 Hz focal-point pinch-zoom, smooth panning, and native
  `NSImageView` fallback for multi-frame animated GIFs;
- **Purgeable unified-memory image cache**: off-screen cached pages are marked
  `kIOSurfacePurgeableVolatile` (zero dirty RAM footprint under pressure), with
  automatic RGB-grayscale detection and `vImage` 8-bit `'L008'` repacking (4×
  less RAM on grayscale manga), hardware `CGImageSourceCreateImageAtIndex`
  decoding, and a lock-protected synchronous cache-hit fast path (<0.2 ms
  page turns);
- **Zero-extraction archive I/O**: direct `pread` random-access CBZ/ZIP (STORE,
  DEFLATE via `libcompression`, Zip64) and CBT/tar with zero temp-file writes,
  in-process `libarchive` for CBR/RAR and CB7/7z, and POSIX `opendir`/`readdir`
  with zero-allocation ASCII-fast natural sorting;
- **Predictive volume pre-warming & instant navigation**: pre-opens and
  pre-decodes adjacent volumes within 3 pages of volume boundaries, preserves
  the 8-ahead / 2-behind + 2-turn backward adaptive predictor, and uses a
  120 ms loading grace timer to eliminate spinner flicker;
- **Lean bundle & toolchain**: direct `clang -arch arm64 -Oz -flto` build,
  single 32-color 512×512 `Assets.car` (32 KB), binary `Info.plist`, omitted
  legacy `AppIcon.icns`, and a standalone Objective-C test & benchmark suite
  (`./scripts/run-tests.sh`).

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
