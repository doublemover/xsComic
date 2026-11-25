# Changelog

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
