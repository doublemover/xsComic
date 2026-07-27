#!/bin/zsh
set -euo pipefail

# Convert approved raster artwork into a small, inspectable three-ink SVG.
#
# This is color separation rather than artistic reinterpretation.  We classify
# pixels by their relation to the paper color, trace the two ink masks into
# Bézier paths, and reassemble them over one flat paper rectangle.  Generated
# shading disappears; silhouette, negative space, and panel geometry remain.
ROOT=${0:A:h:h}
SOURCE=${1:-"$ROOT/Assets/Brand/xsComic-app-mark.png"}
OUTPUT=${2:-"$ROOT/Assets/Brand/xsComic-app-mark.svg"}
STAGE=$(mktemp -d "/tmp/xscomic-vector.XXXXXX")
PUBLISH_STAGE=""
cleanup_vector() {
    rm -rf "$STAGE"
    if [[ -n "$PUBLISH_STAGE" ]]; then
        rm -f "$PUBLISH_STAGE"
    fi
}
trap cleanup_vector EXIT

trace_color() {
    local name=$1
    local test=$2
    local color=$3

    # In normalized sRGB, navy has more blue than red/green, while vermilion has
    # much more red.  Relative tests survive the source image's slight shading
    # better than brittle exact-color matches.
    magick "$SOURCE" -resize 1024x1024 -colorspace sRGB \
        -fx "$test?0:1" -threshold 50% "$STAGE/$name.pbm"
    # A small speck threshold rejects isolated raster noise; curve optimization
    # keeps the result near 10 KB without visibly moving the approved outline.
    potrace -s --flat -t 3 -a 1 -O 0.3 -u 1 -x 1 \
        -C "$color" -o "$STAGE/$name.svg" "$STAGE/$name.pbm"
}

trace_color navy '(b-r>0.08)&&(b-g>0.03)' '#092346'
trace_color red '(r-b>0.25)&&(r-g>0.25)' '#e62f27'

for ink in navy red; do
    sed -n '/<g /,/<[/]g>/p' "$STAGE/$ink.svg" > "$STAGE/$ink.group"
    if [[ ! -s "$STAGE/$ink.group" ]] \
        || ! grep -q '<g ' "$STAGE/$ink.group" \
        || ! grep -q '<path d="[^"]' "$STAGE/$ink.group" \
        || ! grep -q '</g>' "$STAGE/$ink.group"; then
        echo "Potrace produced no usable $ink path group." >&2
        exit 1
    fi
done

mkdir -p "${OUTPUT:h}"
PUBLISH_STAGE=$(mktemp "${OUTPUT:h}/.${OUTPUT:t}.XXXXXX")
{
    # Potrace emits a useful transformed <g> for each mask, but its page wrapper
    # is unnecessary.  Keeping only the groups yields one ordinary 1024-square
    # SVG whose layering order is paper, navy, then vermilion.
    print -r -- '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">'
    print -r -- '  <title>xsComic app mark</title>'
    print -r -- '  <rect width="1024" height="1024" fill="#faf5ef"/>'
    cat "$STAGE/navy.group"
    cat "$STAGE/red.group"
    print -r -- '</svg>'
} > "$PUBLISH_STAGE"

mv "$PUBLISH_STAGE" "$OUTPUT"
PUBLISH_STAGE=""

echo "$OUTPUT"
