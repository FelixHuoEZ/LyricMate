import Foundation

@MainActor
enum PreviewBackup {
    struct Payload: Codable {
        let application: String
        let sources: [LyricSourceConfiguration]
        let preferences: [PreviewRecordingPreferences.Entry]
        let offsets: [PreviewRecordingPreferences.PairOffset]?
        init(application: String, sources: [LyricSourceConfiguration], preferences: [PreviewRecordingPreferences.Entry],
             offsets: [PreviewRecordingPreferences.PairOffset]? = nil) {
            self.application = application; self.sources = sources; self.preferences = preferences; self.offsets = offsets
        }
    }
    struct Document: Codable {
        let schemaVersion: Int
        let payload: Payload
        let sha256: String
    }
    struct Plan {
        let payload: Payload
        let previous: Data
    }
    static let maximumBytes = 512 * 1024
    static let undoKey = "previewBackup.beforeRestore.v1"
    private static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(value)
    }
    static func export(sources: LyricSourceStore, preferences: PreviewRecordingPreferences) throws -> Data {
        guard sources.loadError == nil, preferences.loadError == nil else { throw LyricSourceError.invalidResponse }
        let payload = Payload(application: "local.lyricmate.alpha", sources: sources.sources, preferences: preferences.entries,
                              offsets: preferences.offsets.isEmpty ? nil : preferences.offsets)
        try validate(payload)
        let data = try encoded(Document(schemaVersion: 1, payload: payload, sha256: PreviewLocalLyrics.digest(encoded(payload))))
        guard data.count <= maximumBytes else { throw LyricSourceError.responseTooLarge }
        return data
    }
    private static func validate(_ payload: Payload) throws {
        guard payload.application == "local.lyricmate.alpha", payload.sources.count <= 16,
              Set(payload.sources.map(\.id)).count == payload.sources.count else { throw LyricSourceError.invalidResponse }
        try PreviewRecordingPreferences.validate(payload.preferences, offsets: payload.offsets ?? [])
        var services = Set<String>()
        for source in payload.sources {
            let url = try source.manifest.validatedURL()
            guard services.insert(source.manifest.apiFormat.rawValue + url.absoluteString).inserted else { throw LyricSourceError.duplicateSource }
        }
        guard try encoded(payload.preferences).count <= 256 * 1024 else { throw LyricSourceError.responseTooLarge }
    }
    private static func keys(_ value: Any?, allowed: Set<String>) throws -> [String: Any] {
        guard let object = value as? [String: Any], Set(object.keys).isSubset(of: allowed) else { throw LyricSourceError.invalidResponse }
        return object
    }
    static func decode(_ data: Data) throws -> Payload {
        guard data.count <= maximumBytes else { throw LyricSourceError.responseTooLarge }
        let root = try keys(JSONSerialization.jsonObject(with: data), allowed: ["schemaVersion", "payload", "sha256"])
        let payload = try keys(root["payload"], allowed: ["application", "sources", "preferences", "offsets"])
        guard let sources = payload["sources"] as? [Any], let entries = payload["preferences"] as? [Any] else { throw LyricSourceError.invalidResponse }
        for value in sources {
            let source = try keys(value, allowed: ["id", "manifest", "isEnabled"])
            let manifest = try keys(source["manifest"], allowed: ["schemaVersion", "apiVersion", "name", "baseURL", "capabilities", "auth", "format"])
            _ = try keys(manifest["auth"], allowed: ["type"])
        }
        for value in entries {
            let entry = try keys(value, allowed: ["recording", "candidateSHA256", "offsetMS", "version"])
            _ = try keys(entry["recording"], allowed: ["id", "title", "artist", "album", "durationMS"])
            if let version = entry["version"] {
                _ = try keys(version, allowed: ["sourceSHA256", "songID", "title", "artist", "album", "durationMS"])
            }
        }
        if let value = payload["offsets"] {
            guard let offsets = value as? [Any] else { throw LyricSourceError.invalidResponse }
            for value in offsets {
                let offset = try keys(value, allowed: ["recording", "candidateSHA256", "offsetMS"])
                _ = try keys(offset["recording"], allowed: ["id", "title", "artist", "album", "durationMS"])
            }
        }
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.schemaVersion == 1, document.sha256 == PreviewLocalLyrics.digest(try encoded(document.payload)) else { throw LyricSourceError.invalidResponse }
        try validate(document.payload)
        return document.payload
    }
    static func prepare(_ data: Data, sources: LyricSourceStore, preferences: PreviewRecordingPreferences) throws -> Plan {
        Plan(payload: try decode(data), previous: try export(sources: sources, preferences: preferences))
    }
    static func restore(_ plan: Plan, sources: LyricSourceStore, preferences: PreviewRecordingPreferences, defaults: UserDefaults) throws {
        guard try export(sources: sources, preferences: preferences) == plan.previous else { throw FetchError.staleTrack }
        try validate(plan.payload)
        defaults.set(plan.previous, forKey: undoKey)
        let disabled = plan.payload.sources.map { LyricSourceConfiguration(id: $0.id, manifest: $0.manifest, isEnabled: false) }
        // Full prevalidation precedes both writes; rollback preserves a coherent pair on any validation failure.
        do {
            try sources.replaceValidated(disabled)
            try preferences.replaceValidated(plan.payload.preferences, offsets: plan.payload.offsets)
        } catch {
            let old = try decode(plan.previous)
            try sources.replaceValidated(old.sources); try preferences.replaceValidated(old.preferences, offsets: old.offsets)
            throw error
        }
    }
}
