#!/bin/zsh
set -euo pipefail
zmodload zsh/datetime
export LC_NUMERIC=C

# This file is longer than the application entry point because trustworthy
# measurements require more ceremony than collecting numbers.
#
# The protocol has two processes:
#
#   parent: lock measurement resources -> snapshot inputs -> make copy read-only
#   child:  clean -> build/package -> test -> benchmark -> inspect -> emit JSON
#
# Publication is atomic and occurs only if the snapshot and live tree still
# have the same digest.  A reader can therefore compare any two Metrics/*.json
# files knowing that each describes one coherent source revision.
ROOT=${0:A:h:h}
source "$ROOT/scripts/build-support.sh"
CHILD_MODE=false
if [[ ${1:-} == --snapshot-child ]]; then
    CHILD_MODE=true
    shift
fi
REPLACE=false
if ! $CHILD_MODE && [[ ${1:-} == --replace ]]; then
    REPLACE=true
    shift
fi
LABEL=${1:-latest}
if (( $# > 1 )); then
    echo "usage: $0 [--replace] [label]" >&2
    exit 2
fi
if [[ ! "$LABEL" =~ '^[A-Za-z0-9_-]+$' ]]; then
    echo "Metric label may contain only letters, numbers, underscores, and hyphens." >&2
    exit 2
fi

measurement_lock_path_for() {
    local resource=${1:A}
    local key
    key=$(print -rn -- "$resource" | shasum -a 256 | awk '{print $1}')
    print -r -- "/tmp/comic-book-reader-measure-lock.$key"
}

if ! $CHILD_MODE; then
    # --- Parent: establish the measurement transaction ----------------------
    #
    # Paths may be redirected so a running app is not replaced.  Canonicalize
    # before validation; textual `..` components must not evade containment.
    LIVE_ROOT="$ROOT"
    case ${CBR_OUTPUT_DIR:-} in
        "")
            CBR_OUTPUT_DIR="$LIVE_ROOT/build/metrics-product"
            ;;
        /*)
            ;;
        *)
            CBR_OUTPUT_DIR="$LIVE_ROOT/$CBR_OUTPUT_DIR"
            ;;
    esac
    case ${CBR_SCRATCH_PATH:-} in
        "")
            CBR_SCRATCH_PATH="$LIVE_ROOT/build/swiftpm-metrics"
            ;;
        /*)
            ;;
        *)
            CBR_SCRATCH_PATH="$LIVE_ROOT/$CBR_SCRATCH_PATH"
            ;;
    esac
    CBR_OUTPUT_DIR=${CBR_OUTPUT_DIR:A}
    CBR_SCRATCH_PATH=${CBR_SCRATCH_PATH:A}
    export CBR_OUTPUT_DIR CBR_SCRATCH_PATH
    validate_mutable_path "$CBR_OUTPUT_DIR" "Output directory" "$LIVE_ROOT"
    validate_mutable_path "$CBR_SCRATCH_PATH" "SwiftPM scratch path" "$LIVE_ROOT"
    require_disjoint_paths \
        "$CBR_OUTPUT_DIR" "$CBR_SCRATCH_PATH" \
        "Output directory" "SwiftPM scratch path"

    SNAPSHOT_PARENT=""
    SNAPSHOT_ROOT=""
    METRICS_STAGE=""
    REPO_LOCK_DIR=""
    OUTPUT_LOCK_DIR=""
    OUTPUT_LOCK_TOKEN=""
    SCRATCH_LOCK_DIR=""
    SCRATCH_LOCK_TOKEN=""
    OWNS_REPO_LOCK=false
    OWNS_OUTPUT_LOCK=false
    OWNS_SCRATCH_LOCK=false
    cleanup_snapshot() {
        # Cleanup removes this run's snapshot, staged metrics, and cooperative
        # locks. The child pre-cleans its claimed SwiftPM tree for measurement;
        # the tree and its persistent ownership marker remain afterward.
        if [[ -n "$SNAPSHOT_ROOT" && -d "$SNAPSHOT_ROOT" ]]; then
            chmod -R u+w "$SNAPSHOT_ROOT"
        fi
        if [[ -n "$SNAPSHOT_PARENT" ]]; then
            rm -rf "$SNAPSHOT_PARENT"
        fi
        if [[ -n "$METRICS_STAGE" ]]; then
            rm -f "$METRICS_STAGE"
        fi
        if $OWNS_SCRATCH_LOCK && [[ -n "$SCRATCH_LOCK_TOKEN" ]]; then
            rmdir "$SCRATCH_LOCK_DIR/$SCRATCH_LOCK_TOKEN" 2>/dev/null || true
        fi
        if $OWNS_SCRATCH_LOCK; then
            rmdir "$SCRATCH_LOCK_DIR" 2>/dev/null || true
        fi
        if $OWNS_OUTPUT_LOCK && [[ -n "$OUTPUT_LOCK_TOKEN" ]]; then
            rmdir "$OUTPUT_LOCK_DIR/$OUTPUT_LOCK_TOKEN" 2>/dev/null || true
        fi
        if $OWNS_OUTPUT_LOCK; then
            rmdir "$OUTPUT_LOCK_DIR" 2>/dev/null || true
        fi
        if $OWNS_REPO_LOCK; then
            rmdir "$REPO_LOCK_DIR" 2>/dev/null || true
        fi
    }
    trap cleanup_snapshot EXIT

    REPO_LOCK_DIR=$(measurement_lock_path_for "$LIVE_ROOT")
    if ! mkdir "$REPO_LOCK_DIR" 2>/dev/null; then
        echo "Another measurement is already running for $LIVE_ROOT." >&2
        echo "If no run is active, remove stale lock: $REPO_LOCK_DIR" >&2
        exit 1
    fi
    OWNS_REPO_LOCK=true

    # Three locks cover three different races: another measurement of this
    # source, any writer of this product tree, and any writer of this cache.
    OUTPUT_LOCK_DIR=$(mutable_lock_path_for "$CBR_OUTPUT_DIR")
    if ! mkdir "$OUTPUT_LOCK_DIR" 2>/dev/null; then
        echo "Another build is using output directory: $CBR_OUTPUT_DIR" >&2
        exit 1
    fi
    OWNS_OUTPUT_LOCK=true
    OUTPUT_LOCK_TOKEN="measure.$$.$RANDOM.$RANDOM"
    mkdir "$OUTPUT_LOCK_DIR/$OUTPUT_LOCK_TOKEN"

    SCRATCH_LOCK_DIR=$(mutable_lock_path_for "$CBR_SCRATCH_PATH")
    if ! mkdir "$SCRATCH_LOCK_DIR" 2>/dev/null; then
        echo "Another build is using SwiftPM scratch path: $CBR_SCRATCH_PATH" >&2
        exit 1
    fi
    OWNS_SCRATCH_LOCK=true
    SCRATCH_LOCK_TOKEN="measure.$$.$RANDOM.$RANDOM"
    mkdir "$SCRATCH_LOCK_DIR/$SCRATCH_LOCK_TOKEN"
    if [[ -d "$CBR_SCRATCH_PATH" ]]; then
        CBR_INTERNAL_SCRATCH_EXISTED=true
    else
        CBR_INTERNAL_SCRATCH_EXISTED=false
    fi
    claim_external_scratch_path "$CBR_SCRATCH_PATH" "$LIVE_ROOT"

    # Digest before and after the copy.  Equality on both sides proves that no
    # measured file changed during snapshot construction.
    START_SHA=$(/bin/zsh "$LIVE_ROOT/scripts/source-digest.sh" "$LIVE_ROOT")
    SNAPSHOT_PARENT=$(mktemp -d "/tmp/comic-reader-measure.XXXXXX")
    SNAPSHOT_ROOT="$SNAPSHOT_PARENT/source"
    METRICS_STAGE="$LIVE_ROOT/Metrics/.$LABEL.snapshot.$$"

    mkdir -p "$SNAPSHOT_ROOT" "$LIVE_ROOT/Metrics"
    FINAL_OUTPUT="$LIVE_ROOT/Metrics/$LABEL.json"
    # Named historical results are append-only by default.  `latest` is the one
    # intentionally mutable convenience label; --replace makes exceptions loud.
    if [[ "$LABEL" != latest \
        && ( -e "$FINAL_OUTPUT" || -L "$FINAL_OUTPUT" ) \
        ]] && ! $REPLACE; then
        echo "Metrics already exist: $FINAL_OUTPUT" >&2
        echo "Use --replace only when intentional." >&2
        exit 2
    fi
    /usr/bin/ditto "$LIVE_ROOT/Package.swift" "$SNAPSHOT_ROOT/Package.swift"
    /usr/bin/ditto "$LIVE_ROOT/VERSION" "$SNAPSHOT_ROOT/VERSION"
    /usr/bin/ditto "$LIVE_ROOT/LICENSE" "$SNAPSHOT_ROOT/LICENSE"
    /usr/bin/ditto "$LIVE_ROOT/LICENSING.md" "$SNAPSHOT_ROOT/LICENSING.md"
    mkdir -p "$SNAPSHOT_ROOT/LICENSES"
    /usr/bin/ditto "$LIVE_ROOT/LICENSES/BRANDING.md" \
        "$SNAPSHOT_ROOT/LICENSES/BRANDING.md"
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
        echo "Source changed while creating the measurement snapshot." >&2
        exit 1
    fi
    chmod -R a-w "$SNAPSHOT_ROOT"

    # Private variables are capabilities: they name the live publication root,
    # expected digest, and exact lock tokens.  Child mode refuses direct use
    # without the complete set.
    CBR_INTERNAL_LIVE_ROOT="$LIVE_ROOT" \
    CBR_INTERNAL_EXPECTED_SOURCE_SHA="$START_SHA" \
    CBR_INTERNAL_METRICS_OUTPUT="$METRICS_STAGE" \
    CBR_INTERNAL_OUTPUT_LOCK_TOKEN="$OUTPUT_LOCK_TOKEN" \
    CBR_INTERNAL_SCRATCH_LOCK_TOKEN="$SCRATCH_LOCK_TOKEN" \
    CBR_INTERNAL_SCRATCH_EXISTED="$CBR_INTERNAL_SCRATCH_EXISTED" \
        /bin/zsh "$SNAPSHOT_ROOT/scripts/measure.sh" \
        --snapshot-child "$LABEL"

    LIVE_BEFORE_PUBLISH=$(/bin/zsh \
        "$SNAPSHOT_ROOT/scripts/source-digest.sh" "$LIVE_ROOT")
    if [[ "$LIVE_BEFORE_PUBLISH" != "$START_SHA" ]]; then
        echo "Live source changed during measurement; metrics not published." >&2
        exit 1
    fi
    mv "$METRICS_STAGE" "$FINAL_OUTPUT"
    METRICS_STAGE=""
    cleanup_snapshot
    trap - EXIT
    echo "$FINAL_OUTPUT"
    exit
fi

for required_variable in \
    CBR_INTERNAL_LIVE_ROOT \
    CBR_INTERNAL_EXPECTED_SOURCE_SHA \
    CBR_INTERNAL_METRICS_OUTPUT \
    CBR_INTERNAL_OUTPUT_LOCK_TOKEN \
    CBR_INTERNAL_SCRATCH_LOCK_TOKEN \
    CBR_INTERNAL_SCRATCH_EXISTED \
    CBR_OUTPUT_DIR \
    CBR_SCRATCH_PATH
do
    if [[ -z "${(P)required_variable:-}" ]]; then
        echo "Incomplete private snapshot-child invocation: $required_variable is required." >&2
        exit 2
    fi
done

SCRATCH=${CBR_SCRATCH_PATH:A}
OUTPUT_DIR=${CBR_OUTPUT_DIR:A}
PUBLISH_ROOT=${CBR_INTERNAL_LIVE_ROOT:A}
# --- Child: validate the inherited transaction ------------------------------
validate_mutable_path "$SCRATCH" "SwiftPM scratch path" "$PUBLISH_ROOT"
validate_mutable_path "$OUTPUT_DIR" "Output directory" "$PUBLISH_ROOT"
require_disjoint_paths \
    "$OUTPUT_DIR" "$SCRATCH" \
    "Output directory" "SwiftPM scratch path"
if [[ "${ROOT:A}" == "$PUBLISH_ROOT" ]]; then
    echo "Snapshot-child mode requires an isolated source snapshot." >&2
    exit 2
fi
if [[ "$CBR_INTERNAL_SCRATCH_EXISTED" != true \
    && "$CBR_INTERNAL_SCRATCH_EXISTED" != false ]]; then
    echo "Invalid inherited scratch existence state." >&2
    exit 2
fi
EXPECTED_OUTPUT_LOCK_DIR=$(mutable_lock_path_for "$OUTPUT_DIR")
EXPECTED_SCRATCH_LOCK_DIR=$(mutable_lock_path_for "$SCRATCH")
if [[ ! "$CBR_INTERNAL_OUTPUT_LOCK_TOKEN" =~ '^[A-Za-z0-9._-]+$' \
    || ! -d "$EXPECTED_OUTPUT_LOCK_DIR" \
    || -L "$EXPECTED_OUTPUT_LOCK_DIR" \
    || ! -d "$EXPECTED_OUTPUT_LOCK_DIR/$CBR_INTERNAL_OUTPUT_LOCK_TOKEN" \
    || -L "$EXPECTED_OUTPUT_LOCK_DIR/$CBR_INTERNAL_OUTPUT_LOCK_TOKEN" ]]; then
    echo "Invalid inherited output lock." >&2
    exit 2
fi
if [[ ! "$CBR_INTERNAL_SCRATCH_LOCK_TOKEN" =~ '^[A-Za-z0-9._-]+$' \
    || ! -d "$EXPECTED_SCRATCH_LOCK_DIR" \
    || -L "$EXPECTED_SCRATCH_LOCK_DIR" \
    || ! -d "$EXPECTED_SCRATCH_LOCK_DIR/$CBR_INTERNAL_SCRATCH_LOCK_TOKEN" \
    || -L "$EXPECTED_SCRATCH_LOCK_DIR/$CBR_INTERNAL_SCRATCH_LOCK_TOKEN" ]]; then
    echo "Invalid inherited scratch lock." >&2
    exit 2
fi
export CBR_INTERNAL_OUTPUT_LOCK_TOKEN CBR_INTERNAL_SCRATCH_LOCK_TOKEN
VERSION=$(<"$ROOT/VERSION")
APP="$OUTPUT_DIR/xsComic.app"
BINARY="$APP/Contents/MacOS/ComicBookReader"
SYMBOL_EXECUTABLE="$OUTPUT_DIR/xsComic.symbols"
ARCHIVE="$OUTPUT_DIR/xsComic-$VERSION.zip"
TAR_XZ_ARCHIVE="$OUTPUT_DIR/xsComic-$VERSION.tar.xz"
METRICS_ROOT="$PUBLISH_ROOT/Metrics"
OUTPUT=${CBR_INTERNAL_METRICS_OUTPUT:A}
if [[ "$OUTPUT" != "$METRICS_ROOT"/* ]]; then
    echo "Snapshot-child metrics output must be under Metrics/: $OUTPUT" >&2
    exit 2
fi

assert_locks_held() {
    local stage=$1
    if [[ ! -d "$EXPECTED_OUTPUT_LOCK_DIR" \
        || -L "$EXPECTED_OUTPUT_LOCK_DIR" \
        || ! -d "$EXPECTED_OUTPUT_LOCK_DIR/$CBR_INTERNAL_OUTPUT_LOCK_TOKEN" \
        || -L "$EXPECTED_OUTPUT_LOCK_DIR/$CBR_INTERNAL_OUTPUT_LOCK_TOKEN" \
        || ! -d "$EXPECTED_SCRATCH_LOCK_DIR" \
        || -L "$EXPECTED_SCRATCH_LOCK_DIR" \
        || ! -d "$EXPECTED_SCRATCH_LOCK_DIR/$CBR_INTERNAL_SCRATCH_LOCK_TOKEN" \
        || -L "$EXPECTED_SCRATCH_LOCK_DIR/$CBR_INTERNAL_SCRATCH_LOCK_TOKEN" ]]; then
        echo "Measurement lock was lost during $stage." >&2
        exit 1
    fi
}

source_sha() {
    /bin/zsh "$ROOT/scripts/source-digest.sh" "$ROOT"
}

assert_source_unchanged() {
    # Check both immutable snapshot and live source after every expensive phase.
    # A result is discarded rather than published with a misleading digest.
    local stage=$1
    assert_locks_held "$stage"
    local current_sha
    current_sha=$(source_sha)
    if [[ "$current_sha" != "$SOURCE_SHA" ]]; then
        echo "Source changed during measurement ($stage); refusing mixed-revision metrics." >&2
        echo "started: $SOURCE_SHA" >&2
        echo "current: $current_sha" >&2
        exit 1
    fi
    local live_sha
    live_sha=$(/bin/zsh "$ROOT/scripts/source-digest.sh" \
        "$PUBLISH_ROOT")
    if [[ "$live_sha" != "$SOURCE_SHA" ]]; then
        echo "Live source changed during measurement ($stage)." >&2
        exit 1
    fi
}

metric_line() {
    # Benchmarks emit a compact, intentionally boring wire format:
    # `CBR_METRIC name key=value ...`.  Parsing it here keeps XCTest free of a
    # JSON dependency and makes raw benchmark output useful at the terminal.
    print -r -- "$BENCHMARK_OUTPUT" | grep "CBR_METRIC $1 " | tail -n 1 || true
}

metric_value() {
    local line=$1
    local key=$2
    local field
    for field in ${(z)line}; do
        if [[ "$field" == "$key="* ]]; then
            print -r -- "${field#*=}"
            return
        fi
    done
    print "null"
}

validate_metric_line() {
    local name=$1
    local line=$2
    shift 2
    if [[ -z "$line" ]]; then
        echo "Missing benchmark metric: $name" >&2
        exit 1
    fi

    local key value
    for key in "$@"; do
        value=$(metric_value "$line" "$key")
        if [[ ! "$value" =~ '^[0-9]+([.][0-9]+)?$' ]]; then
            echo "Invalid benchmark metric: $name.$key=$value" >&2
            exit 1
        fi
    done
}

cd "$ROOT"
SOURCE_SHA=$(source_sha)
if [[ "$SOURCE_SHA" != "$CBR_INTERNAL_EXPECTED_SOURCE_SHA" ]]; then
    echo "Measurement snapshot does not match the expected source digest." >&2
    exit 1
fi
export CBR_SCRATCH_PATH="$SCRATCH"
SCRATCH_EXISTED=$CBR_INTERNAL_SCRATCH_EXISTED
assert_locks_held "scratch cleanup"
# --- Child phase 1: produce the exact distribution --------------------------
#
# A clean scratch path makes build time comparable and prevents stale objects
# from hiding dependency mistakes.  build-app.sh creates both archive formats.
swift package --scratch-path "$SCRATCH" clean

PACKAGE_START=$EPOCHREALTIME
"$ROOT/scripts/build-app.sh" --archive
PACKAGE_SECONDS=$(printf "%.3f" $((EPOCHREALTIME - PACKAGE_START)))
assert_source_unchanged "release package"

# --- Child phase 2: correctness and declared runtime policy -----------------
#
# Ordinary test mode skips opt-in benchmarks.  The CBR_POLICY line is asserted
# by tests and then copied into JSON so cache/prefetch constants cannot drift
# silently from the documentation.
TEST_OUTPUT=$(swift test -c release -debug-info-format none \
    --scratch-path "$SCRATCH" 2>&1)
assert_source_unchanged "correctness tests"
print -r -- "$TEST_OUTPUT"
TEST_SUMMARY=$(print -r -- "$TEST_OUTPUT" \
    | grep -E 'Executed [0-9]+ tests?,.*failures' | tail -n 1)
TESTS_EXECUTED=$(print -r -- "$TEST_SUMMARY" \
    | sed -E 's/.*Executed ([0-9]+) tests?.*/\1/')
TESTS_FAILED=$(print -r -- "$TEST_SUMMARY" \
    | grep -Eo '[0-9]+ failures' | awk '{print $1}')
TESTS_SKIPPED=$(print -r -- "$TEST_SUMMARY" \
    | grep -Eo '[0-9]+ tests? skipped' | awk '{print $1}' || true)
TESTS_SKIPPED=${TESTS_SKIPPED:-0}
POLICY_LINE=$(print -r -- "$TEST_OUTPUT" | grep "CBR_POLICY " | tail -n 1 || true)
validate_metric_line runtime_policy "$POLICY_LINE" \
    image_cache_limit_bytes image_cache_entry_limit \
    forward_prefetch_pages backward_buffer_pages

# --- Child phase 3: repeatable microbenchmarks -------------------------------
#
# Performance and policy replay run separately.  This keeps each raw stream
# attributable and allows the ordinary test count to retain its skipped markers.
PERFORMANCE_OUTPUT=$(CBR_BENCHMARK=1 swift test -c release -debug-info-format none \
    --filter PerformanceTests --scratch-path "$SCRATCH" 2>&1)
assert_source_unchanged "performance benchmarks"
PREFETCH_OUTPUT=$(CBR_BENCHMARK=1 swift test -c release -debug-info-format none \
    --filter PrefetchReplayTests/testPrefetchReplayBenchmark \
    --scratch-path "$SCRATCH" 2>&1)
assert_source_unchanged "prefetch replay"
BENCHMARK_OUTPUT="$PERFORMANCE_OUTPUT
$PREFETCH_OUTPUT"
print -r -- "$BENCHMARK_OUTPUT"

ARCHIVE_SCAN_LINE=$(metric_line archive_scan)
CBZ_OPEN_LINE=$(metric_line cbz_open)
IMAGE_DECODE_LINE=$(metric_line image_decode)
PREFETCH_REPLAY_LINE=$(metric_line prefetch_replay_total)
validate_metric_line archive_scan "$ARCHIVE_SCAN_LINE" \
    pages samples median_ms fastest_ms slowest_ms
validate_metric_line cbz_open "$CBZ_OPEN_LINE" \
    pages archive_bytes samples median_ms fastest_ms slowest_ms
validate_metric_line image_decode "$IMAGE_DECODE_LINE" \
    source_width source_height preview_dimension cold_samples cache_samples \
    cold_ms cache_hit_ms decoded_bytes
validate_metric_line prefetch_replay_total "$PREFETCH_REPLAY_LINE" \
    static_misses adaptive_misses static_stalls adaptive_stalls \
    static_prefetch_decodes adaptive_prefetch_decodes wins losses

# --- Child phase 4: inspect artifacts, Mach-O, and readable source -----------
#
# Logical and allocated bundle sizes answer different questions; ZIP and XZ
# capture distribution cost; segment sizes show whether growth is code, data,
# or linker metadata.  Comment-heavy readability work increases source lines
# and bytes but—being removed by the compiler—should not increase __text.
BINARY_BYTES=$(stat -f %z "$BINARY")
SYMBOL_EXECUTABLE_BYTES=$(stat -f %z "$SYMBOL_EXECUTABLE")
BUNDLE_LOGICAL_BYTES=$(find "$APP" -type f -exec stat -f %z {} \; \
    | awk '{sum += $1} END {print sum}')
BUNDLE_ALLOCATED_KIB=$(du -sk "$APP" | awk '{print $1}')
ZIP_BYTES=$(stat -f %z "$ARCHIVE")
TAR_XZ_BYTES=$(stat -f %z "$TAR_XZ_ARCHIVE")
DYNAMIC_DEPENDENCIES=$(otool -L "$BINARY" | tail -n +2 | wc -l | tr -d ' ')
SIZE_OUTPUT=$(size -m "$BINARY")
TEXT_SEGMENT=$(print -r -- "$SIZE_OUTPUT" \
    | awk '/Segment __TEXT:/{print $3}')
TEXT_SECTION=$(print -r -- "$SIZE_OUTPUT" \
    | awk '/Section __text:/{print $3}')
DATA_CONST_SEGMENT=$(print -r -- "$SIZE_OUTPUT" \
    | awk '/Segment __DATA_CONST:/{print $3}')
DATA_SEGMENT=$(print -r -- "$SIZE_OUTPUT" \
    | awk '/Segment __DATA:/{print $3}')
LINKEDIT_SEGMENT=$(print -r -- "$SIZE_OUTPUT" \
    | awk '/Segment __LINKEDIT:/{print $3}')
PRODUCTION_SOURCE_FILES=$(find "$ROOT/Sources" -type f -name '*.swift' \
    | wc -l | tr -d ' ')
PRODUCTION_SOURCE_LINES=$(find "$ROOT/Sources" -type f -name '*.swift' \
    -exec wc -l {} \; | awk '{sum += $1} END {print sum}')
PRODUCTION_SOURCE_BYTES=$(find "$ROOT/Sources" -type f -name '*.swift' \
    -exec stat -f %z {} \; | awk '{sum += $1} END {print sum}')

# Environment metadata makes timing comparisons falsifiable.  Swift, macOS, and
# architecture changes can move numbers even when source is identical.
SWIFT_BANNER=$(swift --version 2>&1)
if [[ "$SWIFT_BANNER" =~ 'Swift version ([0-9]+([.][0-9]+)+)' ]]; then
    SWIFT_VERSION=$match[1]
else
    echo "Could not parse the Swift version." >&2
    exit 1
fi
MEASURED_AT=$(date +%Y-%m-%dT%H:%M:%S%z)

mkdir -p "${OUTPUT:h}"
TEMP_OUTPUT="$OUTPUT.tmp.$$"
trap 'rm -f "$TEMP_OUTPUT"' EXIT
# --- Child phase 5: validate and atomically publish --------------------------
#
# JSON is assembled without a runtime scripting dependency, then plutil parses
# it before the temporary file is renamed into place.
cat > "$TEMP_OUTPUT" <<JSON
{
  "schema_version": 2,
  "label": "$LABEL",
  "measured_at": "$MEASURED_AT",
  "environment": {
    "macos": "$(sw_vers -productVersion)",
    "architecture": "$(uname -m)",
    "swift": "$SWIFT_VERSION",
    "minimum_target": "macOS 14.0"
  },
  "source": {
    "digest_schema": "cbr-source-digest-v5",
    "digest_scope": [
      "Package.swift",
      "VERSION",
      "LICENSE",
      "LICENSING.md",
      "LICENSES/BRANDING.md",
      "Package.resolved when present",
      "Assets regular files except .DS_Store",
      "Sources regular files except .DS_Store",
      "Tests regular files except .DS_Store",
      "scripts regular files except .DS_Store"
    ],
    "sha256": "$SOURCE_SHA"
  },
  "production_source": {
    "swift_files": $PRODUCTION_SOURCE_FILES,
    "lines": $PRODUCTION_SOURCE_LINES,
    "bytes": $PRODUCTION_SOURCE_BYTES
  },
  "correctness": {
    "tests_executed": $TESTS_EXECUTED,
    "tests_skipped": $TESTS_SKIPPED,
    "tests_failed": $TESTS_FAILED
  },
  "archive_scan": {
    "page_count": $(metric_value "$ARCHIVE_SCAN_LINE" pages),
    "samples": $(metric_value "$ARCHIVE_SCAN_LINE" samples),
    "median_ms": $(metric_value "$ARCHIVE_SCAN_LINE" median_ms),
    "fastest_ms": $(metric_value "$ARCHIVE_SCAN_LINE" fastest_ms),
    "slowest_ms": $(metric_value "$ARCHIVE_SCAN_LINE" slowest_ms)
  },
  "cbz_open": {
    "page_count": $(metric_value "$CBZ_OPEN_LINE" pages),
    "archive_bytes": $(metric_value "$CBZ_OPEN_LINE" archive_bytes),
    "samples": $(metric_value "$CBZ_OPEN_LINE" samples),
    "median_ms": $(metric_value "$CBZ_OPEN_LINE" median_ms),
    "fastest_ms": $(metric_value "$CBZ_OPEN_LINE" fastest_ms),
    "slowest_ms": $(metric_value "$CBZ_OPEN_LINE" slowest_ms)
  },
  "image_decode": {
    "source_width": $(metric_value "$IMAGE_DECODE_LINE" source_width),
    "source_height": $(metric_value "$IMAGE_DECODE_LINE" source_height),
    "preview_dimension": $(metric_value "$IMAGE_DECODE_LINE" preview_dimension),
    "cold_samples": $(metric_value "$IMAGE_DECODE_LINE" cold_samples),
    "cache_samples": $(metric_value "$IMAGE_DECODE_LINE" cache_samples),
    "cold_ms": $(metric_value "$IMAGE_DECODE_LINE" cold_ms),
    "cache_hit_ms": $(metric_value "$IMAGE_DECODE_LINE" cache_hit_ms),
    "decoded_bytes": $(metric_value "$IMAGE_DECODE_LINE" decoded_bytes)
  },
  "prefetch_replay": {
    "static_demand_misses": $(metric_value "$PREFETCH_REPLAY_LINE" static_misses),
    "adaptive_demand_misses": $(metric_value "$PREFETCH_REPLAY_LINE" adaptive_misses),
    "static_stalled_turns": $(metric_value "$PREFETCH_REPLAY_LINE" static_stalls),
    "adaptive_stalled_turns": $(metric_value "$PREFETCH_REPLAY_LINE" adaptive_stalls),
    "static_prefetch_decodes": $(metric_value "$PREFETCH_REPLAY_LINE" static_prefetch_decodes),
    "adaptive_prefetch_decodes": $(metric_value "$PREFETCH_REPLAY_LINE" adaptive_prefetch_decodes),
    "winning_cases": $(metric_value "$PREFETCH_REPLAY_LINE" wins),
    "losing_cases": $(metric_value "$PREFETCH_REPLAY_LINE" losses)
  },
  "build_and_package": {
    "seconds": $PACKAGE_SECONDS,
    "scratch_existed": $SCRATCH_EXISTED,
    "scratch_cleaned": true
  },
  "distribution": {
    "signed_executable_bytes": $BINARY_BYTES,
    "retained_symbol_executable_bytes": $SYMBOL_EXECUTABLE_BYTES,
    "bundle_logical_bytes": $BUNDLE_LOGICAL_BYTES,
    "bundle_allocated_kib": $BUNDLE_ALLOCATED_KIB,
    "zip_bytes": $ZIP_BYTES,
    "tar_xz_bytes": $TAR_XZ_BYTES,
    "dynamic_dependencies": $DYNAMIC_DEPENDENCIES,
    "mach_o": {
      "text_segment_bytes": $TEXT_SEGMENT,
      "text_section_bytes": $TEXT_SECTION,
      "data_const_segment_bytes": $DATA_CONST_SEGMENT,
      "data_segment_bytes": $DATA_SEGMENT,
      "linkedit_segment_bytes": $LINKEDIT_SEGMENT
    }
  },
  "runtime_policy": {
    "image_loading": "off-main immediate decode",
    "image_cache_limit_bytes": $(metric_value "$POLICY_LINE" image_cache_limit_bytes),
    "image_cache_entry_limit": $(metric_value "$POLICY_LINE" image_cache_entry_limit),
    "forward_prefetch_pages": $(metric_value "$POLICY_LINE" forward_prefetch_pages),
    "backward_buffer_pages": $(metric_value "$POLICY_LINE" backward_buffer_pages)
  }
}
JSON

plutil -convert json -o /dev/null -- "$TEMP_OUTPUT"
assert_source_unchanged "metrics publication"
mv "$TEMP_OUTPUT" "$OUTPUT"
trap - EXIT
echo "$OUTPUT"
