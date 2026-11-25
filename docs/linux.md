# Guide to xsComic (Linux / Objective-C 3.0)

How the Linux **Objective-C 3.0** port of xsComic is put together, where the
ownership boundaries sit, and why the hot paths are written the way they are.
Detailed invariants live in the source comments; this is the map. For the
native macOS AppKit/Metal implementation, see [guide.md](guide.md).

## Toolchain and Objective-C 3.0 model

xsComic on Linux targets `aarch64-unknown-linux-gnu` and
`x86_64-unknown-linux-gnu` (verified on Debian 13) and compiles directly with
the official **Slopjective-C** (`doublemover/Slopjective-C`,
`v0.1.0-preview.1`) **`objc3c`** compiler — patched LLVM/Clang 23.1.5 targeting
the GNUstep 2.2 ABI and `libobjc2` (`libobjc.so.4.6`) with ARC and Blocks
enabled.

To avoid GNUstep-Base footprint and startup overhead,
[`XSCBase.objc3`](../Sources/xsComicLinux/XSCBase.objc3) defines a minimal
`__attribute__((objc_root_class))` ARC root class (`XSCObject`) and only the
primitives the reader actually needs. The `.objc3` sources use idiomatic
Objective-C 3.0 throughout:

- `defer` for deterministic cleanup of file descriptors, heap buffers, mutex
  guards, libarchive handles, and OpenGL objects;
- `Optional(T)` (`Some` / `None`) and `Result(T, E)` (`Ok` / `Err`) unpacked
  via exhaustive `match`;
- typed `throws(XSCError *)` (conforming to Objective-C 3.0 `<Error>`),
  `tryValue` / `tryOptional`, and `handle` / `catch`.

## Build, test, and run

```sh
# Stripped release binary -> build/linux/xscomic (+ build/linux/xscomic.symbols)
./scripts/build-linux.sh --release

# Unoptimized debug binary (-O0 -g) -> build/linux/xscomic
./scripts/build-linux.sh --debug

# Standalone 183-assertion test and benchmark suite (Tests/xsComicLinuxTests/main.objc3)
./scripts/run-linux-tests.sh

# Build and launch interactively (X11/Wayland) or headlessly (--screenshot)
./scripts/build-and-run-linux.sh [args...]
```

All Linux scripts run natively when `objc3c` (or `/opt/objc3c/activate.sh`) is
present on Linux, and automatically delegate through
[`../scripts/docker-env.sh`](../scripts/docker-env.sh) and
[`../docker/Dockerfile`](../docker/Dockerfile) (`xscomic-objc3:dev`) on macOS
or hosts without the SDK. Outputs use `build/linux/`, `build/objc3/`, and
`build/linux-tests/`, completely disjoint from the macOS `build/product/` and
`build/clang/` trees.

## Supported formats

| Family | Extensions | Backend |
| --- | --- | --- |
| ZIP | `.cbz`, `.zip` | `pread(2)` Central Directory + Zip64 + `zlib` raw-DEFLATE (fallback to `libarchive` for exotic methods) |
| tar | `.cbt`, `.tar` | `pread(2)` ustar / PAX / GNU LongName offset scan (fallback to `libarchive` if needed) |
| RAR | `.cbr`, `.rar` | in-process `libarchive` (`-larchive`) |
| 7-Zip | `.cb7`, `.7z` | in-process `libarchive` (`-larchive`) |
| Folder | any directory | POSIX `opendir` / `readdir` |

Image extensions: `.avif`, `.bmp`, `.gif`, `.heic`, `.heif`, `.jpeg`, `.jpg`,
`.png`, `.tif`, `.tiff`, `.webp`. Decoding runs directly against native Linux
libraries (`libjpeg-turbo`, `libpng`, `libwebp`, `giflib`, `libtiff`,
`libavif`, `libheif`) plus a built-in zero-dependency 24/32-bit BMP decoder.

Dotfiles, `__MACOSX` resource forks, symlinks, non-regular files (FIFOs,
sockets, device nodes), embedded NUL bytes, Windows drive prefixes, leading
slashes, and `..` path traversal components are rejected or skipped. Pages and
adjacent sibling volumes are ordered with a zero-allocation ASCII-fast natural
comparator (`page2.jpg` before `page10.jpg`) that seamlessly handles UTF-8
multibyte prefixes and fullwidth digits with a deterministic raw-byte
tie-breaker (`qsort_r`).

## Architecture

