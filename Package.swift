// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LyricMate",
    defaultLocalization: "en",
    platforms: [.macOS("15.0")],
    products: [.library(name: "LyricFeverCore", targets: ["LyricFeverCore"])],
    targets: [
        .target(name: "LyricMateLocalization", path: "Localization", resources: [.process("Resources")]),
        .testTarget(name: "LyricMateLocalizationTests", dependencies: ["LyricMateLocalization"], path: "Tests/LyricMateLocalizationTests"),
        .target(name: "LyricFeverCore", dependencies: ["LyricMateLocalization"], path: "LyricFever", sources: [
            "Models/LyricLine.swift", "Models/LyricTimeline.swift", "Models/NetworkFetchReturn.swift", "Models/FetchError.swift",
            "Models/CoreData/SongObject.swift", "Models/CoreData/SongObjectExtensions.swift",
            "Models/LyricsParser/LyricsParser.swift", "Models/LyricsParser/LyricsHeader.swift",
            "LyricProvider/LyricProvider.swift", "LyricProvider/SongResult.swift", "LyricProvider/LyricFetchPipeline.swift", "LyricProvider/LyricPreviewSession.swift",
            "LyricProvider/PreviewRecordingMatcher.swift", "LyricProvider/PreviewRecordingPreferences.swift", "LyricProvider/PreviewLyricPresentation.swift",
            "LyricProvider/PreviewLocalLyrics.swift", "LyricProvider/PreviewBackup.swift", "LyricProvider/CustomHTTP/AMLLSource.swift",
            "LyricProvider/CustomHTTP/LyricSourceStore.swift", "LyricProvider/CustomHTTP/LyricHTTPClient.swift",
            "LyricProvider/CustomHTTP/CustomHTTPSourceProvider.swift", "LyricProvider/CustomHTTP/LyricSourceRegistry.swift", "LyricProvider/CustomHTTP/PlatformLyricSource.swift"
        ]),
        .testTarget(name: "LyricFeverCoreTests", dependencies: ["LyricFeverCore"], path: "Tests/LyricFeverCoreTests"),
        .target(name: "LyricPreviewPolicy", dependencies: ["LyricMateLocalization"], path: "LyricPreview", exclude: ["Info.plist", "Resources", "ReadOnlySpotifyReader.swift", "SpotifyPlaybackControl.swift", "LyricPreviewApp.swift", "PreviewSourcesView.swift", "PreviewFilesView.swift", "PreviewLibraryView.swift", "PreviewDesktopPresentation.swift", "PreviewFloatingPanel.swift", "PreviewWrappedTextView.swift"],
                sources: ["PlaybackReadGate.swift", "PlaybackControlPolicy.swift", "PlaybackControlDiagnostics.swift", "PlaybackReadRecovery.swift", "PlaybackReadDiagnostics.swift", "PlaybackProcessDiscovery.swift", "PlaybackMetadataCache.swift", "PlaybackReadBudget.swift", "PlaybackIncidentRecorder.swift", "PlaybackIncidentStore.swift", "PreviewPresentationSettings.swift", "PreviewFloatingLayoutPolicy.swift", "PreviewLyricWrapping.swift"]),
        .testTarget(name: "LyricPreviewPolicyTests", dependencies: ["LyricPreviewPolicy", "LyricFeverCore"], path: "Tests/LyricPreviewPolicyTests")
    ]
)
