#!/bin/zsh
set -euo pipefail

# The installed app contains one ICNS container rather than ten loose PNGs.
# This script is a development-time compiler: the ordinary app build only
# copies its result, so ImageMagick never becomes a user or build dependency.
ROOT=${0:A:h:h}
STAGE=$(mktemp -d "/tmp/xscomic-icons.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT

build_icon() {
    local source=$1
    local output=$2
    local modern_output=${3:-}
    local iconset="$STAGE/${output:t:r}.iconset"
    local catalog="$STAGE/Legacy.xcassets"
    local legacy_set="$catalog/AppIcon.appiconset"
    local modern_catalog="$STAGE/Modern.xcassets"
    local modern_set="$modern_catalog/AppIcon.appiconset"
    local compiled="$STAGE/legacy-compiled"
    local modern_compiled="$STAGE/modern-compiled"
    local packed="$STAGE/${output:t}"
    local validation="$STAGE/validation.iconset"
    mkdir -p "$iconset" "$legacy_set" "$compiled"

    # Zsh's multi-variable loop consumes the complete 1x/2x family pairwise.
    for points scale in 16 1 16 2 32 1 32 2 128 1 128 2 256 1 256 2 512 1 512 2; do
        local pixels=$((points * scale))
        local suffix=""
        (( scale == 2 )) && suffix="@2x"
        local target="$iconset/icon_${points}x${points}${suffix}.png"
        local png_format=PNG8
        (( pixels <= 64 )) && png_format=PNG32
        # The mark uses three inks, but antialiased edges introduce intermediate
        # samples.  A 128-entry indexed PNG preserves those edges while cutting
        # the large ICNS planes substantially. The four 16–64 px chunks stay
        # RGBA because macOS's legacy small-icon decoder misreads indexed PNGs.
        magick -background none "$source" -resize "${pixels}x${pixels}" \
            -depth 8 -strip -colors 128 \
            -define png:compression-level=9 -define png:compression-filter=5 \
            "$png_format:$target"
    done

    # ICNS's non-Retina 16 px and 32 px records use an old compressed ARGB
    # payload rather than PNG. Let Apple's compiler produce only those two
    # legacy representations; the compact PNGs below supply every other size.
    cp "$iconset"/icon_{16x16,16x16@2x,32x32,32x32@2x}.png "$legacy_set/"
    cat > "$catalog/Contents.json" <<'JSON'
{"info":{"author":"xsComic","version":1}}
JSON
    cat > "$legacy_set/Contents.json" <<'JSON'
{
  "images": [
    {"filename":"icon_16x16.png","idiom":"mac","scale":"1x","size":"16x16"},
    {"filename":"icon_16x16@2x.png","idiom":"mac","scale":"2x","size":"16x16"},
    {"filename":"icon_32x32.png","idiom":"mac","scale":"1x","size":"32x32"},
    {"filename":"icon_32x32@2x.png","idiom":"mac","scale":"2x","size":"32x32"}
  ],
  "info":{"author":"xsComic","version":1}
}
JSON
    xcrun actool "$catalog" \
        --compile "$compiled" \
        --platform macosx \
        --minimum-deployment-target 10.7 \
        --app-icon AppIcon \
        --output-partial-info-plist "$STAGE/icon-info.plist" \
        --warnings --notices >/dev/null
    for type in ic04 ic05; do
        /usr/bin/perl -e '
            use strict;
            open my $input, "<:raw", $ARGV[0] or die $!;
            read($input, my $header, 8) == 8 or die "short ICNS";
            my $total = unpack("x4N", $header);
            my $offset = 8;
            while ($offset < $total) {
                read($input, my $chunk, 8) == 8 or die "short chunk";
                my ($type, $length) = unpack("a4N", $chunk);
                read($input, my $payload, $length - 8) == $length - 8
                    or die "short payload";
                if ($type eq $ARGV[2]) {
                    open my $output, ">:raw", $ARGV[1] or die $!;
                    print {$output} $payload;
                    exit 0;
                }
                $offset += $length;
            }
            die "missing $ARGV[2] chunk";
        ' "$compiled/AppIcon.icns" "$STAGE/$type.payload" "$type"
    done

    # Current iconutil can unpack ICNS but rejects newly-authored iconsets.
    # ICNS itself is only a big-endian chunk container, so write its ten PNG
    # chunks directly. This retains every legacy and Retina rendition without
    # shipping the much larger Assets.car produced by actool.
    local chunks=(
        ic04 "$STAGE/ic04.payload"
        ic11 "$iconset/icon_16x16@2x.png"
        ic05 "$STAGE/ic05.payload"
        ic12 "$iconset/icon_32x32@2x.png"
        ic07 "$iconset/icon_128x128.png"
        ic13 "$iconset/icon_128x128@2x.png"
        ic08 "$iconset/icon_256x256.png"
        ic14 "$iconset/icon_256x256@2x.png"
        ic09 "$iconset/icon_512x512.png"
        ic10 "$iconset/icon_512x512@2x.png"
    )
    local total=8 type file
    for type file in "${chunks[@]}"; do
        total=$((total + 8 + $(stat -f %z "$file")))
    done
    {
        print -rn -- icns
        printf '%08x' "$total" | xxd -r -p
        for type file in "${chunks[@]}"; do
            print -rn -- "$type"
            printf '%08x' $((8 + $(stat -f %z "$file"))) | xxd -r -p
            cat "$file"
        done
    } > "$packed"

    # iconutil remains a useful independent parser: publication proceeds only
    # if it can recover all ten named renditions from the completed container.
    iconutil --convert iconset --output "$validation" "$packed"
    [[ $(find "$validation" -type f | wc -l) -eq 10 ]]

    mkdir -p "${output:h}"
    mv "$packed" "$output"
    echo "$output"

    if [[ -n "$modern_output" ]]; then
        # Tahoe distinguishes an app-icon asset from a legacy picture. Without
        # this catalog it places the full square ICNS inside another rounded
        # plate. Its decoder expects RGBA planes, unlike the palette-compressed
        # large planes retained above solely to minimize the fallback ICNS.
        mkdir -p "$modern_set"
        cp "$catalog/Contents.json" "$modern_catalog/Contents.json"
        for file in "$iconset"/*.png; do
            magick "$file" -define png:compression-level=9 \
                "PNG32:$modern_set/${file:t}"
        done
        cat > "$modern_set/Contents.json" <<'JSON'
{
  "images": [
    {"filename":"icon_16x16.png","idiom":"mac","scale":"1x","size":"16x16"},
    {"filename":"icon_16x16@2x.png","idiom":"mac","scale":"2x","size":"16x16"},
    {"filename":"icon_32x32.png","idiom":"mac","scale":"1x","size":"32x32"},
    {"filename":"icon_32x32@2x.png","idiom":"mac","scale":"2x","size":"32x32"},
    {"filename":"icon_128x128.png","idiom":"mac","scale":"1x","size":"128x128"},
    {"filename":"icon_128x128@2x.png","idiom":"mac","scale":"2x","size":"128x128"},
    {"filename":"icon_256x256.png","idiom":"mac","scale":"1x","size":"256x256"},
    {"filename":"icon_256x256@2x.png","idiom":"mac","scale":"2x","size":"256x256"},
    {"filename":"icon_512x512.png","idiom":"mac","scale":"1x","size":"512x512"},
    {"filename":"icon_512x512@2x.png","idiom":"mac","scale":"2x","size":"512x512"}
  ],
  "info":{"author":"xsComic","version":1}
}
JSON
        mkdir -p "$modern_compiled"
        xcrun actool "$modern_catalog" \
            --compile "$modern_compiled" \
            --platform macosx \
            --target-device mac \
            --minimum-deployment-target 14.0 \
            --app-icon AppIcon \
            --output-partial-info-plist "$STAGE/modern-info.plist" \
            --warnings --notices >/dev/null
        [[ -s "$modern_compiled/Assets.car" ]]
        mkdir -p "${modern_output:h}"
        cp "$modern_compiled/Assets.car" "$modern_output"
        echo "$modern_output"
    fi
}

# With no arguments we rebuild the checked-in primary icon.  The two-argument
# form remains useful for inspecting an alternate without making a redundant
# ICNS part of the distributed application.
if (( $# == 2 )); then
    build_icon "${1:A}" "${2:A}"
elif (( $# == 0 )); then
    build_icon \
        "$ROOT/Assets/Brand/xsComic-app-mark.svg" \
        "$ROOT/Assets/AppIcon.icns" \
        "$ROOT/Assets/Assets.car"
else
    echo "usage: $0 [source.svg output.icns]" >&2
    exit 2
fi