Six `.objc3` implementation files and five headers in
[`../Sources/xsComicLinux/`](../Sources/xsComicLinux/):

```text
main.objc3 (XSCAppController / XSCUIRenderer)
  │ SDL2 window, reactive event loop, dark-chrome GL UI, XDG prefs, CLI/--screenshot
  ▼
XSCReaderModel ──────────► XSCArchive (XSCBook)
  │ archive-order nav,      zero-extraction CBZ/CBT (pread + zlib),
  │ spreads, pre-warming    libarchive CBR/CB7, POSIX directory scan
  │
  ├──────────────────────► XSCImageStore (XSCDecodedPage)
  │                         pthread_mutex hash cache, mmap + MADV_FREE,
  │                         L8 grayscale repack, 4-lane priority pthread pool
  ▼
XSCGLCanvas
  OpenGL 3.3 Core, GL_R8 / GL_RGBA8 textures, inline GLSL 330 Lanczos-3 & EXIF 1–8

XSCBase — XSCObject ARC root, XSCString, XSCData, XSCError <Error>, XSCIndexList,
          main-thread queue/timers, and background pthread pool
```

### `XSCBase` ([`XSCBase.h`](../Sources/xsComicLinux/XSCBase.h), [`XSCBase.objc3`](../Sources/xsComicLinux/XSCBase.objc3))

- **Minimal ARC foundation**: `XSCObject` (`__attribute__((objc_root_class))`)
  allocates and disposes directly through `libobjc2` (`class_createInstance` /
  `object_dispose`). `XSCString`, `XSCData` (including zero-copy
  `dataTakingBytesNoCopy:length:`), `XSCError <Error>`, and `XSCIndexList`
  replace Foundation collections and strings without extra runtime baggage.
- **Queues, timers, and clock**: Provides monotonic timing (`xsc_now_ns` /
  `xsc_now_ms`), a main-thread dispatch and delayed-timer queue
  (`xsc_dispatch_main`, `xsc_dispatch_main_after_ms`, `xsc_main_drain`) with a
  wakeup hook (`xsc_set_main_wakeup`) shared by both SDL2 and headless tests, a
  background pthread worker pool (`xsc_dispatch_bg`), and recursive POSIX tree
  removal (`xsc_remove_tree`).

### `XSCArchive` ([`XSCArchive.h`](../Sources/xsComicLinux/XSCArchive.h), [`XSCArchive.objc3`](../Sources/xsComicLinux/XSCArchive.objc3))

- **CBZ/ZIP & CBT/tar**: Opened with `O_RDONLY | O_NONBLOCK`, verified with
  `fstat` (`S_ISREG`), and read via stateless `pread(2)` rather than `mmap` so
  an unplugged drive or dropped network mount returns `EIO` instead of raising
  `SIGBUS`. STORE entries read straight from disk; DEFLATE entries inflate via
  `zlib` raw-DEFLATE (`inflateInit2(..., -MAX_WBITS)`) with strict size bounds
  (256 MiB per page, 64 MiB Central Directory, 100,000 entries max) and a
  1-byte overflow sentinel to defeat zip bombs. Supports Zip64 and
  ustar/PAX/GNU LongName TAR headers with zero temporary files written.
- **CBR/RAR & CB7/7z**: Streamed in-process via `libarchive`, switching only
  the calling thread to a UTF-8 `LC_CTYPE` locale via `uselocale()` + `defer`
  so Unicode entry names decode cleanly under the default `"C"` locale.
  Payloads stay in memory up to 256 MiB and spill overflow pages to a private
  per-process directory (`/tmp/xsComic-XXXXXX`, cleaned on error via `defer`,
  on book `-dealloc`, and on exit via `atexit(3)`).
- **Directories & adjacent volumes**: Walked with `opendir`/`readdir`
  (`d_type`, falling back to `lstat` on `DT_UNKNOWN`, max depth 64), packing
  all relative paths into a single flat UTF-8 byte arena and opening leaf files
  component-by-component with `O_NOFOLLOW`. `adjacentVolumePathFor:step:cancelFlag:`
  locates the next or previous readable sibling archive or image folder in
  natural order.

### `XSCImageStore` ([`XSCImageStore.h`](../Sources/xsComicLinux/XSCImageStore.h), [`XSCImageStore.objc3`](../Sources/xsComicLinux/XSCImageStore.objc3))

