<p align="center">
  <img src="Assets/Brand/xsComic-lockup.png" alt="xsComic" width="420">
</p>

**xsComic** is a native macOS reader for CBR/CBZ/etc. I cooked it up
because I wanted to read *Beastars* (sue me), didn't want unvetted
third-party software on my work partition, and realized because Codex
could make something passable in five minutes.

I then decided to run an experiment: can an LLM — tools (entities?)
that have gained infamy for their wild preference for adding lines
over deleting them — successfully write aggressively footprint-optimized
software? And can it write code that's "good," not simply "working"?
Recent models (post-January '26, basically) have seemed, perhaps,
capable of doing so.

*Reader, be advised: LLM writing is to follow.*

I believe the experiment to have been a success. Its result is a 510 KB app bundle,
about 220 KB of which is icon resources. It launches very quickly and includes no
third-party code. The source, from what I've seen, is legibile, well-structured,
and even educational. (The RAM footprint could still use some work.)

*Reader, be advised: human language stops here.*

## What it does

- Reads CB7/7z, CBR/RAR, CBT/tar, CBZ/ZIP, and image folders (`.avif`, `.bmp`, `.gif`, `.heic`/`.heif`, `.jpg`/`.jpeg`, `.png`, `.tif`/`.tiff`, `.webp`).
- Single-page and two-page spreads, left-to-right or right-to-left.
- Keyboard navigation, focal-point zoom, drag panning, fit, and actual size.
- Collapsible page sidebar, direct page jump (`Cmd+Shift+G` on macOS, `Ctrl+Shift+G` / `G` on Linux), and adjacent-volume continuation.
- Zero-extraction `pread` archive reading, GPU downscaling with EXIF 1–8 orientation, 8-bit grayscale repacking, and bounded page caching.

## macOS

Native **Objective-C, AppKit, and Metal** (`Sources/xsComic/`, `Tests/xsComicTests/`). Requires macOS 14+ on Apple Silicon (`arm64`); Intel users can stay on [v1.0.0](https://github.com/linusmixson/xsComic/releases/tag/v1.0.0).

```sh
./scripts/build-and-run.sh
./scripts/run-tests.sh
./scripts/build-app.sh --archive
```

Compiles directly with `clang` against macOS system frameworks and libraries (`AppKit`, `Metal`, `ImageIO`, `IOSurface`, `Accelerate`, `libcompression`, `libarchive`) into `build/product/xsComic.app`. No Xcode project, no third-party dependencies.

## Linux (Slopjective-C / Objective-C 3.0)

Native **Objective-C 3.0, SDL2, and OpenGL 3.3 Core** port (`Sources/xsComicLinux/`, `Tests/xsComicLinuxTests/`) targeting Linux (`aarch64` / `x86_64`, verified on Debian 13), compiled with [**Slopjective-C**](https://github.com/doublemover/Slopjective-C) (`objc3c` `v0.1.0-preview.1`, patched Clang 23.1.5, GNUstep 2.2 ABI + `libobjc2`, zero GNUstep-Base).

```sh
# Build the stripped release binary (build/linux/xscomic)
./scripts/build-linux.sh --release

# Run the Linux core test and benchmark suite
./scripts/run-linux-tests.sh

# Build and launch (interactive X11/Wayland or headless --screenshot)
./scripts/build-and-run-linux.sh [args...]
```

Compiles `.objc3` sources directly with `objc3c` (`-Oz -flto=thin -Wl,--gc-sections -Wl,--as-needed` + `strip`) against system Linux libraries (`zlib`, `libarchive`, `libjpeg-turbo`, `libpng`, `libwebp`, `giflib`, `libtiff`, `libavif`, `libheif`, `SDL2`, `SDL2_ttf`, OpenGL, `pthreads`). On Linux with `objc3c` (or `/opt/objc3c/activate.sh`) installed, all scripts run natively; on macOS or hosts without the SDK, they automatically build and delegate through [`scripts/docker-env.sh`](scripts/docker-env.sh) and [`docker/Dockerfile`](docker/Dockerfile).

[Linux CI](.github/workflows/linux.yml) builds the pinned SDK image on x86-64
and AArch64. Each runner runs the core suite and a release smoke test covering
rendered images and X11 interaction.

[macOS CI](.github/workflows/macos.yml) builds and verifies the AppKit app on
Apple Silicon and runs its reader tests in parallel. It uses the `macos-26`
runner by default. A manual run can select `macos-15` if runner allocation
fails. The Objective-C 3 core also has a native qualification entry point
for the experimental Darwin SDK. Use the Xcode
version required by the installed SDK and install the codec dependencies.
[Slopjective-C #8340](https://github.com/doublemover/Slopjective-C/issues/8340)

```sh
brew install pkg-config libarchive jpeg-turbo libpng webp libtiff libavif libheif giflib
XSCOMIC_OBJC3_SDK="/path/to/installed/Darwin SDK" ./scripts/run-objc3-macos-tests.sh
```

The script builds the same core sources and test suite on Apple Silicon.
Build logs, SDK identity, library paths, and results are saved under
`build/objc3-macos-tests/`.

The original port's benchmark snapshot was recorded on Debian 13
(`aarch64`). The [measurement record](Metrics/linux-objc3.json) includes the source digest.

| Metric | Measured |
| --- | --- |
| Stripped `build/linux/xscomic` | **284.0 KiB** (290,848 bytes; 16 direct shared libs, 0 unused) |
| Test suite (`./scripts/run-linux-tests.sh`) | **183 passed, 0 failed** (ASan + UBSan + LSan + TSan clean) |
| 4,096-file directory scan | **1.13 ms** median (1.12 ms best) |
| 128-page / 500-page CBZ open | **0.035 ms** / **0.075 ms** median |
| Cold 1024×1536 JPEG decode | **2.66 ms** median (2.63 ms best) |
| Synchronous cache-hit lookup | **47.7 ns/call** median (47.5 ns/call best) |
| Cold CBZ launch-to-render (Xvfb + Mesa llvmpipe) | **105.1 ms** median direct / **154.4 ms** via `xvfb-run` |

See [`docs/linux.md`](docs/linux.md) for architecture, controls, CLI options, and cache invariants.

## Docs

- [`docs/README.md`](docs/README.md) — dual-platform repository layout and commands
- [`docs/guide.md`](docs/guide.md) — macOS architecture, I/O, Metal rendering, and cache invariants
- [`docs/linux.md`](docs/linux.md) — Linux Objective-C 3.0 architecture, OpenGL 3.3 rendering, controls, and CLI flags
- [`docs/optimization.md`](docs/optimization.md) — historical macOS 1.0 optimization record and measurements
- [`docs/releasing.md`](docs/releasing.md) — macOS packaging, signing, notarization, and DMG builds
- [`Metrics/`](Metrics/) — raw measurement records (macOS + [`Metrics/linux-objc3.json`](Metrics/linux-objc3.json))

## License

Code is **AGPL-3.0-or-later**. Docs and measurements are **CC BY-SA 4.0**. The xsComic name and everything under `Assets/` are excluded; see [`LICENSING.md`](LICENSING.md).
