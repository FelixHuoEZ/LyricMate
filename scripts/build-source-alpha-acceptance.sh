#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
name='LyricMate Alpha Acceptance'
identifier='local.lyricmate.alpha.acceptance'
permission=false
case "${1:-}" in
    '') ;;
    --permission-denied) name='LyricMate Permission Denied'; identifier+='.permission.denied'; permission=true ;;
    --permission-allowed) name='LyricMate Permission Check 2'; identifier+='.permission.allowed'; permission=true ;;
    *) printf '%s\n' 'Unknown acceptance build mode.' >&2; exit 1 ;;
esac
output="$root/dist/$name.app"
if [[ -e "$output" ]]; then
    printf '%s\n' 'Acceptance build already exists; choose a clean source directory.' >&2
    exit 1
fi
cache="$(mktemp -d "${TMPDIR:-/tmp}/lyricmate-acceptance-cache.XXXXXX")"
trap 'rm -rf "$cache"' EXIT
mkdir -p "$output/Contents/MacOS" "$output/Contents/Resources"
cd "$root"
source "$root/scripts/preview-sources.sh"
sources+=(Tests/SourceAlphaAcceptance/SourceAlphaAcceptanceApp.swift)
if $permission; then
    sources=(Tests/SourceAlphaAcceptance/PermissionProbeApp.swift)
fi
swiftc -parse-as-library -swift-version 5 -strict-concurrency=complete -warnings-as-errors \
    -D PREVIEW_ACCEPTANCE -Onone -target arm64-apple-macos15.0 -sdk "$(xcrun --show-sdk-path)" \
    -file-prefix-map "$root=/LyricMate" -debug-prefix-map "$root=/LyricMate" \
    -module-cache-path "$cache" -module-name LyricMateAlphaAcceptance \
    "${sources[@]}" \
    -o "$output/Contents/MacOS/LyricMateAlphaAcceptance"
cp LyricPreview/Info.plist "$output/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $identifier" "$output/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable LyricMateAlphaAcceptance' "$output/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $name" "$output/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $name" "$output/Contents/Info.plist"
if $permission; then
    /usr/libexec/PlistBuddy -c 'Set :NSAppleEventsUsageDescription Check the macOS Automation permission result only. This test does not read songs or send playback commands.' "$output/Contents/Info.plist"
fi
cp -R Localization/Resources/en.lproj Localization/Resources/zh-Hans.lproj "$output/Contents/Resources/"
cp LyricPreview/Resources/LyricMate.icns "$output/Contents/Resources/"
codesign --force --sign - --identifier "$identifier" "$output"
codesign --verify --strict "$output"
printf '%s\n' "$output"
