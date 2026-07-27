# Releasing xsComic

This is the direct-distribution procedure for the package-first macOS app. It
separates checks the repository can perform from publisher-owned facts such as
certificate identity, notarization credentials, legal terms, and a permanent
bundle identifier.

## Current release identity

- product: xsComic
- version: `1.0.0` from [`../VERSION`](../VERSION)
- minimum system: macOS 14
- executable/module: `ComicBookReader` (internal and intentionally stable)
- default bundle identifier: `com.xscomic.app`
- local artifact: `build/product/xsComic.app`
- archives: `xsComic-<version>.zip` and `xsComic-<version>.tar.xz`
- disk images: `xsComic-<version>-x86_64.dmg` and
  `xsComic-<version>-arm64.dmg`

The primary xsComic mark is compiled into `Assets/Assets.car` for current macOS
and `Assets/AppIcon.icns` as a backward-compatible fallback. They are copied to
`Contents/Resources`, named by `CFBundleIconName` and `CFBundleIconFile`, and
sealed by the app signature. The settings-controlled alternate ships as
`Contents/Resources/AppIcon-Azusa.svg`. No raster branding master is packaged.
The primary uses a full square canvas and leaves rounded-corner masking to
macOS. Because `applicationIconImage` treats runtime overrides as finished
artwork, the app clips the alternate with the alpha of its current
system-rendered primary icon. The alternate SVG therefore stores composition,
not a platform-radius approximation. The ICNS contains ten independently
validated legacy and Retina renditions from 16 through 1024 pixels.

## Before calling a build public

The publisher must settle these facts; the repository must not invent them:

- confirm ownership of the permanent reverse-DNS bundle identifier;
- set a public security-reporting route and support location;
- provide release copyright/attribution if desired;
- decide Developer ID direct distribution versus the Mac App Store;
- obtain the appropriate Apple signing identity and notarization credentials.

Until those are resolved, the output is a release candidate, not a responsibly
published public release.

The repository license is already settled: software is AGPL-3.0-or-later,
documentation and measurements are CC BY-SA 4.0, and no license is granted for
branding. See [`../LICENSING.md`](../LICENSING.md). Third-party builds must
replace `Assets/` and the xsComic identity; publishing the source files does not
authorize reuse of those materials.

## 1. Prepare the source

1. Update `VERSION` with two or three dot-separated integers.
2. Review user-visible changes and write release notes.
3. Confirm the tree contains no generated `.build/`, `build/`, Finder metadata,
   archives, credentials, or notarization profiles.
4. Inspect the dependency graph:

   ```sh
   swift package show-dependencies
   ```

   It should contain only the root package.

5. Lint and test:

   ```sh
   swift format lint --strict --recursive Sources Tests Package.swift
   swift test --scratch-path build/release-test
   ```

## 2. Produce and measure a local candidate

Run:

```sh
./scripts/measure.sh release
```

This performs a clean release build, creates both archives, runs correctness
tests and opt-in benchmarks, validates metrics, and writes
`Metrics/release.json`. Compare it with the previous immutable checkpoint:

```sh
jq '{source, correctness, distribution, runtime_policy}' \
  Metrics/readability.json Metrics/release.json
```

Keep a changed footprint only when its cause is understood. Timings can vary
with host load; byte counts, policy values, failures, and structural checks are
hard gates.

### Cross-architecture candidate

An Intel Mac can build and structurally inspect ARM64, but it cannot run the
result. Cross-build it into separate mutable trees:

```sh
CBR_TARGET_TRIPLE=arm64-apple-macosx14.0 \
CBR_OUTPUT_DIR=build/product-arm64 \
CBR_SCRATCH_PATH=build/swiftpm-arm64 \
./scripts/build-app.sh --archive
```

Confirm the executable with `file`, `lipo -archs`, `otool -L`, `size -m`, and
`codesign --verify`. Record its byte counts separately from the native metrics.
Do not label Intel test or benchmark results as ARM64 results. Runtime
correctness and performance require an Apple Silicon machine; cross-compilation
proves only that ARM64 compiles, links, packages, and signs.

## 3. Build with Developer ID

The default is intentionally ad-hoc signing for local work. For direct public
distribution, locate the exact certificate:

```sh
security find-identity -v -p codesigning
```

Then build using that full identity and the publisher's permanent bundle ID:

```sh
CBR_SIGN_IDENTITY="Developer ID Application: Example (TEAMID)" \
CBR_BUNDLE_ID="com.example.xscomic" \
CBR_BUILD_NUMBER=1 \
./scripts/build-app.sh --archive
```