- **Bounded cache & zero-hop fast path**: Default hard limits of 12 entries and
  64 MiB logical bytes, with retention-aware LRU eviction, in-flight request
  coalescing (promoting queued prefetches to visible demand on page turns), and
  a bounded negative cache. `cachedPageForBook:index:` acquires a
  `pthread_mutex_t`, probes a compact open-addressed C hash table (47.7 ns/call
  median on arm64), pins the page non-volatile, and returns
  `Optional(XSCDecodedPage *)` synchronously with zero thread hops.
- **Native codecs & EXIF**: Decodes via `libjpeg-turbo` (`JCS_GRAYSCALE` and
  `JCS_EXT_RGBA`), `libpng`, `libwebp`, `giflib` (static and full multi-frame
  composited animated GIFs with per-frame delays), `libtiff` (in-memory
  `TIFFClientOpen`), `libavif`, `libheif`, and a built-in 24/32-bit BMP
  decoder. Parses EXIF 1–8 orientation tags and enforces a 16,384 px texture
  dimension cap.
- **4× grayscale RAM savings & purgeable memory**: Monochrome JPEG/PNG pages
  decode straight into 8-bit `L8` buffers. Static `RGBA8` pages run a 32×32
  chroma probe (`A >= 253`, `|R-G| <= 2`, `|G-B| <= 2`) and repack visually
  grayscale manga to `L8` while immediately `munmap`-ing the 4× larger `RGBA8`
  buffer. Pixel buffers live in page-aligned anonymous
  `mmap(MAP_PRIVATE | MAP_ANONYMOUS)` allocations with 64-byte row alignment;
  off-screen cached pages are marked volatile via `madvise(MADV_FREE)` so Linux
  can reclaim them under memory pressure without swapping.
- **Concurrency**: 4-lane priority pthread decode pool capping background
  prefetch/pre-warm work at 3 active lanes so 1 lane is always reserved for
  visible demand.

### `XSCGLCanvas` ([`XSCGLCanvas.h`](../Sources/xsComicLinux/XSCGLCanvas.h), [`XSCGLCanvas.objc3`](../Sources/xsComicLinux/XSCGLCanvas.objc3))

- Renders directly through OpenGL 3.3 Core, uploading `L8` pages as `GL_R8`
  (1 Bpp) and color pages as `GL_RGBA8` (4 Bpp) using `GL_UNPACK_ROW_LENGTH` to
  honor 64-byte-aligned row strides.
- Compiles an inline GLSL 330 Core shader once at startup using an empty VAO
  and `gl_VertexID` quads. The fragment shader performs EXIF 1–8 orientation
  transforms, 6×6 separable Lanczos-3 downscaling whenever the downscale ratio
  exceeds `1.05×` (switching to linear sampling for upscaling or 1:1), `.rrr1`
  grayscale swizzling for `GL_R8` textures, and a 1 backing-pixel hairline
  border.
- Decode-once, GPU-scale-always: focal-point zooming (`0.1×`–`16×`), drag
  panning, resizing, and toggling the sidebar never re-decode images.
  Multi-frame animated GIFs advance in-place via `tickAnimationAtMs:`.

### `XSCReaderModel` & desktop shell ([`XSCReaderModel.h`](../Sources/xsComicLinux/XSCReaderModel.h), [`XSCReaderModel.objc3`](../Sources/xsComicLinux/XSCReaderModel.objc3), [`main.objc3`](../Sources/xsComicLinux/main.objc3))

- **Archive-order navigation & zero-hop turns**: `currentIndex` always walks
  `0 ..< pageCount` aligned to the spread step; RTL reverses only
  `visualPageIndices`. Synchronous cache hits update `XSCGLCanvas` in the same
  event turn. Cold decodes hold the previous spread for a 120 ms loading grace
  period before revealing the loading overlay.
- **Prefetch & adjacent-volume pre-warming**: Prefetches 8 pages ahead and 2
  behind, flipping bias backward after 2 consecutive backward turns. Within 3
  pages of either volume boundary (when volume continuation is enabled), the
  adjacent volume is opened and its boundary page(s) pre-decoded off-main so
  crossing volumes swaps seamlessly.
