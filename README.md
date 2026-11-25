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

- Reads CB7/7z, CBR/RAR, CBT/tar, CBZ/ZIP, and image folders.
- Single-page and two-page spreads, left-to-right or right-to-left.
- Keyboard navigation, focal-point pinch zoom, drag panning, fit, and actual size.
- Page sidebar, direct page jump (`Cmd+Shift+G`), and adjacent-volume continuation.
- Zero-extraction archive reading, Metal Lanczos-3 scaling, and purgeable `IOSurface` page caching.

Requires macOS 14+ on Apple Silicon (`arm64`). Intel users can use [v1.0.0](https://github.com/linusmixson/xsComic/releases/tag/v1.0.0).

## Build and test

```sh
./scripts/build-and-run.sh
./scripts/run-tests.sh
```

Compiles directly with `clang` against macOS system frameworks and libraries (`AppKit`, `Metal`, `ImageIO`, `IOSurface`, `Accelerate`, `libcompression`, `libarchive`). No Xcode project, no third-party dependencies.

## Docs

- [`docs/guide.md`](docs/guide.md) — architecture, I/O, rendering, and cache invariants
- [`docs/optimization.md`](docs/optimization.md) — historical 1.0 optimization record and measurements
- [`docs/releasing.md`](docs/releasing.md) — packaging, signing, notarization, and DMG builds
- [`Metrics/`](Metrics/) — raw measurement records

## License

Code is **AGPL-3.0-or-later**. Docs and measurements are **CC BY-SA 4.0**. The xsComic name and everything under `Assets/` are excluded; see [`LICENSING.md`](LICENSING.md).
