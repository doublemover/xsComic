# Documentation

The root README is intentionally a light introduction. This directory holds the
machinery: how xsComic works, why it is shaped this way, how its claims are
measured, and what remains before a public binary release.

## Reading route

Read these in order:

1. [Project guide](guide.md) explains what xsComic does and how its six source
   files cooperate.
2. [Release procedure](releasing.md) turns the SwiftPM executable into a
   distribution-ready macOS artifact.
3. [Optimization record](optimization.md) preserves the measurements and
   reasoning behind the current performance and size policy.

Historical measurements live in [`../Metrics/`](../Metrics/). They are kept
outside `docs/` because they are machine-readable evidence rather than prose.

## Repository map

```text
.
├── Package.swift                 SwiftPM package definition
├── VERSION                       single source of release version
├── Sources/ComicBookReader/      six production source files
├── Tests/ComicBookReaderTests/   correctness, replay, and benchmark tests
├── Assets/                       shipped icons and repository-only artwork
├── Metrics/                      immutable historical measurements
├── docs/                         guides and engineering record
└── scripts/                      build, run, icon, and measurement tools
```

Only `Assets/Assets.car`, `Assets/AppIcon.icns`, and
`Assets/Brand/xsComic-azusa-app-mark.svg` enter the app bundle. The larger
raster artwork and wordmark are repository branding material.

The project intentionally has no Xcode project, generated source, vendored
library, telemetry, database, updater, or plug-in system.

Licensing is intentionally split. Code is AGPL-3.0-or-later; documentation and
measurements are CC BY-SA 4.0; branding is not licensed. See
[`../LICENSING.md`](../LICENSING.md). A redistributable fork must supply its own
name and replace `Assets/`.

## Everyday commands

```sh
# Build and launch a release app.
./scripts/build-and-run.sh

# Build under LLDB.
./scripts/build-and-run.sh --debug

# Run correctness tests in a fresh scratch directory.
swift test --scratch-path build/test

# Check the house source style.
swift format lint --strict --recursive Sources Tests Package.swift

# Create the local app and ZIP/tar.xz archives.
./scripts/build-app.sh --archive

# Create themed drag-to-Applications disk images from those apps.
./scripts/build-dmg.sh x86_64
./scripts/build-dmg.sh arm64

# Cross-build an ARM64 release on an Intel development Mac.
CBR_TARGET_TRIPLE=arm64-apple-macosx14.0 \
CBR_OUTPUT_DIR=build/product-arm64 \
CBR_SCRATCH_PATH=build/swiftpm-arm64 \
./scripts/build-app.sh --archive

# Record a full release-size and performance checkpoint.
./scripts/measure.sh local

# Re-run the static-versus-adaptive prefetch experiment.
./scripts/measure-predictor.sh
```

Generated products go under `build/` and are ignored by Git. See the
[release procedure](releasing.md) before distributing them: the default local
signature is deliberately ad hoc.