- **Desktop shell (`main.objc3`)**: Single-process SDL2 + OpenGL 3.3 Core +
  `SDL2_ttf` (DejaVu Sans / Liberation Sans) reactive event loop using
  `SDL_WaitEventTimeout` woken instantaneously by a registered SDL user event
  from `xsc_set_main_wakeup` (zero busy-wait). Draws dark-chrome UI elements
  via an inline SDF rounded-rectangle shader and an LRU glyph texture cache:
  top toolbar, collapsible 180 px page sidebar, empty-state CTA card, direct
  Jump-to-Page modal, settings popover persisted to
  `$XDG_CONFIG_HOME/xscomic/prefs.ini` (default `~/.config/xscomic/prefs.ini`),
  drag-and-drop (`SDL_DROPFILE`), off-main file chooser (`zenity` / `kdialog`),
  and deterministic `--screenshot` PNG capture via `libpng`.

## Controls and CLI options

### Keyboard and pointer

| Input | Action |
| --- | --- |
| `Left` / `Right` | Turn page (respects RTL key-swap preference) |
| `Space` / `Shift+Space`, `PageDown` / `PageUp` | Next / previous page or spread |
| `Home` / `End` | First / last page |
| `Ctrl+O` | Open comic (`zenity` / `kdialog`) — or drag & drop onto window |
| `Ctrl+Shift+G` or `G` | Open Jump-to-Page modal |
| `B` or `Ctrl+Alt+S` | Toggle page sidebar |
| `D` / `Ctrl+D` | Toggle LTR / RTL reading direction |
| `P` / `Ctrl+P` | Toggle Single / Two-page spread mode |
| `+` / `-`, `Ctrl`+scroll, trackpad pinch | Zoom in / out (focal-point on pointer/pinch) |
| `0` / `F` / `Ctrl+0`, `1` / `Ctrl+1` | Fit to window / 100% actual size |
| Left-drag (while zoomed) | Pan canvas |
| `Ctrl+,` | Toggle Settings popover |
| `Esc` / `Ctrl+Q` | Dismiss modal/popover/banner / Quit |

### CLI flags

```text
build/linux/xscomic [options] [book_path]
  --single            Start in single-page mode
  --double            Start in two-page spread mode
  --ltr               Start in left-to-right reading direction
  --rtl               Start in right-to-left reading direction
  --sidebar           Start with the page sidebar open
  --page N            Jump to 1-based page N after opening
  --zoom SCALE        Set custom zoom scale (e.g. 1.5)
  --size WxH          Start with initial window dimensions (e.g. 640x480)
  --jump-modal        Open the Jump-to-Page modal
  --settings          Open the Settings popover
  --screenshot PATH   Render frame, save PNG to PATH, and exit
```

## Measured footprint and benchmarks

Measured on Debian 13.8 (`aarch64`, `objc3c` `v0.1.0-preview.1` / Clang 23.1.5,
GNUstep 2.2 ABI, `-Oz -flto=thin -Wl,--gc-sections -Wl,--as-needed` + `strip`).
Full section breakdown, sanitizers, and raw run samples are recorded in
[`../Metrics/linux-objc3.json`](../Metrics/linux-objc3.json):

| Metric | Measured |
| --- | --- |
| Stripped `build/linux/xscomic` | **284.0 KiB** (290,848 bytes; `text` 259,369 B, `data` 27,492 B, `bss` 5,032 B) |
| Unstripped `build/linux/xscomic.symbols` | **441.1 KiB** (451,664 bytes) |
| Debug `-O0 -g` binary | **873.6 KiB** (894,560 bytes) |
| Direct dynamic dependencies (`readelf -d`) | **16** (`ldd -u -r`: 0 unused; zero GNUstep-Base) |
| Standalone tests ([`Tests/xsComicLinuxTests/main.objc3`](../Tests/xsComicLinuxTests/main.objc3)) | **183 passed, 0 failed** (3/3 runs; ASan+UBSan+LSan & TSan 3/3 clean) |
| 4,096-file directory scan (3 runs) | **1.13 ms** median (1.12 ms fastest) |
| 128-page CBZ open (3 runs) | **0.035 ms** median (0.034 ms fastest) |
| 500-page CBZ open (3 runs) | **0.075 ms** median (0.070 ms fastest) |
| Cold 1024×1536 JPEG decode (3 runs) | **2.66 ms** median (2.63 ms fastest) |
| Synchronous cache-hit lookup (10,000 hits, 3 runs) | **47.7 ns/call** median (47.5 ns/call fastest) |
| Test process RSS (`/proc/self/statm`, 3 runs) | **42.80 MiB** median (42.68 MiB lowest) |
| Cold launch-to-render, 10p 1024×1536 CBZ (1280×800, Mesa llvmpipe) | **105.10 ms** median direct on Xvfb (99.76 ms fastest) / **154.37 ms** via `xvfb-run` |
