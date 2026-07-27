#!/bin/zsh
set -euo pipefail

# Turn one already-built release app into the familiar macOS installation
# window: app on the left, /Applications on the right, legal notices below.
# The writable image exists only long enough for Finder to write .DS_Store;
# the published image is read-only LZFSE, the compact native macOS format.
ROOT=${0:A:h:h}
VERSION=$(<"$ROOT/VERSION")
case ${1:-} in
    x86_64)
        PRODUCT="$ROOT/build/product"
        VOLUME="xsComic $VERSION — Intel"
        ;;
    arm64)
        PRODUCT="$ROOT/build/product-arm64"
        VOLUME="xsComic $VERSION — Apple Silicon"
        ;;
    *)
        echo "usage: $0 <x86_64|arm64>" >&2
        exit 2
        ;;
esac
ARCHITECTURE=$1
APP="$PRODUCT/xsComic.app"
BINARY="$APP/Contents/MacOS/ComicBookReader"
OUTPUT="$PRODUCT/xsComic-$VERSION-$ARCHITECTURE.dmg"
BACKGROUND="$ROOT/Assets/Brand/xsComic-dmg-background.jpg"
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
    echo "App architecture does not match requested DMG: $BINARY" >&2
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
cp "$ROOT/Assets/AppIcon.icns" "$STAGE/.VolumeIcon.icns"
chmod 644 "$STAGE/.background/background.jpg" "$STAGE/Licenses/"* \
    "$STAGE/.VolumeIcon.icns"

hdiutil create -quiet -fs HFS+ -format UDRW -volname "$VOLUME" \
    -srcfolder "$STAGE" "$WRITABLE"
hdiutil attach -quiet -readwrite -noverify -noautoopen \
    -mountpoint "$MOUNT" "$WRITABLE"
MOUNTED=true
/usr/bin/SetFile -a C "$MOUNT"
osascript "$ROOT/scripts/layout-dmg.applescript" "$MOUNT"
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
