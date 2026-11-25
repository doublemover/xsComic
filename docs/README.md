# Documentation

- [Project guide](guide.md) — architecture, I/O, GPU rendering, and invariants.
- [Release procedure](releasing.md) — packaging, Developer ID signing, notarization, and DMG creation.
- [Optimization record](optimization.md) — historical 1.0 optimization log and measurements.

Raw JSON measurements live in [`../Metrics/`](../Metrics/).

## Repository layout

```text
.
├── VERSION                   release version
├── Sources/xsComic/          Objective-C / AppKit / Metal application
├── Tests/xsComicTests/       standalone test and benchmark suite
├── Assets/                   compiled Assets.car, alternate SVG, and brand masters
├── Metrics/                  historical measurement records
├── docs/                     architecture and release docs
└── scripts/                  build, test, icon, and DMG scripts
```

Only `Assets/Assets.car` and `Assets/Brand/xsComic-azusa-app-mark.svg` ship in
the app bundle. No Xcode project, vendored libraries, telemetry, or updater.

Code is AGPL-3.0-or-later, docs/metrics are CC BY-SA 4.0, and branding is
excluded. See [`../LICENSING.md`](../LICENSING.md).

## Commands

```sh
# Build and launch a release app.
./scripts/build-and-run.sh

# Build a debug binary for LLDB.
./scripts/build-and-run.sh --debug

# Run tests and benchmarks.
./scripts/run-tests.sh

# Build the app bundle and reproducible ZIP / tar.xz archives.
./scripts/build-app.sh --archive

# Build the themed arm64 DMG.
./scripts/build-dmg.sh arm64
```

Build outputs land in `build/` (gitignored). Local builds are ad-hoc signed by
default; see [releasing.md](releasing.md) for Developer ID signing and
notarization.
