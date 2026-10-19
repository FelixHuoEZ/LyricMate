import Foundation

/// Explicit projection, not text replacement: unknown free-form strings never leave the app.
enum PreviewShareDiagnostics {
    private struct Event: Encodable {
        let stage: String
        let status: String
        let elapsedMS: Int
        let errorCode: Int?
    }
    private struct Control: Encodable {
        let command: PlaybackControlCommand
        let totalToReadbackMS: Int?
        let events: [Event]
    }
    private struct Report: Encodable {
        let schemaVersion = 1
        let application = "LyricMate"
        let reads: [Event]
        let controls: [Control]
    }
    private static let readStages: Set<String> = [
        "request.deadline", "request.worker.deadline", "bridge.isRunning", "track.metadata.cache",
        "playerState", "probe.playerState", "playerPosition", "currentTrack", "track.spotifyUrl",
        "currentTrack.spotifyUrl.confirm", "track.name", "track.artist", "track.album", "track.duration"
    ]
    private static let statuses: Set<String> = [
        "started", "succeeded", "failed", "expired", "cancelled", "unavailable", "missing", "hit"
    ]

    static func preview(reads: [PlaybackReadDiagnostic], controls: [PlaybackControlDiagnostics.Entry]) throws -> String {
        let report = Report(reads: reads.suffix(200).map {
            Event(stage: readStages.contains($0.stage) ? $0.stage : "other",
                  status: statuses.contains($0.status) ? $0.status : "other",
                  elapsedMS: max(0, $0.elapsedMS), errorCode: $0.errorCode)
        }, controls: controls.suffix(20).map {
            Control(command: $0.command, totalToReadbackMS: $0.totalToReadbackMS.map { max(0, $0) },
                    events: $0.events.suffix(64).map {
                Event(stage: $0.stage.rawValue, status: $0.status.rawValue,
                      elapsedMS: max(0, $0.elapsedMS), errorCode: $0.errorCode)
            })
        })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(report), as: UTF8.self)
    }

    static func save(_ preview: String, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let url = directory.appendingPathComponent("share-diagnostics.json")
        try Data(preview.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
