#!/bin/sh
set -eu

# Build (if missing) the xscomic-objc3:dev Docker image and run commands inside
# it with the repository root bind-mounted at /work.

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)
IMAGE="${XSCOMIC_DOCKER_IMAGE:-xscomic-objc3:dev}"
DOCKERFILE="$REPO_ROOT/docker/Dockerfile"

usage() {
    cat <<EOF
Usage: $(basename -- "$0") [--build] [--] [command [args...]]

Options:
  --build     (Re)build ${IMAGE} from docker/Dockerfile before running.
              If no command is given, exits after building.
  -h, --help  Show this help message.

Environment:
  XSCOMIC_DOCKER_IMAGE  Override Docker image tag (default: xscomic-objc3:dev)

Examples:
  ./scripts/docker-env.sh --build
  ./scripts/docker-env.sh objc3c --version
  ./scripts/docker-env.sh sh -c 'xvfb-run -a glxinfo -B'
  ./scripts/docker-env.sh   # interactive shell in /work
EOF
}

FORCE_BUILD=0
while [ $# -gt 0 ]; do
    case "$1" in
        --build)
            FORCE_BUILD=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        *)
            break
            ;;
    esac
done

build_image() {
    docker build \
        -f "$DOCKERFILE" \
        -t "$IMAGE" \
        "$REPO_ROOT/docker"
}

if [ "$FORCE_BUILD" -eq 1 ]; then
    build_image
    if [ $# -eq 0 ]; then
        exit 0
    fi
elif ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    build_image
fi

TTY_FLAGS=""
if [ -t 0 ] && [ -t 1 ]; then
    TTY_FLAGS="-it"
fi

if [ $# -eq 0 ]; then
    # shellcheck disable=SC2086
    exec docker run --rm --init $TTY_FLAGS \
        -v "$REPO_ROOT:/work" \
        -w /work \
        "$IMAGE" \
        bash -l
fi

# shellcheck disable=SC2086
exec docker run --rm --init $TTY_FLAGS \
    -v "$REPO_ROOT:/work" \
    -w /work \
    "$IMAGE" \
    "$@"
