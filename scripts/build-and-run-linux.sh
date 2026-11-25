#!/usr/bin/env bash
set -euo pipefail

# Build and launch xsComic for Linux (Objective-C 3.0 + SDL2 + OpenGL 3.3 Core).
# Supports both interactive desktop launches (X11/Wayland) and headless
# --screenshot runs (automatically wrapped with xvfb-run when no display exists).
# On hosts without native objc3c (e.g. macOS), delegates via scripts/docker-env.sh.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd -P)

usage() {
    cat <<EOF
Usage: $(basename "$0") [--release|--debug] [--] [xscomic args...]

Build options:
  --release          Build optimized, stripped release binary (default).
  --debug            Build debug binary with symbols.
  -h, --help         Show this help message.

xsComic runtime args (forwarded to xscomic):
  --single|--double  Start in single-page or two-page spread mode
  --ltr|--rtl        Start in LTR or RTL reading direction
  --sidebar          Open page sidebar on launch
  --page N           Jump to 1-based page N
  --zoom SCALE       Start at custom zoom scale
  --jump-modal       Open the Jump-to-Page modal
  --settings         Open the Settings popover
  --screenshot PATH  Render a frame, save PNG to PATH, and exit
  [book_path]        Optional archive (.cbz/.cbr/.cb7/.cbt) or image directory

Environment:
  CBR_SCRATCH_PATH          Object/build scratch dir (default: build/objc3)
  CBR_OUTPUT_DIR            Output directory for xscomic binary (default: build/linux)
  XSCOMIC_USE_XVFB=1        Force launching under xvfb-run with software GL
  XSCOMIC_DOCKER_IMAGE      Override Docker image tag (default: xscomic-objc3:dev)
EOF
}

