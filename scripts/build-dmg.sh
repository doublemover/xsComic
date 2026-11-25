#!/bin/zsh
set -euo pipefail

# Turn one already-built arm64 release app into the familiar macOS installation
# window: app on the left, /Applications on the right, legal notices below.
# The writable image exists only long enough for Finder to write .DS_Store;
# the published image is read-only LZFSE, the compact native macOS format.
ROOT=${0:A:h:h}
VERSION=$(<"$ROOT/VERSION")
ARCHITECTURE=${1:-arm64}
case "$ARCHITECTURE" in
    arm64)
        PRODUCT=${CBR_OUTPUT_DIR:-"$ROOT/build/product"}
        PRODUCT=${PRODUCT:A}
        VOLUME="xsComic $VERSION"
        ;;
    *)
        echo "usage: $0 [arm64]" >&2
        echo "xsComic 2.0+ ships for Apple Silicon (arm64) only." >&2
        exit 2
        ;;
esac

APP="$PRODUCT/xsComic.app"
BINARY="$APP/Contents/MacOS/ComicBookReader"
OUTPUT="$PRODUCT/xsComic-$VERSION-$ARCHITECTURE.dmg"
BACKGROUND="$ROOT/Assets/Brand/xsComic-dmg-background.jpg"
VOLUME_ICON="$ROOT/Assets/AppIcon.icns"
SIGN_IDENTITY=${CBR_SIGN_IDENTITY:--}

for required in "$APP" "$BINARY" "$BACKGROUND" "$ROOT/LICENSE" \
    "$ROOT/LICENSING.md" "$ROOT/LICENSES/BRANDING.md"
do
    if [[ ! -e "$required" ]]; then
        echo "Required DMG input is missing: $required" >&2
        exit 1
    fi
done
if [[ "$(lipo -archs "$BINARY")" != "$ARCHITECTURE" ]]; then
    echo "App architecture does not match requested DMG ($ARCHITECTURE): $BINARY" >&2
    exit 1
fi
codesign --verify --strict "$APP"

WORK=$(mktemp -d "/tmp/xscomic-dmg.XXXXXX")
STAGE="$WORK/stage"
MOUNT="$WORK/mount"
WRITABLE="$WORK/writable.dmg"
MOUNTED=false
cleanup() {
    if $MOUNTED; then
        hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

mkdir -p "$STAGE/.background" "$STAGE/Licenses" "$MOUNT"
/usr/bin/ditto "$APP" "$STAGE/xsComic.app"
ln -s /Applications "$STAGE/Applications"
cp "$BACKGROUND" "$STAGE/.background/background.jpg"
cp "$ROOT/LICENSE" "$STAGE/Licenses/AGPL-3.0.txt"
cp "$ROOT/LICENSING.md" "$STAGE/Licenses/LICENSING.md"
cp "$ROOT/LICENSES/BRANDING.md" "$STAGE/Licenses/BRANDING.md"
chmod 644 "$STAGE/.background/background.jpg" "$STAGE/Licenses/"*
if [[ -f "$VOLUME_ICON" ]]; then
    cp "$VOLUME_ICON" "$STAGE/.VolumeIcon.icns"
    chmod 644 "$STAGE/.VolumeIcon.icns"
fi

hdiutil create -quiet -fs HFS+ -format UDRW -volname "$VOLUME" \
    -srcfolder "$STAGE" "$WRITABLE"
hdiutil attach -quiet -readwrite -noverify -noautoopen \
    -mountpoint "$MOUNT" "$WRITABLE"
MOUNTED=true
if [[ -f "$VOLUME_ICON" ]]; then
    /usr/bin/SetFile -a C "$MOUNT"
fi
osascript "$ROOT/scripts/layout-dmg.applescript" "$MOUNT"

# Finder has finished writing the one metadata file we want: .DS_Store. Remove
# transient services' volume-local state before freezing the image. These names
# are created by macOS itself, never by release source, and encode no layout.
rm -rf "$MOUNT/.fseventsd" "$MOUNT/.Spotlight-V100" \
    "$MOUNT/.TemporaryItems" "$MOUNT/.Trashes"
sync
hdiutil detach "$MOUNT" -quiet
MOUNTED=false

rm -f "$OUTPUT"
hdiutil convert -quiet "$WRITABLE" -format ULFO -o "$OUTPUT"
if [[ "$SIGN_IDENTITY" != - ]]; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$OUTPUT"
fi
hdiutil verify "$OUTPUT" >/dev/null
echo "$OUTPUT"
