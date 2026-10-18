#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
source_png="$root/LyricPreview/Resources/LyricMateIcon-1024.png"
output="${1:?Usage: build-lyricmate-icon.sh /absolute/new/LyricMate.icns}"
[[ "$output" = /* && "$output" == *.icns && ! -e "$output" && ! -L "$output" ]] || {
    printf '%s\n' 'Expected a new absolute .icns output path; existing assets are never overwritten.' >&2
    exit 2
}
work="$(mktemp -d /tmp/lyricmate-icon-XXXXXX)"
trap 'rm -rf "$work"' EXIT
iconset="$work/LyricMate.iconset"
mkdir "$iconset"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$source_png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    retina=$((size * 2))
    sips -z "$retina" "$retina" "$source_png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$output"
printf '%s\n' "$output"
