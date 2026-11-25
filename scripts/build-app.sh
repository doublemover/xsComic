#!/bin/zsh
set -euo pipefail

# Compile and package xsComic directly with clang + Apple system frameworks.
# Phases are linear and deterministic:
#
#   validate paths -> lock mutable trees -> compile (arm64 ObjC) -> assemble
#   -> strip/validate/binary-plist/sign -> optionally create reproducible archives
ROOT=${0:A:h:h}
cd "$ROOT"
export TZ=UTC
source "$ROOT/scripts/build-support.sh"

ARCHIVE=false
CONFIGURATION=release
case ${1:-} in
    "")
        ;;
    --archive)
        ARCHIVE=true
        ;;
    --debug)
        CONFIGURATION=debug
        ;;
    *)
        echo "usage: $0 [--archive|--debug]" >&2
        exit 2
        ;;
esac

SCRATCH_PATH=${CBR_SCRATCH_PATH:-"$ROOT/build/clang"}
SCRATCH_PATH=${SCRATCH_PATH:A}
OUTPUT_DIR=${CBR_OUTPUT_DIR:-"$ROOT/build/product"}
OUTPUT_DIR=${OUTPUT_DIR:A}
VERSION=$(<"$ROOT/VERSION")
BUILD_NUMBER=${CBR_BUILD_NUMBER:-1}
BUNDLE_ID=${CBR_BUNDLE_ID:-com.xscomic.app}
SIGN_IDENTITY=${CBR_SIGN_IDENTITY:--}
if [[ ! "$VERSION" =~ '^[0-9]+([.][0-9]+){1,2}$' ]]; then
    echo "VERSION must contain two or three dot-separated integers." >&2
    exit 2
fi
if [[ ! "$BUILD_NUMBER" =~ '^[1-9][0-9]*$' ]]; then
    echo "CBR_BUILD_NUMBER must be a positive integer." >&2
    exit 2
fi
if [[ ! "$BUNDLE_ID" =~ '^[A-Za-z0-9-]+([.][A-Za-z0-9-]+)+$' ]]; then
    echo "CBR_BUNDLE_ID must be a reverse-DNS-style identifier." >&2
    exit 2
fi
validate_mutable_path "$SCRATCH_PATH" "Build scratch path" "$ROOT"
validate_mutable_path "$OUTPUT_DIR" "Output directory" "$ROOT"
require_disjoint_paths \
    "$OUTPUT_DIR" "$SCRATCH_PATH" \
    "Output directory" "Build scratch path"

ARCHIVE_STAGE=""
BUNDLE_STAGE=""
PREVIOUS_APP=""
OWNS_OUTPUT_LOCK=false
OWNS_SCRATCH_LOCK=false
cleanup_build() {
    if [[ -n "$ARCHIVE_STAGE" ]]; then
        rm -rf "$ARCHIVE_STAGE"
    fi
    if [[ -n "$BUNDLE_STAGE" ]]; then
        rm -rf "$BUNDLE_STAGE"
    fi
    if [[ -n "$PREVIOUS_APP" && ( -e "$PREVIOUS_APP" || -L "$PREVIOUS_APP" ) ]]; then
        if [[ -e "$APP" || -L "$APP" ]]; then
            rm -rf "$PREVIOUS_APP"
        else
            mv "$PREVIOUS_APP" "$APP"
        fi
    fi
    if $OWNS_SCRATCH_LOCK; then
        rmdir "$SCRATCH_LOCK_DIR" 2>/dev/null || true
    fi
    if $OWNS_OUTPUT_LOCK; then
        rmdir "$OUTPUT_LOCK_DIR" 2>/dev/null || true
    fi
}
trap cleanup_build EXIT

OUTPUT_LOCK_DIR=$(mutable_lock_path_for "$OUTPUT_DIR")
OUTPUT_LOCK_TOKEN=${CBR_INTERNAL_OUTPUT_LOCK_TOKEN:-}
if [[ -n "$OUTPUT_LOCK_TOKEN" ]]; then
    if [[ ! "$OUTPUT_LOCK_TOKEN" =~ '^[A-Za-z0-9._-]+$' \
        || ! -d "$OUTPUT_LOCK_DIR" \
        || -L "$OUTPUT_LOCK_DIR" \
        || ! -d "$OUTPUT_LOCK_DIR/$OUTPUT_LOCK_TOKEN" \
        || -L "$OUTPUT_LOCK_DIR/$OUTPUT_LOCK_TOKEN" ]]; then
        echo "Invalid inherited output lock." >&2
        exit 2
    fi
else
    if ! mkdir "$OUTPUT_LOCK_DIR" 2>/dev/null; then
        echo "Another build is using output directory: $OUTPUT_DIR" >&2
        exit 1
    fi
    OWNS_OUTPUT_LOCK=true
fi

