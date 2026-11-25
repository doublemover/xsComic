#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
    echo "The Objective-C 3 macOS suite requires native Apple Silicon." >&2
    exit 2
fi
SDK=$(cd "${XSCOMIC_OBJC3_SDK:?Set XSCOMIC_OBJC3_SDK to the installed Darwin SDK prefix.}" && pwd -P)
MANIFEST="$SDK/objc3-sdk.json"
SDKROOT=$(xcrun --sdk macosx --show-sdk-path)
APPLE_LINKER=$(xcrun --sdk macosx --find ld)
RESOURCE_DIR=$(python3 - "$MANIFEST" "$(xcrun --sdk macosx --show-sdk-version)" <<'PY'
import json
import re
import sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text())
resource = manifest['resource_dir']
if (manifest['target'] != 'arm64-apple-macos15.0' or
        manifest['runtime_abi'] != 'objc3-darwin-registration-v1' or
        manifest['host_requirements']['sdk_version'] != sys.argv[2] or
        not re.fullmatch(r'lib/clang/[1-9][0-9]*', resource)):
    raise SystemExit('The installed Objective-C 3 compiler requires a matching Apple SDK and runtime.')
print(resource)
PY
)

BREW_FORMULAE=(libarchive jpeg-turbo libpng webp libtiff libavif libheif)
for formula in "${BREW_FORMULAE[@]}"; do
    pc="$(brew --prefix "$formula")/lib/pkgconfig"
    PKG_CONFIG_PATH="$pc${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
done
export PKG_CONFIG_PATH
CODECS=(libarchive libjpeg libpng libwebp libtiff-4 libavif libheif)
CODEC_CFLAGS=$(pkg-config --cflags "${CODECS[@]}")
CODEC_LIBS=$(pkg-config --libs "${CODECS[@]}")
GIF_PREFIX=$(brew --prefix giflib)

SOURCE="$ROOT/Sources/xsComicLinux"
OUT="$ROOT/build/objc3-macos-tests"
mkdir -p "$OUT"
CLANG="$SDK/bin/clang"
RUNTIME="$SDK/lib/libobjc3darwin.dylib"
FLAGS=(--no-default-config --target=arm64-apple-macos15.0 -isysroot "$SDKROOT"
       -resource-dir "$SDK/$RESOURCE_DIR")
OBJC=(-x objective-c -std=c17 -D_DARWIN_C_SOURCE -fobjc-version=3 -fobjc-runtime=gnustep-2.99
      -fobjc-arc -fblocks -O2 -Wall -Wextra -Werror
      -I"$SOURCE" -I"$SDK/include" -I"$GIF_PREFIX/include")
SRC_FILES=("$ROOT/Tests/xsComicLinuxTests/main.objc3"
           "$SOURCE/XSCBase.objc3" "$SOURCE/XSCArchive.objc3"
           "$SOURCE/XSCImageStore.objc3" "$SOURCE/XSCReaderModel.objc3")
OBJECTS=()
PIDS=()
for unit in "${SRC_FILES[@]}"; do
    base=$(basename "$unit" .objc3)
    obj="$OUT/$base.o"
    # pkg-config supplies the compiler's list of switches.
    # shellcheck disable=SC2086
    "$CLANG" "${FLAGS[@]}" "${OBJC[@]}" $CODEC_CFLAGS -c "$unit" -o "$obj" >"$OUT/$base.log" 2>&1 &
    PIDS+=("$!")
    OBJECTS+=("$obj")
done
ready=true
for pid in "${PIDS[@]}"; do
    if ! wait "$pid"; then ready=false; fi
done
cat "$OUT"/{main,XSCBase,XSCArchive,XSCImageStore,XSCReaderModel}.log
if [[ "$ready" != true ]]; then exit 1; fi

BIN="$OUT/xsComicObjC3Tests"
# shellcheck disable=SC2086
"$CLANG" "${FLAGS[@]}" "--ld-path=$APPLE_LINKER" "${OBJECTS[@]}" "$RUNTIME" \
    -Xlinker -rpath -Xlinker "$SDK/lib" $CODEC_LIBS -L"$GIF_PREFIX/lib" -lgif -lz -o "$BIN"
test "$(lipo -archs "$BIN")" = arm64
otool -L "$BIN" | tee "$OUT/load-paths.txt"
if grep -Eq '/libobjc(\.[[:alnum:]]+)?\.dylib' "$OUT/load-paths.txt"; then
    echo "The executable linked the system Objective-C runtime." >&2
    exit 1
fi
cp "$MANIFEST" "$OUT/sdk.json"
"$CLANG" --no-default-config --version | tee "$OUT/compiler.txt"
DYLD_PRINT_LIBRARIES=1 "$BIN" "$@" 2>"$OUT/dyld.log" | tee "$OUT/results.txt"
python3 - "$RUNTIME" "$OUT/dyld.log" <<'PY'
import re
import sys
from pathlib import Path

runtime = Path(sys.argv[1]).resolve(strict=True)
libraries = []
for line in Path(sys.argv[2]).read_text().splitlines():
    entry = re.fullmatch(r'dyld\[\d+\]:\s+(?:<[^>]+>\s+)?(/.+)', line)
    if entry and Path(entry[1]).name == runtime.name:
        libraries.append(Path(entry[1]).resolve(strict=True))
if libraries != [runtime]:
    raise SystemExit('The Objective-C 3 suite did not load the installed runtime.')
PY
