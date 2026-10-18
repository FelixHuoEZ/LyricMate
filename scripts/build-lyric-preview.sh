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
sources=(
    Localization/L10n.swift
    LyricFever/Models/LyricLine.swift
    LyricFever/Models/LyricTimeline.swift
    LyricFever/Models/NetworkFetchReturn.swift
    LyricFever/Models/FetchError.swift
    LyricFever/Models/CoreData/SongObject.swift
    LyricFever/Models/CoreData/SongObjectExtensions.swift
    LyricFever/Models/LyricsParser/LyricsParser.swift
    LyricFever/Models/LyricsParser/LyricsHeader.swift
    LyricFever/LyricProvider/LyricProvider.swift
    LyricFever/LyricProvider/SongResult.swift
    LyricFever/LyricProvider/LyricFetchPipeline.swift
    LyricFever/LyricProvider/LyricPreviewSession.swift
    LyricFever/LyricProvider/PreviewRecordingMatcher.swift
    LyricFever/LyricProvider/PreviewRecordingPreferences.swift
    LyricFever/LyricProvider/PreviewLyricPresentation.swift
    LyricFever/LyricProvider/PreviewLocalLyrics.swift
    LyricFever/LyricProvider/PreviewBackup.swift
    LyricFever/LyricProvider/CustomHTTP/AMLLSource.swift
    LyricFever/LyricProvider/CustomHTTP/LyricSourceStore.swift
    LyricFever/LyricProvider/CustomHTTP/LyricHTTPClient.swift
    LyricFever/LyricProvider/CustomHTTP/CustomHTTPSourceProvider.swift
    LyricFever/LyricProvider/CustomHTTP/LyricSourceRegistry.swift
    LyricFever/LyricProvider/CustomHTTP/PlatformLyricSource.swift
    LyricPreview/ReadOnlySpotifyReader.swift
    LyricPreview/PlaybackControlPolicy.swift
    LyricPreview/PlaybackControlDiagnostics.swift
    LyricPreview/SpotifyPlaybackControl.swift
    LyricPreview/PlaybackReadGate.swift
    LyricPreview/PlaybackReadBudget.swift
    LyricPreview/PlaybackMetadataCache.swift
    LyricPreview/PlaybackReadRecovery.swift
    LyricPreview/PlaybackReadDiagnostics.swift
    LyricPreview/PlaybackIncidentRecorder.swift
    LyricPreview/PlaybackIncidentStore.swift
    LyricPreview/PlaybackProcessDiscovery.swift
    LyricPreview/LyricPreviewApp.swift
    LyricPreview/PreviewSourcesView.swift
    LyricPreview/PreviewFilesView.swift
    LyricPreview/PreviewLibraryView.swift
    LyricPreview/PreviewPresentationSettings.swift
    LyricPreview/PreviewFloatingLayoutPolicy.swift
    LyricPreview/PreviewLyricWrapping.swift
    LyricPreview/PreviewWrappedTextView.swift
    LyricPreview/PreviewFloatingPanel.swift
    LyricPreview/PreviewDesktopPresentation.swift
)
swiftc -parse-as-library -swift-version 5 -strict-concurrency=complete -warnings-as-errors \
    -O -target arm64-apple-macos15.0 -sdk "$(xcrun --show-sdk-path)" \
    -file-prefix-map "$root=/LyricMate" -debug-prefix-map "$root=/LyricMate" \
    -module-cache-path "$cache" -module-name LyricPreview \
    "${sources[@]}" -o "$output/Contents/MacOS/LyricPreview"
cp LyricPreview/Info.plist "$output/Contents/Info.plist"
cp LICENSE NOTICE.md "$output/Contents/Resources/"
cp -R LICENSES "$output/Contents/Resources/"
cp -R Localization/Resources/en.lproj Localization/Resources/zh-Hans.lproj "$output/Contents/Resources/"
codesign --force --sign - --identifier local.lyricmate.alpha "$output"
codesign --verify --strict "$output"
printf '%s\n' "$output"
