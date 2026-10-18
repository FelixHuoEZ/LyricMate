# LyricMate Alpha

English | [简体中文](README.zh-CN.md)

Authors: [FelixHuoEZ](https://github.com/FelixHuoEZ) and codex.

Menu-bar lyrics and a transparent, two-line floating lyric window for macOS, following an already-running Spotify desktop client.

This is a standalone source alpha, not an official Lyric Fever release or a product of Spotify or any lyric service. Parts are based on [Lyric Fever](https://github.com/aviwad/LyricFever), with the original MIT license and third-party attribution preserved. There is no official installer, automatic updater or stability guarantee yet.

## Features

- Menu-bar lyrics, transparent two-line overlay, smart wrapping, upward line transitions and a singing countdown.
- Optional artist input, title-only fallback, match scores, progressive candidate upgrades, manual selection and revalidated offsets.
- Play/pause, previous/next and menu-based seeking. Floating controls appear on hover and stay hidden when the window is locked for click-through.
- Local LRC files, saved settings, configuration backups and bounded local diagnostics. No lyric database or account credentials are bundled.

A match score is not a synchronization accuracy percentage; provisional matches may refer to another recording. Word-by-word singing, vocal-emphasis and breath annotations are outside the current scope.

## Languages

The interface follows the system's preferred app language: English or Simplified Chinese, with English as the fallback for unsupported languages. Relaunch after changing the app language in macOS. Lyrics, song metadata and user-supplied source names are displayed as provided, not translated.

Language selection does not rename configuration keys, source IDs, data folders or saved recording fingerprints. Existing connections, floating-window settings, sources and offsets remain in the same configuration domain.

## Build and Test

The current target is Apple Silicon on macOS 15 or later. Install full Xcode and ensure `xcrun --show-sdk-path` works. Intel and earlier systems have not been accepted. The standalone build does not use the upstream Xcode project or third-party compiler macros.

```sh
swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
python3 scripts/check-localization.py
bash scripts/build-lyric-preview.sh
python3 scripts/public-source.py check
python3 scripts/public-source.py archive
```

Outputs are `dist/LyricMate Alpha.app` and `dist/LyricMate-source.tar.gz`. Scripts only build; they do not install, launch or overwrite existing output. Move an older output aside before rebuilding. The app is ad-hoc signed locally, not Developer ID signed or notarized; this is not Gatekeeper or installer acceptance. Do not distribute this build as a finished installer.

## Use and Permissions

1. Start Spotify and the built alpha yourself.
2. Click **Enable read-only Spotify following** and decide whether to grant macOS Automation permission.
3. Show floating lyrics or search manually. A title alone is enough. Playback controls act only on explicit clicks.

The app does not log in, read Spotify cookies or launch Spotify automatically. Live highlighting stops when playback state is unavailable. LRCLIB is the initial default; other adapters must be added explicitly. Experimental platform endpoints may change, fail or be rate-limited. Musixmatch and LyricFind are not connected without official access and display rights.

The alpha app identifier is `local.lyricmate.alpha`, with settings in `local.lyricmate.alpha.daily.v1`. It is isolated from other editions and does not migrate their settings automatically. Existing internal directory and module names are retained to limit behavioral risk.

## Privacy, Sources and Maintenance

Searches send the entered title, artist and necessary candidate identifiers to the selected services. Local imports do not use the network. Settings, lyric files and bounded diagnostics stay on this Mac unless you export or share them. Diagnostic exports may include track metadata; review them before sharing. The app has no source-code or diagnostic-upload feature.

Additional documentation, currently in Chinese: [privacy](docs/privacy.md), [source policy](docs/sources.md), [security](SECURITY.md), [requirements and design](docs/requirements-and-design.md), and [release checklist](docs/release-checklist.md). When reporting a bug, share only redacted steps, version and error categories, not account tokens, personal settings, playback records or full lyrics.

Code is covered by [MIT](LICENSE) and the [third-party notices](NOTICE.md). These licenses do not grant rights to lyrics, recordings, trademarks or external services. Public distribution and signed-installer acceptance remain separate release gates.