BUILD_CONFIG="release"
APP_ARGS=()
HAS_SCREENSHOT=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --release)
            BUILD_CONFIG="release"
            shift
            ;;
        --debug)
            BUILD_CONFIG="debug"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            while [[ $# -gt 0 ]]; do
                if [[ "$1" == "--screenshot" || "$1" == --screenshot=* ]]; then
                    HAS_SCREENSHOT=true
                fi
                APP_ARGS+=("$1")
                shift
            done
            break
            ;;
        *)
            while [[ $# -gt 0 ]]; do
                if [[ "$1" == "--screenshot" || "$1" == --screenshot=* ]]; then
                    HAS_SCREENSHOT=true
                fi
                APP_ARGS+=("$1")
                shift
            done
            break
            ;;
    esac
done

is_native_objc3_linux() {
    [[ "$(uname -s)" == "Linux" ]] && {
        command -v objc3c >/dev/null 2>&1 || [[ -f /opt/objc3c/activate.sh ]]
    }
}

rewrite_repo_path_for_docker() {
    local arg="$1"
    if [[ "$arg" == "$ROOT" ]]; then
        printf '/work\n'
    elif [[ "$arg" == "$ROOT/"* ]]; then
        printf '/work/%s\n' "${arg#"$ROOT/"}"
    elif [[ "$arg" == --screenshot="$ROOT/"* ]]; then
        printf '--screenshot=/work/%s\n' "${arg#--screenshot="$ROOT/"}"
    else
        printf '%s\n' "$arg"
    fi
}

if ! is_native_objc3_linux; then
    if [[ -n "${XSCOMIC_DOCKER_DELEGATED:-}" ]]; then
        echo "Error: objc3c toolchain not found inside container." >&2
        exit 1
    fi

    DOCKER_ARGS=()
    for a in ${APP_ARGS[@]+"${APP_ARGS[@]}"}; do
        DOCKER_ARGS+=("$(rewrite_repo_path_for_docker "$a")")
    done

    # Interactive X11/Wayland passthrough on a Linux host without native objc3c.
    if [[ "$(uname -s)" == "Linux" && "$HAS_SCREENSHOT" == false && "${XSCOMIC_USE_XVFB:-0}" != "1" \
          && ( -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ) ]]; then
        "$ROOT/scripts/build-linux.sh" "--$BUILD_CONFIG"
        IMAGE="${XSCOMIC_DOCKER_IMAGE:-xscomic-objc3:dev}"
        DOCKER_RUN_FLAGS=(--rm --init -v "$ROOT:/work" -w /work)
        if [[ -t 0 && -t 1 ]]; then
            DOCKER_RUN_FLAGS+=(-it)
        fi
        if [[ -n "${DISPLAY:-}" ]]; then
            DOCKER_RUN_FLAGS+=(-e "DISPLAY=$DISPLAY")
            if [[ -d /tmp/.X11-unix ]]; then
                DOCKER_RUN_FLAGS+=(-v /tmp/.X11-unix:/tmp/.X11-unix)
            fi
            if [[ -n "${XAUTHORITY:-}" && -f "$XAUTHORITY" ]]; then
                DOCKER_RUN_FLAGS+=(-e "XAUTHORITY=$XAUTHORITY" -v "$XAUTHORITY:$XAUTHORITY:ro")
            fi
        fi
        if [[ -n "${WAYLAND_DISPLAY:-}" && -n "${XDG_RUNTIME_DIR:-}" \
              && -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]]; then
            DOCKER_RUN_FLAGS+=(
                -e "WAYLAND_DISPLAY=$WAYLAND_DISPLAY"
                -e "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR"
                -v "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY:$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY"
            )
        fi
        if [[ -d /dev/dri ]]; then
            DOCKER_RUN_FLAGS+=(--device /dev/dri:/dev/dri)
        fi
        CONTAINER_OUTPUT_DIR="/work/build/linux"
        if [[ -n "${CBR_OUTPUT_DIR:-}" ]]; then
            if [[ "$CBR_OUTPUT_DIR" != /* ]]; then
                CONTAINER_OUTPUT_DIR="/work/$CBR_OUTPUT_DIR"
            elif [[ "$CBR_OUTPUT_DIR" == "$ROOT/"* ]]; then
                CONTAINER_OUTPUT_DIR="/work/${CBR_OUTPUT_DIR#"$ROOT/"}"
            fi
        fi
        exec docker run "${DOCKER_RUN_FLAGS[@]}" "$IMAGE" \
            "$CONTAINER_OUTPUT_DIR/xscomic" ${DOCKER_ARGS[@]+"${DOCKER_ARGS[@]}"}
    fi

    DOCKER_ENV_ARGS=(XSCOMIC_DOCKER_DELEGATED=1)
    if [[ -n "${XSCOMIC_USE_XVFB:-}" ]]; then
        DOCKER_ENV_ARGS+=("XSCOMIC_USE_XVFB=$XSCOMIC_USE_XVFB")
    fi
    if [[ -n "${LIBGL_ALWAYS_SOFTWARE:-}" ]]; then
        DOCKER_ENV_ARGS+=("LIBGL_ALWAYS_SOFTWARE=$LIBGL_ALWAYS_SOFTWARE")
    fi
    if [[ -n "${XSCOMIC_NO_LTO:-}" ]]; then
        DOCKER_ENV_ARGS+=("XSCOMIC_NO_LTO=$XSCOMIC_NO_LTO")
    fi
    if [[ -n "${CBR_SCRATCH_PATH:-}" ]]; then
        if [[ "$CBR_SCRATCH_PATH" != /* ]]; then
            DOCKER_ENV_ARGS+=("CBR_SCRATCH_PATH=$CBR_SCRATCH_PATH")
        elif [[ "$CBR_SCRATCH_PATH" == "$ROOT/"* ]]; then
            DOCKER_ENV_ARGS+=("CBR_SCRATCH_PATH=${CBR_SCRATCH_PATH#"$ROOT/"}")
        fi
    fi
    if [[ -n "${CBR_OUTPUT_DIR:-}" ]]; then
        if [[ "$CBR_OUTPUT_DIR" != /* ]]; then
            DOCKER_ENV_ARGS+=("CBR_OUTPUT_DIR=$CBR_OUTPUT_DIR")
        elif [[ "$CBR_OUTPUT_DIR" == "$ROOT/"* ]]; then
            DOCKER_ENV_ARGS+=("CBR_OUTPUT_DIR=${CBR_OUTPUT_DIR#"$ROOT/"}")
        fi
    fi
    exec "$ROOT/scripts/docker-env.sh" \
        env "${DOCKER_ENV_ARGS[@]}" \
        bash /work/scripts/build-and-run-linux.sh "--$BUILD_CONFIG" -- ${DOCKER_ARGS[@]+"${DOCKER_ARGS[@]}"}
fi

"$ROOT/scripts/build-linux.sh" "--$BUILD_CONFIG"

OUTPUT_DIR="${CBR_OUTPUT_DIR:-$ROOT/build/linux}"
if [[ "$OUTPUT_DIR" != /* ]]; then
    OUTPUT_DIR="$ROOT/$OUTPUT_DIR"
fi
BIN="$OUTPUT_DIR/xscomic"

if [[ ! -x "$BIN" ]]; then
    echo "Error: built executable not found at $BIN" >&2
    exit 1
fi

USE_XVFB=false
if [[ "${XSCOMIC_USE_XVFB:-0}" == "1" ]]; then
    USE_XVFB=true
elif [[ "$HAS_SCREENSHOT" == true && -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
    USE_XVFB=true
fi

if [[ "$USE_XVFB" == true ]]; then
    if ! command -v xvfb-run >/dev/null 2>&1; then
        echo "Error: headless launch requested, but xvfb-run is not installed." >&2
        exit 1
    fi
    export LIBGL_ALWAYS_SOFTWARE="${LIBGL_ALWAYS_SOFTWARE:-1}"
    xvfb-run -a -s "-screen 0 1280x800x24" \
        "$BIN" ${APP_ARGS[@]+"${APP_ARGS[@]}"}
    exit $?
fi

if [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
    echo "Error: neither DISPLAY nor WAYLAND_DISPLAY is set." >&2
    echo "Run interactively on a Linux X11/Wayland session, set XSCOMIC_USE_XVFB=1, or pass --screenshot <out.png>." >&2
    exit 1
fi

exec "$BIN" ${APP_ARGS[@]+"${APP_ARGS[@]}"}
