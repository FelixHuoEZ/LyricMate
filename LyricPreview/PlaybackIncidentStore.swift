import Foundation

final class PlaybackIncidentStore: @unchecked Sendable {
    struct Limits: Sendable {
        var count = 20
        var bytes = 10 * 1024 * 1024
        var age: TimeInterval = 7 * 24 * 60 * 60
    }
    struct Status: Sendable {
        var saved = 0
        var failures = 0
        var droppedPending = 0
    }
    typealias Writer = @Sendable (Data, URL) throws -> Void
    let directory: URL
    private let queue = DispatchQueue(label: "local.lyricmate.alpha.incident-disk", qos: .utility)
    private let lock = NSLock()
    private let limits: Limits
    private let writer: Writer
    private var pending: [UUID: PlaybackIncident] = [:]
    private var pendingOrder: [UUID] = []
    private var draining = false
    private var result = Status()
    private var cleanupTimer: DispatchSourceTimer?

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("local.lyricmate.alpha/diagnostics/incidents", isDirectory: true),
         limits: Limits = Limits(), maintenance: Bool = true,
         writer: @escaping Writer = { data, url in
             try data.write(to: url, options: .atomic)
             try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
         }) {
        self.directory = directory
        self.limits = Limits(count: max(1, min(20, limits.count)), bytes: max(1, min(10 * 1024 * 1024, limits.bytes)),
                             age: max(1, min(7 * 24 * 60 * 60, limits.age)))
        self.writer = writer
        queue.async { [weak self] in self?.cleanup() }
        if maintenance {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 60, repeating: 60)
            timer.setEventHandler { [weak self] in self?.cleanup() }
            cleanupTimer = timer
            timer.resume()
        }
    }

    deinit { cleanupTimer?.cancel() }

    var status: Status { lock.lock(); defer { lock.unlock() }; return result }

    func submit(_ incident: PlaybackIncident) {
        lock.lock(); defer { lock.unlock() }
        if pending[incident.requestID] == nil {
            if pendingOrder.count >= 20 {
                pending.removeValue(forKey: pendingOrder.removeFirst())
                result.droppedPending += 1
            }
            pendingOrder.append(incident.requestID)
        }
        pending[incident.requestID] = incident
        guard !draining else { return }
        draining = true
        queue.async { [weak self] in self?.drain() }
    }

    func flush() async { await withCheckedContinuation { continuation in queue.async { continuation.resume() } } }

    private func drain() {
        while true {
            lock.lock()
            guard !pendingOrder.isEmpty else { draining = false; lock.unlock(); return }
            let id = pendingOrder.removeFirst()
            let incident = pending.removeValue(forKey: id)
            lock.unlock()
            guard let incident else { continue }
            do { if try persist(incident) { lock.lock(); result.saved += 1; lock.unlock() } }
            catch { lock.lock(); result.failures += 1; lock.unlock() }
        }
    }

    private struct File {
        let url: URL
        let detectedAt: Date
        let bytes: Int
    }

    private func files() throws -> [File] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path) else { return [] }
        let info = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard info.isDirectory == true, info.isSymbolicLink != true else { throw CocoaError(.fileWriteInvalidFileName) }
        return try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]).compactMap { url in
            let name = url.lastPathComponent
            guard name.range(of: #"^incident-[0-9]+-[A-Fa-f0-9-]{36}-[A-Fa-f0-9-]{36}\.json$"#, options: .regularExpression) != nil,
                  let seconds = Double(name.split(separator: "-")[1]) else { return nil }
            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true else { return nil }
            return File(url: url, detectedAt: Date(timeIntervalSince1970: seconds), bytes: info.fileSize ?? 0)
        }.sorted { $0.detectedAt == $1.detectedAt ? $0.url.lastPathComponent < $1.url.lastPathComponent : $0.detectedAt < $1.detectedAt }
    }

    private func cleanup() {
        do { try prune(now: Date(), incoming: nil, incomingBytes: 0) }
        catch { lock.lock(); result.failures += 1; lock.unlock() }
    }

    private func prune(now: Date, incoming: URL?, incomingBytes: Int) throws {
        var kept: [File] = []
        for file in try files() {
            if now.timeIntervalSince(file.detectedAt) >= limits.age { try FileManager.default.removeItem(at: file.url) }
            else if file.url != incoming { kept.append(file) }
        }
        let incomingCount = incoming == nil ? 0 : 1
        var bytes = kept.reduce(incomingBytes) { $0 + $1.bytes }
        while kept.count + incomingCount > limits.count || bytes > limits.bytes {
            guard !kept.isEmpty else { throw CocoaError(.fileWriteOutOfSpace) }
            let first = kept.removeFirst()
            try FileManager.default.removeItem(at: first.url)
            bytes -= first.bytes
        }
    }

    private func persist(_ incident: PlaybackIncident) throws -> Bool {
        let now = Date()
        guard now.timeIntervalSince(incident.detectedAt) < limits.age else { return false }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(incident)
        guard data.count <= limits.bytes else { throw CocoaError(.fileWriteOutOfSpace) }
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("incident-\(Int(incident.detectedAt.timeIntervalSince1970))-\(incident.sessionID)-\(incident.requestID).json")
        if manager.fileExists(atPath: url.path) {
            let info = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard info.isSymbolicLink != true, info.isRegularFile == true else { throw CocoaError(.fileWriteInvalidFileName) }
        }
        try prune(now: now, incoming: url, incomingBytes: data.count)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try writer(data, url)
        return true
    }
}
