#!/bin/zsh
set -euo pipefail

# A metric without an exact source identity is anecdote.  This script hashes a
# canonical stream of path, content digest, and executable bit for every input
# that can affect correctness or the distributed app.  NUL separators make the
# encoding unambiguous even for unusual filenames.
ROOT=${1:-${0:A:h:h}}
cd "$ROOT"

# Documentation is intentionally excluded: prose edits must not invalidate a
# runtime measurement. The three release notices are exceptions because their
# exact bytes enter both distribution archives. Finder's `.DS_Store` is
# metadata, not a build input. Assets are included because icon bytes ship.
INPUTS=(
    VERSION LICENSE LICENSING.md LICENSES/BRANDING.md
    Assets Sources Tests scripts
)

# Following a symlink would make the digest depend on state outside this tree;
# hashing the link text would not prove the bytes a tool later reads.  Refusing
# both interpretations is the only simple, auditable rule.
if [[ -n "$(find "${INPUTS[@]}" -type l -print -quit)" ]]; then
    echo "Measured source scope contains a symlink; refusing an ambiguous digest." >&2
    exit 1
fi

{
    # Version 6 reflects the dependency-free arm64 Objective-C + Metal tree.
    print -rn -- $'cbr-source-digest-v6\0'
    find "${INPUTS[@]}" -type f ! -name '.DS_Store' -print0 \
        | LC_ALL=C sort -z \
        | while IFS= read -r -d $'\0' file; do
            file_sha=$(shasum -a 256 -- "$file" | awk '{print $1}')
            if [[ -x "$file" ]]; then
                executable=1
            else
                executable=0
            fi
            print -rn -- "$file"$'\0'"$file_sha"$'\0'"$executable"$'\0'
        done
} | shasum -a 256 | awk '{print $1}'
