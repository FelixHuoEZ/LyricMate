#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
app="${1:?Usage: test-lyricmate-icon.sh /absolute/app-bundle.app}"
[[ "$app" = /* && -d "$app" && ! -L "$app" ]] || exit 2
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == local.lyricmate.alpha ]]
icon_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$app/Contents/Info.plist")"
[[ "$icon_name" == LyricMate.icns ]]
icon="$app/Contents/Resources/$icon_name"
[[ -f "$icon" && ! -L "$icon" ]]
cmp "$root/LyricPreview/Resources/LyricMate.icns" "$icon"
work="$(mktemp -d /tmp/lyricmate-icon-test-XXXXXX)"
trap 'rm -rf "$work"' EXIT
iconset="$work/LyricMate.iconset"
iconutil -c iconset "$icon" -o "$iconset"
count=0
for size in 16 32 128 256 512; do
    for scale in 1 2; do
        suffix=''
        if [[ "$scale" == 2 ]]; then suffix='@2x'; fi
        file="$iconset/icon_${size}x${size}${suffix}.png"
        pixels=$((size * scale))
        metadata="$(sips -g pixelWidth -g pixelHeight -g hasAlpha "$file")"
        [[ "$(awk '/pixelWidth:/{print $2}' <<< "$metadata")" == "$pixels" ]]
        [[ "$(awk '/pixelHeight:/{print $2}' <<< "$metadata")" == "$pixels" ]]
        [[ "$(awk '/hasAlpha:/{print $2}' <<< "$metadata")" == yes ]]
        count=$((count + 1))
    done
done
codesign --verify --strict "$app"
printf 'PASS icon reference, bundled asset, %s size/scale variants, transparency and signed package.\n' "$count"
