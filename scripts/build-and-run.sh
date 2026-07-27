#!/bin/zsh
set -euo pipefail

# This is the deliberately thin human-facing wrapper around build-app.sh.
# Keeping launch, logging, and LLDB policy here lets the packaging script remain
# deterministic and usable by the measurement harness.
MODE=${1:-run}
APP_NAME="ComicBookReader"
BUNDLE_ID=${CBR_BUNDLE_ID:-com.xscomic.app}
ROOT=${0:A:h:h}
OUTPUT_DIR=${CBR_OUTPUT_DIR:-"$ROOT/build/product"}
if [[ "$OUTPUT_DIR" != /* ]]; then
    OUTPUT_DIR="$ROOT/$OUTPUT_DIR"
fi
OUTPUT_DIR=${OUTPUT_DIR:A}
APP="$OUTPUT_DIR/xsComic.app"
EXECUTABLE="$APP/Contents/MacOS/$APP_NAME"

case "$MODE" in
    run|--logs|logs|--telemetry|telemetry|--verify|verify)
        BUILD_MODE=release
        ;;
    --debug|debug)
        BUILD_MODE=debug
        ;;
    *)
        echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
        exit 2
        ;;
esac

# Query the command column rather than the process name: another installed build
# may use the same executable basename. The supported output override must build,
# stop, launch, log, and debug one coherent product.
build_pids() {
    ps -axo pid=,command= | awk -v executable="$EXECUTABLE" '
        {
            pid = $1
            sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "")
            if ($0 == executable || index($0, executable " ") == 1) print pid
        }
    '
}

for pid in ${(f)"$(build_pids)"}; do
    [[ -n "$pid" ]] && kill "$pid" >/dev/null 2>&1 || true
done
if [[ "$BUILD_MODE" == debug ]]; then
    "$ROOT/scripts/build-app.sh" --debug
else
    "$ROOT/scripts/build-app.sh"
fi

open_app() {
    # `-n` is intentional: after the exact-name kill above, it makes this build
    # the process macOS launches instead of reusing another registered bundle.
    /usr/bin/open -n "$APP"
}

case "$MODE" in
    run)
        open_app
        ;;
    --debug|debug)
        lldb -- "$EXECUTABLE"
        ;;
    --logs|logs)
        open_app
        /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
        ;;
    --telemetry|telemetry)
        open_app
        /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
        ;;
    --verify|verify)
        open_app
        # Thirty short probes allow LaunchServices time on a cold machine. Once
        # found, the exact built process must survive another second: observing
        # one transient PID is not evidence that application startup completed.
        launched_pid=""
        for _ in {1..30}; do
            launched_pid=$(build_pids | sed -n '1p')
            [[ -n "$launched_pid" ]] && break
            sleep 0.1
        done
        if [[ -n "$launched_pid" ]]; then
            for _ in {1..10}; do
                sleep 0.1
                build_pids | grep -qx "$launched_pid" || {
                    echo "$APP_NAME exited during launch verification." >&2
                    exit 1
                }
            done
            exit 0
        fi
        echo "$APP_NAME did not remain running after launch." >&2
        exit 1
        ;;
esac
