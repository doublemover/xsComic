# Guide to xsComic

How xsComic 2.0 is put together, where the ownership boundaries sit, and why the
hot paths are written the way they are. Detailed invariants live in the source
comments; this is the map.

## Supported formats

| Family | Extensions | Backend |
| --- | --- | --- |
| ZIP | `.cbz`, `.zip` | `pread` Central Directory + Zip64 + `libcompression` (fallback to `libarchive` for exotic methods) |
| tar | `.cbt`, `.tar` | `pread` ustar / PAX / GNU LongName offset scan |
| RAR | `.cbr`, `.rar` | in-process `/usr/lib/libarchive.2.dylib` |
| 7-Zip | `.cb7`, `.7z` | in-process `/usr/lib/libarchive.2.dylib` |
| Folder | any directory | POSIX `opendir` / `readdir` |

Image extensions: `.avif`, `.bmp`, `.gif`, `.heic`, `.heif`, `.jpeg`, `.jpg`,
`.png`, `.tif`, `.tiff`, `.webp`. Actual decoding is handled by macOS Image I/O.

Hidden files, macOS package bundles, symlinks, non-regular files, and paths
containing `..` or a leading `/` are rejected. Pages are sorted with an
ASCII-fast natural comparator (`page2.jpg` before `page10.jpg`), falling back to
`CFStringCompare` when a name contains non-ASCII UTF-8 bytes.

## Architecture

Five implementation files in `Sources/xsComic/`:

```text
main.m (XSCAppDelegate / XSCWindowController)
  │ owns one window, toolbar, sidebar, and preferences
  ▼
XSCReaderModel ──────────► XSCArchive (XSCBook)
  │ navigation, spread      zero-extraction CBZ/CBT, libarchive CBR/CB7,
  │ math, pre-warming       POSIX directory scan
  │
  ├──────────────────────► XSCImageStore
  │                         os_unfair_lock cache, purgeable IOSurface,
  │                         Gray8 repack, 4-lane priority GCD decode
  ▼
XSCMetalCanvas
  CAMetalLayer, zero-copy IOSurface -> MTLTexture, inline MSL Lanczos-3
```

### `XSCArchive` (`XSCArchive.h`, `XSCArchive.m`)

- **CBZ/ZIP & CBT/tar**: Opened with `O_RDONLY | O_NONBLOCK`, verified with
  `fstat` (`S_ISREG`), and read via stateless `pread` rather than `mmap` so an
  unplugged drive or dropped network share returns `EIO` instead of raising
  `SIGBUS`. STORE entries read straight from disk; DEFLATE entries stream
  through `libcompression` (`COMPRESSION_ZLIB`) with strict size caps against
  zip bombs. Zero temporary files are written.
- **CBR/RAR & CB7/7z**: Decoded in-process via `/usr/lib/libarchive.2.dylib`
  with minimal C declarations. Payloads stay in memory up to 256 MiB and spill
  to a per-process temp directory (`O_NOFOLLOW`, cleaned on `dealloc` and
  `atexit`) for larger archives.
- **Directories**: Walked with `opendir`/`readdir` (`d_type`, falling back to
  `lstat` only on `DT_UNKNOWN`), storing all paths in a single flat UTF-8 byte
  arena and materializing `NSURL`s lazily.

### `XSCImageStore` (`XSCImageStore.h`, `XSCImageStore.m`)

- **Bounded cache**: Hard limits of 12 entries and 64 MiB logical bytes, with
  retention-aware LRU, request coalescing, and a bounded negative cache.
- **Synchronous fast path**: `cachedPageForBook:index:` checks an
  `os_unfair_lock`-protected dictionary (~600 ns) and pins the `IOSurface`
  non-volatile without hopping threads.
- **Decoding & RAM**: Uses `CGImageSourceCreateImageAtIndex` (AppleJPEG
  hardware path) instead of `CGImageSourceCreateThumbnailAtIndex`. Monochrome
  images go straight to 8-bit `'L008'` `IOSurface`s; RGB images run a 32×32
  chroma probe and repack visually grayscale manga to `'L008'` via `vImage`
  (4× less RAM). Off-screen cached pages are marked
  `kIOSurfacePurgeableVolatile` so macOS can reclaim them without swapping.
- **Concurrency**: 4-permit GCD decode pool reserving 1 lane for visible demand
  so background prefetch never stalls a page turn.

### `XSCMetalCanvas` (`XSCMetalCanvas.h`, `XSCMetalCanvas.m`)

- Hosts a `CAMetalLayer` and binds each page's `IOSurface` zero-copy to an
  `MTLTexture` (`R8Unorm` or `BGRA8Unorm`).
- Compiles a small inline MSL shader once at startup that handles EXIF 1–8
  orientation, Lanczos-3 downscaling, `.rrr1` grayscale swizzling, and a 1 px
  hairline border.
- Zooming, resizing, and toggling the sidebar never re-decode images. Multi-frame
  animated GIFs display through a lazy `NSImageView` overlay.

### `XSCReaderModel` & `main.m`

- **Zero-hop turns**: `XSCWindow.sendEvent:` routes arrow/space/PageUp/PageDown
  keys directly (yielding when `firstResponder` is an `NSTextView`). Cache hits
  swap Metal textures in the same run-loop turn. Cold decodes hold the previous
  frame for a 120 ms grace period before showing a loading label.
- **Prefetch & volume pre-warming**: Prefetches 8 pages ahead and 2 behind,
  biasing backward after two consecutive backward turns. Within 3 pages of a
  volume boundary (when continuation is enabled), the adjacent volume is opened
  and its boundary page pre-decoded in the background.
- **Launch & icons**: `application:openURLs:` starts opening the file in
  parallel with window setup. Primary icon comes from `Assets.car` (32-color
  512×512); the optional Azusa Dock icon (`AppIcon-Azusa.svg`) is rasterized
  off-main and clipped with the native icon's alpha mask.
