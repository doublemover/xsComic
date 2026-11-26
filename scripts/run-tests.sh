#!/bin/zsh
set -euo pipefail

# Compile and run the standalone arm64 Objective-C test & benchmark suite.
ROOT=${0:A:h:h}
cd "$ROOT"

SRC_DIR="$ROOT/Sources/xsComic"
TEST_SRC="$ROOT/Tests/xsComicTests/main.m"
OUT_DIR="$ROOT/build/tests"
OUT_BIN="$OUT_DIR/xsComicTests"
SANITIZER_FLAGS=()
case ${XSCOMIC_TEST_SANITIZER:-} in
    "") ;;
    address)
        OUT_BIN="$OUT_DIR/xsComicTests-address"
        SANITIZER_FLAGS=(-fsanitize=address,undefined -fno-omit-frame-pointer -g)
        export UBSAN_OPTIONS="${UBSAN_OPTIONS:-halt_on_error=1}"
        ;;
    thread)
        OUT_BIN="$OUT_DIR/xsComicTests-thread"
        SANITIZER_FLAGS=(-fsanitize=thread -fno-omit-frame-pointer -g)
        export TSAN_OPTIONS="${TSAN_OPTIONS:-halt_on_error=1}"
        ;;
    *)
        echo 'XSCOMIC_TEST_SANITIZER must be address or thread.' >&2
        exit 2
        ;;
esac

mkdir -p "$OUT_DIR"

xcrun clang \
    -arch arm64 \
    -mmacosx-version-min=14.0 \
    -fobjc-arc \
    -O2 \
    -Wall -Wextra \
    "${SANITIZER_FLAGS[@]}" \
    -I"$SRC_DIR" \
    "$TEST_SRC" \
    "$SRC_DIR/XSCArchive.m" \
    "$SRC_DIR/XSCImageStore.m" \
    "$SRC_DIR/XSCReaderModel.m" \
    -framework Foundation \
    -framework AppKit \
    -framework CoreGraphics \
    -framework ImageIO \
    -framework IOSurface \
    -framework UniformTypeIdentifiers \
    -framework Accelerate \
    -lcompression \
    -larchive \
    -o "$OUT_BIN"

exec "$OUT_BIN" "$@"
