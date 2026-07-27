# Shared safety vocabulary for scripts that create or replace build products.
#
# These checks look more elaborate than the build itself because cleanup is the
# one place where a concise utility can do disproportionate harm.  Every caller
# canonicalizes paths first, proves that mutable trees cannot contain source,
# and acquires a lock named by the resource's full path.

# Accept build-local paths, or explicitly claimed external scratch paths, but
# never a repository root or one of its source-bearing descendants.
validate_mutable_path() {
    local candidate=${1:A}
    local label=$2
    local source_root=${3:A}
    local allowed_build_root="$source_root/build"

    if [[ "$candidate" == "/" \
        || "$source_root" == "$candidate" \
        || "$source_root" == "$candidate/"* ]]; then
        echo "$label may not contain the source repository: $candidate" >&2
        exit 2
    fi
    if [[ "$candidate" == "$source_root"/* \
        && "$candidate" != "$allowed_build_root" \
        && "$candidate" != "$allowed_build_root"/* ]]; then
        echo "$label may only write under build/ inside the source repository: $candidate" >&2
        exit 2
    fi
}

# SwiftPM expects to own its scratch tree and may remove arbitrary descendants.
# For an external path we leave a sibling marker containing that directory's
# device/inode identity. A marker cannot bless a later directory which merely
# reuses the pathname. Pre-existing nonempty directories are never adopted:
# guessing ownership would turn a convenient cache option into a deletion risk.
claim_external_scratch_path() {
    local candidate=${1:A}
    local source_root=${2:A}
    local allowed_build_root="$source_root/build"
    if [[ "$candidate" == "$allowed_build_root" \
        || "$candidate" == "$allowed_build_root"/* ]]; then
        return
    fi

    local marker="$candidate.comic-book-reader-scratch"
    local identity_file="$marker/directory-id"
    if [[ -e "$candidate" && ! -d "$candidate" ]]; then
        echo "SwiftPM scratch path is not a directory: $candidate" >&2
        exit 2
    fi
    if [[ -e "$marker" || -L "$marker" ]]; then
        if [[ ! -d "$marker" || -L "$marker" ]]; then
            echo "Invalid SwiftPM scratch ownership marker: $marker" >&2
            exit 2
        fi
    fi

    if [[ -d "$candidate" ]]; then
        local current_identity
        current_identity=$(/usr/bin/stat -f '%d:%i' "$candidate")
        if [[ -f "$identity_file" && ! -L "$identity_file" \
            && "$(<"$identity_file")" == "$current_identity" ]]; then
            return
        fi
        if [[ -n "$(find "$candidate" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
            echo "External SwiftPM scratch path is nonempty and unowned: $candidate" >&2
            exit 2
        fi
    else
        mkdir -p "${candidate:h}"
        mkdir "$candidate"
    fi

    if [[ ! -d "$marker" ]]; then
        mkdir -p "${candidate:h}"
        mkdir "$marker"
    fi
    if [[ -e "$identity_file" || -L "$identity_file" ]]; then
        rm -f "$identity_file"
    fi
    /usr/bin/stat -f '%d:%i' "$candidate" > "$identity_file"
}

# A digest gives each canonical mutable path a fixed-size, filesystem-safe lock
# name without exposing spaces or other punctuation from the path itself.
mutable_lock_path_for() {
    local resource=${1:A}
    local key
    key=$(print -rn -- "$resource" | shasum -a 256 | awk '{print $1}')
    print -r -- "/tmp/comic-book-reader-mutable-lock.$key"
}

# Output and scratch must not nest.  Otherwise replacing an app could erase its
# compiler cache, or cache cleanup could erase a just-built distribution.
require_disjoint_paths() {
    local first=${1:A}
    local second=${2:A}
    if [[ "$first" == "$second" \
        || "$first" == "$second/"* \
        || "$second" == "$first/"* ]]; then
        echo "$3 and $4 must not overlap." >&2
        exit 2
    fi
}