SCRATCH_LOCK_DIR=$(mutable_lock_path_for "$SCRATCH_PATH")
SCRATCH_LOCK_TOKEN=${CBR_INTERNAL_SCRATCH_LOCK_TOKEN:-}
if [[ -n "$SCRATCH_LOCK_TOKEN" ]]; then
    if [[ ! "$SCRATCH_LOCK_TOKEN" =~ '^[A-Za-z0-9._-]+$' \
        || ! -d "$SCRATCH_LOCK_DIR" \
        || -L "$SCRATCH_LOCK_DIR" \
        || ! -d "$SCRATCH_LOCK_DIR/$SCRATCH_LOCK_TOKEN" \
        || -L "$SCRATCH_LOCK_DIR/$SCRATCH_LOCK_TOKEN" ]]; then
        echo "Invalid inherited scratch lock." >&2
        exit 2
    fi
else
    if ! mkdir "$SCRATCH_LOCK_DIR" 2>/dev/null; then
        echo "Another build is using build scratch path: $SCRATCH_PATH" >&2
        exit 1
    fi
    OWNS_SCRATCH_LOCK=true
    claim_external_scratch_path "$SCRATCH_PATH" "$ROOT"
fi

assert_locks_held() {
    if [[ -n "$OUTPUT_LOCK_TOKEN" ]]; then
        [[ -d "$OUTPUT_LOCK_DIR" \
            && ! -L "$OUTPUT_LOCK_DIR" \
            && -d "$OUTPUT_LOCK_DIR/$OUTPUT_LOCK_TOKEN" \
            && ! -L "$OUTPUT_LOCK_DIR/$OUTPUT_LOCK_TOKEN" ]] || return 1
    else
        [[ -d "$OUTPUT_LOCK_DIR" && ! -L "$OUTPUT_LOCK_DIR" ]] || return 1
    fi
    if [[ -n "$SCRATCH_LOCK_TOKEN" ]]; then
        [[ -d "$SCRATCH_LOCK_DIR" \
            && ! -L "$SCRATCH_LOCK_DIR" \
            && -d "$SCRATCH_LOCK_DIR/$SCRATCH_LOCK_TOKEN" \
            && ! -L "$SCRATCH_LOCK_DIR/$SCRATCH_LOCK_TOKEN" ]] || return 1
    else
        [[ -d "$SCRATCH_LOCK_DIR" && ! -L "$SCRATCH_LOCK_DIR" ]] || return 1
    fi
    return 0
}

if ! assert_locks_held; then
    echo "Build lock was lost before compilation." >&2
    exit 1
fi