When `CBR_SIGN_IDENTITY` is not `-`, the script signs with a trusted timestamp
and hardened runtime. Do not put signing identities, passwords, app-specific
passwords, API keys, or keychain profiles in the repository.

## 4. Inspect the exact app

```sh
APP="build/product/xsComic.app"

plutil -lint "$APP/Contents/Info.plist"
plutil -p "$APP/Contents/Info.plist"
codesign --verify --strict --verbose=4 "$APP"
codesign -d --verbose=4 "$APP"
codesign -d --entitlements :- "$APP"
xcrun dyld_info -validate_only \
  "$APP/Contents/MacOS/ComicBookReader"
otool -L "$APP/Contents/MacOS/ComicBookReader"
```

Confirm:

- display name and bundle name are `xsComic`;
- version/build and bundle identifier are the intended release values;
- `CFBundleIconFile` is `AppIcon`;
- `CFBundleIconName` is `AppIcon`;
- `Assets.car`, `AppIcon.icns`, and `AppIcon-Azusa.svg` are present;
- the primary ICNS is nonempty and recognized by `iconutil`;
- the Developer ID authority, hardened runtime, and timestamp are present;
- no unexpected entitlements or dynamic libraries appear.

The bundle has one executable and no nested frameworks or helper tools, so
signing the bundle root after all copies is sufficient; do not use
`codesign --deep` to conceal an incomplete signing order.

## 5. Validate archives

```sh
VERSION=$(<VERSION)
unzip -t "build/product/xsComic-$VERSION.zip"
bsdtar -tf "build/product/xsComic-$VERSION.tar.xz"
```

Extract each archive into a fresh temporary directory and verify the app
signature again. The ZIP is the normal Finder-facing release. The tar/XZ is the
same app with a smaller transfer container for users who value bytes over
convenience. Both archives also contain `LICENSE`, `LICENSING.md`, and
`BRANDING.md`. Those notices sit outside the app bundle, so legal completeness
does not increase installed size or launch work.

Keep `build/product/xsComic.symbols` privately with the release record. It is
the unstripped executable for crash diagnosis and is intentionally absent from
both public archives.

## 6. Build disk images

After producing the architecture-specific apps, create the themed
drag-to-Applications images:

```sh
./scripts/build-dmg.sh x86_64
./scripts/build-dmg.sh arm64
```

Each read-only LZFSE image contains the correctly sliced app, an
`/Applications` alias, the complete legal notices, a custom volume icon, and a
Finder `.DS_Store` describing the 660 × 440 background and optical icon
positions. The script verifies the app architecture, app signature, and final
UDIF checksum. With `CBR_SIGN_IDENTITY` set, it also Developer-ID-signs the DMG
using a secure timestamp.

Finder and HFS write per-image identifiers and timestamps, so two structurally
identical DMGs need not be byte-for-byte identical; record the checksum and
size of each exact release image. The packager removes `.fseventsd`,
`.Spotlight-V100`, `.TemporaryItems`, and `.Trashes` before freezing the image.
The ZIP and tar/XZ—not the Finder-authored DMGs—are the byte-reproducible
containers.

Mount each finished image read-only and confirm the background, icon alignment,
alias target, legal folder, and embedded app signature. Finder counts its
28-point title bar inside window bounds, so the saved 660 × 468 window exposes
the complete 660 × 440 background.

## 7. Notarize and staple

Apple requires a Developer ID signature, hardened runtime, and secure timestamp
for current direct-distribution notarization. Store credentials in a keychain
profile, then submit the ZIP with `notarytool`, wait for success, and inspect
the returned log. Staple the accepted ticket to the app, rebuild the
distribution archive from that exact stapled app if needed, and validate:

```sh
xcrun stapler validate "build/product/xsComic.app"
spctl --assess --type execute --verbose=4 "build/product/xsComic.app"
```

Follow Apple's current procedures rather than copying credentials or brittle
command details into this repository:

- [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
- [Resolving common notarization issues](https://developer.apple.com/documentation/security/resolving-common-notarization-issues)

## 8. Final release record

Record together:

- source commit and source digest from `Metrics/release.json`;
- version, build number, bundle identifier, macOS/Swift versions;
- SHA-256 of app executable, ZIP, tar/XZ, and private symbols;
- exact artifact byte counts;
- test count and failures;
- notarization submission ID and acceptance log;
- Gatekeeper assessment from a clean user account or test Mac;
- a smoke test opening a directory and each promised archive family;
- confirmation that the primary icon appears in Finder, Dock, app switcher, and
  About panel, and that the alternate setting can switch away and back.

The app may launch locally without notarization; that is not evidence that a
quarantined download will pass Gatekeeper on someone else's Mac.
