#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
output="$root/dist/LyricMate Alpha.app"
if [[ -e "$output" ]]; then
    printf '%s\n' 'Build output already exists. Move the previous dist/LyricMate Alpha.app before rebuilding.' >&2
    exit 1
fi
cache="$(mktemp -d "${TMPDIR:-/tmp}/lyricmate-module-cache.XXXXXX")"
trap 'rm -rf "$cache"' EXIT
mkdir -p "$output/Contents/MacOS" "$output/Contents/Resources"
cd "$root"
source "$root/scripts/preview-sources.sh"
swiftc -parse-as-library -swift-version 5 -strict-concurrency=complete -warnings-as-errors \
    -O -target arm64-apple-macos15.0 -sdk "$(xcrun --show-sdk-path)" \
    -file-prefix-map "$root=/LyricMate" -debug-prefix-map "$root=/LyricMate" \
    -module-cache-path "$cache" -module-name LyricPreview \
    "${sources[@]}" -o "$output/Contents/MacOS/LyricPreview"
cp LyricPreview/Info.plist "$output/Contents/Info.plist"
cp LICENSE NOTICE.md "$output/Contents/Resources/"
cp -R LICENSES "$output/Contents/Resources/"
cp -R Localization/Resources/en.lproj Localization/Resources/zh-Hans.lproj "$output/Contents/Resources/"
cp LyricPreview/Resources/LyricMate.icns "$output/Contents/Resources/"
codesign --force --sign - --identifier local.lyricmate.alpha "$output"
codesign --verify --strict "$output"
bash scripts/test-lyricmate-icon.sh "$output"
printf '%s\n' "$output"
