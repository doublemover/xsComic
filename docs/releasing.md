# Releasing xsComic

This is the direct-distribution procedure for the macOS app. It separates
checks the repository can perform from publisher-owned facts such as
certificate identity, notarization credentials, legal terms, and a permanent
bundle identifier.

## Current release identity

- product: xsComic
- version: `2.0.0` from [`../VERSION`](../VERSION)
- minimum system: macOS 14 on Apple Silicon (`arm64` only)
- executable: `ComicBookReader` (internal and intentionally stable)
- default bundle identifier: `com.xscomic.app`
- local artifact: `build/product/xsComic.app`
- archives: `xsComic-<version>.zip` and `xsComic-<version>.tar.xz`
- disk image: `xsComic-<version>-arm64.dmg`

The primary xsComic mark is compiled into `Assets/Assets.car` (a single
32-color 512×512 `256x256@2x` rendition compiled with `actool --optimization space`,
~32 KB). It is copied to `Contents/Resources/Assets.car`, referenced by
`CFBundleIconName` (`AppIcon`) in the binary `Info.plist`, and sealed by the
app signature. Legacy `AppIcon.icns` is no longer packaged inside the `.app`
bundle on macOS 14+ (the checked-in `Assets/AppIcon.icns` is used only as the
DMG `.VolumeIcon.icns`). The settings-controlled alternate ships as
`Contents/Resources/AppIcon-Azusa.svg` and is clipped at runtime with the alpha
of macOS's system-rendered primary icon. No raster branding master is packaged.

## Before calling a build public

The publisher must settle these facts; the repository must not invent them:

- confirm ownership of the permanent reverse-DNS bundle identifier;
- set a public security-reporting route and support location;
- provide release copyright/attribution if desired;
- decide Developer ID direct distribution versus the Mac App Store;
- obtain the appropriate Apple signing identity and notarization credentials.

The repository license is already settled: software is AGPL-3.0-or-later,
documentation and measurements are CC BY-SA 4.0, and no license is granted for
branding. See [`../LICENSING.md`](../LICENSING.md). Third-party builds must
replace `Assets/` and the xsComic identity; publishing the source files does not
authorize reuse of those materials.

## 1. Prepare the source

1. Update `VERSION` with two or three dot-separated integers.
2. Update `CHANGELOG.md` and review user-visible changes.
3. Confirm the tree contains no generated `build/`, Finder metadata, archives,
   credentials, or notarization profiles.
4. Run the standalone arm64 Objective-C test and benchmark suite:

   ```sh
   ./scripts/run-tests.sh
   ```

   This compiles `Tests/xsComicTests/main.m` against
   `Sources/xsComic/{XSCArchive,XSCImageStore,XSCReaderModel}.m` with
   `clang -Wall -Wextra`, runs all archive, security, navigation, and image
   store tests, and reports directory-scan, CBZ-open, cold-decode, and
   synchronous cache-hit benchmarks.

## 2. Build a local release candidate

```sh
./scripts/build-app.sh --archive
```

This compiles `Sources/xsComic/*.m` with
`clang -arch arm64 -mmacosx-version-min=14.0 -fobjc-arc -Oz -flto -Wall -Wextra`,
links only Apple system frameworks and libraries (`AppKit`, `CoreGraphics`,
`ImageIO`, `IOSurface`, `Metal`, `QuartzCore`, `Accelerate`, `libcompression`,
`libarchive`), preserves `build/product/xsComic.symbols`, strips the shipped
binary (`strip -S -x -N`), validates it with `dyld_info -validate_only`,
converts `Info.plist` to binary format (`plutil -convert binary1`), signs the
bundle, and writes deterministic `xsComic-<version>.zip` and
`xsComic-<version>.tar.xz` archives.

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

lipo -archs "$APP/Contents/MacOS/ComicBookReader"
plutil -lint "$APP/Contents/Info.plist"
plutil -p "$APP/Contents/Info.plist"
codesign --verify --strict --verbose=4 "$APP"
codesign -d --verbose=4 "$APP"
codesign -d --entitlements :- "$APP"
xcrun dyld_info -validate_only "$APP/Contents/MacOS/ComicBookReader"
otool -L "$APP/Contents/MacOS/ComicBookReader"
size -m "$APP/Contents/MacOS/ComicBookReader"
```

Confirm:

- `lipo -archs` reports `arm64`;
- display name and bundle name are `xsComic`;
- version/build and bundle identifier are the intended release values;
- `CFBundleIconName` is `AppIcon` (and `Assets.car` + `AppIcon-Azusa.svg` are
  present in `Contents/Resources`, with no legacy `AppIcon.icns`);
- the Developer ID authority, hardened runtime, and timestamp are present;
- no unexpected entitlements or third-party dynamic libraries appear.

The bundle has one executable and no nested frameworks or helper tools, so
signing the bundle root after all copies is sufficient; do not use
`codesign --deep`.

## 5. Validate archives

```sh
VERSION=$(<VERSION)
unzip -t "build/product/xsComic-$VERSION.zip"
bsdtar -tf "build/product/xsComic-$VERSION.tar.xz"
```

Extract each archive into a fresh temporary directory and verify the app
signature again. Both archives contain `LICENSE`, `LICENSING.md`, and
`BRANDING.md` outside the app bundle so legal completeness does not increase
installed size or launch work.

Keep `build/product/xsComic.symbols` privately with the release record. It is
the unstripped executable for crash diagnosis and is intentionally absent from
both public archives.

## 6. Build the Apple Silicon disk image

After building the signed arm64 app, create the themed drag-to-Applications
disk image:

```sh
CBR_SIGN_IDENTITY="Developer ID Application: Example (TEAMID)" \
./scripts/build-dmg.sh arm64
```

The read-only LZFSE image (`build/product/xsComic-<version>-arm64.dmg`)
contains `xsComic.app`, an `/Applications` alias, the complete legal notices, a
custom volume icon, and a Finder `.DS_Store` describing the 660 × 440
background and optical icon positions. The script verifies the `arm64` slice,
app signature, and final UDIF checksum, and Developer-ID-signs the DMG with a
secure timestamp when `CBR_SIGN_IDENTITY` is set.

## 7. Notarize and staple

Apple requires a Developer ID signature, hardened runtime, and secure timestamp
for direct-distribution notarization. Submit the DMG (or ZIP) with
`xcrun notarytool submit --wait`, inspect the log, staple the accepted ticket
to both `xsComic.app` (before rebuilding final ZIP/tar.xz if stapling the app)
and `xsComic-<version>-arm64.dmg`, and validate:

```sh
xcrun stapler validate "build/product/xsComic.app"
xcrun stapler validate "build/product/xsComic-$(<VERSION)-arm64.dmg"
spctl --assess --type execute --verbose=4 "build/product/xsComic.app"
```

Follow Apple's current procedures:

- [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
- [Resolving common notarization issues](https://developer.apple.com/documentation/security/resolving-common-notarization-issues)

## 8. Final release record

Record together:

- source commit and exact `clang --version` / macOS SDK version;
- version, build number, and bundle identifier;
- SHA-256 and byte counts of the app executable, ZIP, tar/XZ, DMG, and private
  symbols;
- `./scripts/run-tests.sh` pass/fail count and benchmark numbers;
- notarization submission ID and acceptance log;
- Gatekeeper assessment (`spctl --assess`) and clean smoke test opening a
  directory, CBZ, CBT, CBR, and CB7, plus verifying primary and alternate icons.
