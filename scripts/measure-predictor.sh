#!/bin/zsh
set -euo pipefail

# The adaptive prefetcher was allowed a strict 15 KiB binary budget.  This
# experiment builds the same immutable source twice—once normally and once with
# `CBR_STATIC_PREFETCH`—then compares stripped Mach-O and __text sizes.
#
# It is deliberately separate from measure.sh: ordinary performance metrics
# should not double compilation time, while this question is about code cost,
# not wall-clock behavior.
ROOT=${0:A:h:h}
CHILD_MODE=false
if [[ ${1:-} == --snapshot-child ]]; then
    CHILD_MODE=true
    shift
fi
if (( $# != 0 )); then
    echo "usage: $0" >&2
    exit 2
fi

measurement_lock_path_for() {
    local resource=${1:A}
    local key
    key=$(print -rn -- "$resource" | shasum -a 256 | awk '{print $1}')
    print -r -- "/tmp/comic-book-reader-measure-lock.$key"
}

if ! $CHILD_MODE; then
    # Parent mode is an integrity envelope.  It snapshots every hashed input,
    # makes that snapshot read-only, and delegates the actual experiment to it.
    # Thus neither an editor save nor a generated file can produce a hybrid
    # "static from revision A, adaptive from revision B" result.
    LIVE_ROOT="$ROOT"
    SNAPSHOT_PARENT=""
    SNAPSHOT_ROOT=""
    REPO_LOCK_DIR=""
    OWNS_REPO_LOCK=false
    cleanup_source_snapshot() {
        if [[ -n "$SNAPSHOT_ROOT" && -d "$SNAPSHOT_ROOT" ]]; then
            chmod -R u+w "$SNAPSHOT_ROOT"
        fi
        if [[ -n "$SNAPSHOT_PARENT" ]]; then
            rm -rf "$SNAPSHOT_PARENT"
        fi
        if $OWNS_REPO_LOCK; then
            rmdir "$REPO_LOCK_DIR" 2>/dev/null || true
        fi
    }
    trap cleanup_source_snapshot EXIT

    REPO_LOCK_DIR=$(measurement_lock_path_for "$LIVE_ROOT")
    if ! mkdir "$REPO_LOCK_DIR" 2>/dev/null; then
        echo "Another measurement is already running for $LIVE_ROOT." >&2
        echo "If no run is active, remove stale lock: $REPO_LOCK_DIR" >&2
        exit 1
    fi
    OWNS_REPO_LOCK=true

    START_SHA=$(/bin/zsh "$LIVE_ROOT/scripts/source-digest.sh" "$LIVE_ROOT")
    SNAPSHOT_PARENT=$(mktemp -d \
        "/tmp/comic-reader-predictor-source.XXXXXX")
    SNAPSHOT_ROOT="$SNAPSHOT_PARENT/source"

    mkdir -p "$SNAPSHOT_ROOT"
    /usr/bin/ditto "$LIVE_ROOT/Package.swift" "$SNAPSHOT_ROOT/Package.swift"
    /usr/bin/ditto "$LIVE_ROOT/VERSION" "$SNAPSHOT_ROOT/VERSION"
    if [[ -f "$LIVE_ROOT/Package.resolved" ]]; then
        /usr/bin/ditto "$LIVE_ROOT/Package.resolved" \
            "$SNAPSHOT_ROOT/Package.resolved"
    fi
    /usr/bin/ditto "$LIVE_ROOT/Sources" "$SNAPSHOT_ROOT/Sources"
    /usr/bin/ditto "$LIVE_ROOT/Tests" "$SNAPSHOT_ROOT/Tests"
    /usr/bin/ditto "$LIVE_ROOT/scripts" "$SNAPSHOT_ROOT/scripts"
    /usr/bin/ditto "$LIVE_ROOT/Assets" "$SNAPSHOT_ROOT/Assets"

    SNAPSHOT_SHA=$(/bin/zsh "$SNAPSHOT_ROOT/scripts/source-digest.sh" \
        "$SNAPSHOT_ROOT")
    LIVE_AFTER_COPY=$(/bin/zsh "$SNAPSHOT_ROOT/scripts/source-digest.sh" \
        "$LIVE_ROOT")
    if [[ "$SNAPSHOT_SHA" != "$START_SHA" \
        || "$LIVE_AFTER_COPY" != "$START_SHA" ]]; then
        echo "Source changed while creating the predictor snapshot." >&2
        exit 1
    fi
    chmod -R a-w "$SNAPSHOT_ROOT"

    CBR_INTERNAL_LIVE_ROOT="$LIVE_ROOT" \
    CBR_INTERNAL_EXPECTED_SOURCE_SHA="$START_SHA" \
        /bin/zsh "$SNAPSHOT_ROOT/scripts/measure-predictor.sh" \
        --snapshot-child

    LIVE_AFTER_RUN=$(/bin/zsh "$SNAPSHOT_ROOT/scripts/source-digest.sh" \
        "$LIVE_ROOT")
    if [[ "$LIVE_AFTER_RUN" != "$START_SHA" ]]; then
        echo "Live source changed during predictor measurement." >&2
        exit 1
    fi
    cleanup_source_snapshot
    trap - EXIT
    exit
fi

for required_variable in \
    CBR_INTERNAL_LIVE_ROOT \
    CBR_INTERNAL_EXPECTED_SOURCE_SHA
do
    if [[ -z "${(P)required_variable:-}" ]]; then
        echo "Incomplete private snapshot-child invocation: $required_variable is required." >&2
        exit 2
    fi
done
LIVE_ROOT=${CBR_INTERNAL_LIVE_ROOT:A}
if [[ "${ROOT:A}" == "$LIVE_ROOT" ]]; then
    echo "Snapshot-child mode requires an isolated source snapshot." >&2
    exit 2
fi

WORK_ROOT=$(mktemp -d "/tmp/comic-reader-predictor.XXXXXX")
trap 'rm -rf "$WORK_ROOT"' EXIT

# Child mode is intentionally suspicious of both trees: the snapshot must stay
# fixed while the live tree must still match the digest the parent observed.
source_sha() {
    /bin/zsh "$ROOT/scripts/source-digest.sh" "$ROOT"
}

assert_source_unchanged() {
    local stage=$1
    local current_sha
    current_sha=$(source_sha)
    if [[ "$current_sha" != "$SOURCE_SHA" ]]; then
        echo "Source changed during predictor measurement ($stage); refusing mixed-revision results." >&2
        echo "started: $SOURCE_SHA" >&2
        echo "current: $current_sha" >&2
        exit 1
    fi
    local live_sha
    live_sha=$(/bin/zsh "$ROOT/scripts/source-digest.sh" \
        "$LIVE_ROOT")
    if [[ "$live_sha" != "$SOURCE_SHA" ]]; then
        echo "Live source changed during predictor measurement ($stage)." >&2
        exit 1
    fi
}

build_variant() {
    local name=$1
    shift
    local scratch="$WORK_ROOT/$name-build"
    # Give each variant a fresh scratch tree so conditional-compilation products
    # cannot leak across builds.  Strip both exactly as the app bundle does.
    swift build --package-path "$ROOT" -c release -debug-info-format none \
        --scratch-path "$scratch" "$@" >&2
    local bin_dir
    bin_dir=$(swift build --package-path "$ROOT" -c release \
        -debug-info-format none --scratch-path "$scratch" "$@" --show-bin-path)
    cp "$bin_dir/ComicBookReader" "$WORK_ROOT/$name"
    xcrun strip -S -x -N "$WORK_ROOT/$name"
    xcrun dyld_info -validate_only "$WORK_ROOT/$name" >&2
    assert_source_unchanged "$name build"
}

cd "$ROOT"
SOURCE_SHA=$(source_sha)
if [[ "$SOURCE_SHA" != "$CBR_INTERNAL_EXPECTED_SOURCE_SHA" ]]; then
    echo "Predictor snapshot does not match the expected source digest." >&2
    exit 1
fi
build_variant adaptive
assert_source_unchanged "before static build"
build_variant static -Xswiftc -DCBR_STATIC_PREFETCH

# File size catches all shipped bytes; __text isolates executable instructions.
# Reporting both prevents a change in metadata alignment from masquerading as
# predictor logic.
ADAPTIVE_BYTES=$(stat -f %z "$WORK_ROOT/adaptive")
STATIC_BYTES=$(stat -f %z "$WORK_ROOT/static")
ADAPTIVE_TEXT=$(size -m "$WORK_ROOT/adaptive" | awk '/Section __text:/{print $3}')
STATIC_TEXT=$(size -m "$WORK_ROOT/static" | awk '/Section __text:/{print $3}')
FILE_DELTA=$((ADAPTIVE_BYTES - STATIC_BYTES))
TEXT_DELTA=$((ADAPTIVE_TEXT - STATIC_TEXT))

assert_source_unchanged "size capture"
print "CBR_METRIC predictor_size source_sha=$SOURCE_SHA static_bytes=$STATIC_BYTES adaptive_bytes=$ADAPTIVE_BYTES file_delta=$FILE_DELTA static_text_bytes=$STATIC_TEXT adaptive_text_bytes=$ADAPTIVE_TEXT text_delta=$TEXT_DELTA"

# This is the user's original hard ceiling, not a statistical threshold.
if (( FILE_DELTA > 15_360 )); then
    echo "Predictor exceeds the 15 KiB binary budget." >&2
    exit 1
fi