SRC_DIR="$ROOT/Sources/xsComic"
SOURCES=("$SRC_DIR"/*.m(N))
if (( ${#SOURCES[@]} == 0 )); then
    echo "No Objective-C sources found in $SRC_DIR" >&2
    exit 1
fi

BIN_DIR="$SCRATCH_PATH/$CONFIGURATION"
mkdir -p "$BIN_DIR"
BUILT_BIN="$BIN_DIR/ComicBookReader"

CLANG_FLAGS=(
    -arch arm64
    -mmacosx-version-min=14.0
    -fobjc-arc
    -Wall -Wextra
    -I"$SRC_DIR"
)
LINK_FLAGS=(
    -framework AppKit
    -framework CoreGraphics
    -framework ImageIO
    -framework IOSurface
    -framework Metal
    -framework QuartzCore
    -framework Accelerate
    -framework UniformTypeIdentifiers
    -lcompression
    -larchive
    -Wl,-dead_strip
    -Wl,-dead_strip_dylibs
    -Wl,-exported_symbol,_main
    -Wl,-objc_stubs_small
    -Wl,-reproducible
)

if [[ "$CONFIGURATION" == release ]]; then
    CLANG_FLAGS+=(-Oz -flto -fvisibility=hidden -fno-exceptions -fno-objc-exceptions)
else
    CLANG_FLAGS+=(-O0 -g)
fi

xcrun clang "${CLANG_FLAGS[@]}" "${SOURCES[@]}" "${LINK_FLAGS[@]}" -o "$BUILT_BIN"

if ! assert_locks_held; then
    echo "Build lock was lost during compilation." >&2
    exit 1
fi

APP="$OUTPUT_DIR/xsComic.app"
mkdir -p "$OUTPUT_DIR"
BUNDLE_STAGE=$(mktemp -d "$OUTPUT_DIR/.comic-book-reader-stage.XXXXXX")
STAGED_APP="$BUNDLE_STAGE/${APP:t}"
CONTENTS="$STAGED_APP/Contents"
EXECUTABLE="$CONTENTS/MacOS/ComicBookReader"
MODERN_ICON="$ROOT/Assets/Assets.car"
ALTERNATE_ICON="$ROOT/Assets/Brand/xsComic-azusa-app-mark.svg"

# macOS 14+ resolves CFBundleIconName from Assets.car natively; legacy AppIcon.icns
# is omitted to save ~74 KB. The optional alternate Dock icon stays as a 9 KB SVG.
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BUILT_BIN" "$EXECUTABLE"
cp "$MODERN_ICON" "$CONTENTS/Resources/Assets.car"
cp "$ALTERNATE_ICON" "$CONTENTS/Resources/AppIcon-Azusa.svg"

if [[ "$CONFIGURATION" == release ]]; then
    SYMBOL_EXECUTABLE="$OUTPUT_DIR/xsComic.symbols"
    rm -f "$SYMBOL_EXECUTABLE"
    cp "$EXECUTABLE" "$SYMBOL_EXECUTABLE"
    xcrun strip -S -x -N "$EXECUTABLE"
    xcrun dyld_info -validate_only "$EXECUTABLE"
fi

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleDisplayName</key><string>xsComic</string>
    <key>CFBundleExecutable</key><string>ComicBookReader</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>CFBundleName</key><string>xsComic</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Comic Book Archive</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>cb7</string><string>cbr</string><string>cbt</string><string>cbz</string>
                <string>7z</string><string>rar</string><string>tar</string><string>zip</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST
/usr/bin/plutil -convert binary1 "$CONTENTS/Info.plist"

chmod 755 "$STAGED_APP" "$CONTENTS" "$CONTENTS/MacOS" \
    "$CONTENTS/Resources" "$EXECUTABLE"
chmod 644 "$CONTENTS/Info.plist" "$CONTENTS/Resources/"*

if [[ "$SIGN_IDENTITY" == - ]]; then
    codesign --force --sign - "$STAGED_APP"
else
    codesign --force --timestamp --options runtime \
        --sign "$SIGN_IDENTITY" "$STAGED_APP"
fi
if ! assert_locks_held; then
    echo "Build lock was lost during bundle creation." >&2
    exit 1
fi

if [[ -e "$APP" || -L "$APP" ]]; then
    PREVIOUS_APP="$OUTPUT_DIR/.comic-book-reader-previous.$$.$RANDOM"
    mv "$APP" "$PREVIOUS_APP"
fi
if ! mv "$STAGED_APP" "$APP"; then
    echo "Could not publish the completed app bundle." >&2
    exit 1
fi
rmdir "$BUNDLE_STAGE"
BUNDLE_STAGE=""
if [[ -n "$PREVIOUS_APP" ]]; then
    rm -rf "$PREVIOUS_APP"
    PREVIOUS_APP=""
fi

if $ARCHIVE; then
    ZIP_ARCHIVE="$OUTPUT_DIR/xsComic-$VERSION.zip"
    TAR_XZ_ARCHIVE="$OUTPUT_DIR/xsComic-$VERSION.tar.xz"
    ARCHIVE_STAGE=$(mktemp -d "/tmp/comic-reader-package.XXXXXX")
    TAR_LIST="$ARCHIVE_STAGE/files.list"

    rm -f "$ZIP_ARCHIVE" "$TAR_XZ_ARCHIVE"
    /usr/bin/ditto "$APP" "$ARCHIVE_STAGE/${APP:t}"
    cp "$ROOT/LICENSE" "$ARCHIVE_STAGE/LICENSE"
    cp "$ROOT/LICENSING.md" "$ARCHIVE_STAGE/LICENSING.md"
    cp "$ROOT/LICENSES/BRANDING.md" "$ARCHIVE_STAGE/BRANDING.md"
    chmod 644 "$ARCHIVE_STAGE/LICENSE" "$ARCHIVE_STAGE/LICENSING.md" \
        "$ARCHIVE_STAGE/BRANDING.md"
    find "$ARCHIVE_STAGE/${APP:t}" "$ARCHIVE_STAGE/LICENSE" \
        "$ARCHIVE_STAGE/LICENSING.md" "$ARCHIVE_STAGE/BRANDING.md" -exec \
        /usr/bin/touch -h -t 200001010000 {} +
    (
        cd "$ARCHIVE_STAGE"
        MEMBERS=("${APP:t}" LICENSE LICENSING.md BRANDING.md)
        find "${MEMBERS[@]}" \( -type f -o -type l \) -print \
            | LC_ALL=C sort \
            | /usr/bin/zip -9 -X -D -y -q "$ZIP_ARCHIVE" -@
        find "${MEMBERS[@]}" -print0 | LC_ALL=C sort -z > "$TAR_LIST"
        /usr/bin/bsdtar -c -J -n -f "$TAR_XZ_ARCHIVE" \
            --format ustar \
            --options xz:compression-level=9 \
            --uid 0 --gid 0 --uname "" --gname "" \
            --null -T "$TAR_LIST"
    )
    if ! assert_locks_held; then
        echo "Build lock was lost during packaging." >&2
        exit 1
    fi
    rm -rf "$ARCHIVE_STAGE"
    ARCHIVE_STAGE=""
    echo "$ZIP_ARCHIVE"
    echo "$TAR_XZ_ARCHIVE"
fi

echo "$APP"
cleanup_build
trap - EXIT
