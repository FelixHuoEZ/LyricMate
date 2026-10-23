import AppKit
import ScriptingBridge
import CoreServices

@objc private enum PreviewSpotifyState: UInt32 {
    case stopped = 0x6b505353
    case playing = 0x6b505350
    case paused = 0x6b505370
}

@objc private protocol PreviewSpotifyApplication: NSObjectProtocol {
    @objc optional var currentTrack: PreviewSpotifyTrack { get }
    @objc optional var playerState: PreviewSpotifyState { get }
    @objc optional var playerPosition: Double { get }
}

@objc private protocol PreviewSpotifyTrack: NSObjectProtocol {
    @objc optional var name: String { get }
    @objc optional var artist: String { get }
    @objc optional var album: String { get }
    @objc optional var duration: Int { get }
    @objc optional var spotifyUrl: String { get }
}

extension SBApplication: PreviewSpotifyApplication {}
extension SBObject: PreviewSpotifyTrack {}

final class ReadOnlySpotifyReader: @unchecked Sendable {
    typealias Failure = PlaybackReadFailure
    typealias SnapshotWork = @Sendable (pid_t, Bool, (PlaybackReadDiagnostic) -> Void) throws -> PlaybackSnapshot

    private final class EventFailure: NSObject, SBApplicationDelegate {
        var code: Int?
        func eventDidFail(_ event: UnsafePointer<AppleEvent>, withError error: Error) -> Any? {
            code = (error as NSError).code
            return nil
        }
    }
    private let queue = DispatchQueue(label: "local.lyricmate.alpha.read-only-spotify", qos: .userInitiated)
    // Explicit controls share this queue; no Apple Events run concurrently with a snapshot read.
    var serializedQueue: DispatchQueue { queue }
    private let snapshotWork: SnapshotWork?
#if PREVIEW_ACCEPTANCE
    // Test-only synchronization point; real Apple Events, deadlines and identity checks still run.
    var acceptanceProgress: (@Sendable (PlaybackReadDiagnostic) -> Void)?
#endif
    private struct Metadata { let name: String; let artist: String; let album: String; let duration: Int }
    // This cache is accessed only on the serial reader queue, never on the UI actor.
    private var metadataCache = PlaybackMetadataCache<Metadata>()

    init(snapshotWork: SnapshotWork? = nil) {
        self.snapshotWork = snapshotWork
    }

    func read(processID: pid_t, requiresProbe: Bool, allowsPermissionPrompt: Bool = true,
              launchDate: Date? = nil, deadline: ContinuousClock.Instant? = nil,
              incidentRecorder: PlaybackIncidentRecorder? = nil, requestID: UUID = UUID(),
              progress: @escaping @Sendable (PlaybackReadDiagnostic) -> Void,
              completion: @escaping @Sendable (Result<PlaybackSnapshot, Failure>, [PlaybackReadDiagnostic]) -> Void) {
        let effectiveDeadline = deadline ?? ContinuousClock.now.advanced(by:
            .milliseconds(requiresProbe ? PlaybackReadGate.Request.probeBudgetMS : PlaybackReadGate.Request.pollingBudgetMS))
        incidentRecorder?.queued(requestID, processID: processID, probe: requiresProbe, deadline: effectiveDeadline)
        queue.async {
            autoreleasepool {
                incidentRecorder?.workerStarted(requestID)
                var diagnostics: [PlaybackReadDiagnostic] = []
                func record(_ event: PlaybackReadDiagnostic) {
                    diagnostics.append(event)
                    incidentRecorder?.property(requestID, event: event)
                    progress(event)
#if PREVIEW_ACCEPTANCE
                    self.acceptanceProgress?(event)
#endif
                }
                func deliver(_ result: Result<PlaybackSnapshot, Failure>, diagnosticFailure: PlaybackIncident.WorkerFailure? = nil) {
                    switch result {
                    case .success: incidentRecorder?.workerFinished(requestID, succeeded: true)
                    case .failure(let failure):
                        incidentRecorder?.workerFinished(requestID, succeeded: false,
                                                         failure: diagnosticFailure ?? .init(failure))
                    }
                    completion(result, diagnostics)
                }
                do {
                    if requiresProbe { self.metadataCache.reset() }
                    let snapshot: PlaybackSnapshot
                    if let work = self.snapshotWork { snapshot = try work(processID, requiresProbe, record) }
                    else {
                        let budget = PlaybackReadBudget(deadline: effectiveDeadline)
                        snapshot = try Self.snapshot(processID: processID, launchDate: launchDate, requiresProbe: requiresProbe,
                                                     allowsPermissionPrompt: allowsPermissionPrompt, budget: budget,
                                                     cache: &self.metadataCache, progress: record)
                    }
                    deliver(.success(snapshot))
                } catch let failure as Failure {
                    self.metadataCache.reset()
                    deliver(.failure(failure))
                } catch {
                    self.metadataCache.reset()
                    deliver(.failure(.invalidSnapshot), diagnosticFailure: .init(kind: .unexpectedError))
                }
            }
        }
    }

    static func eventSendMode(allowsPermissionPrompt: Bool) -> AESendMode {
        AESendMode(kAEWaitReply | (allowsPermissionPrompt ? 0 : kAEDoNotPromptForUserConsent))
    }

    private static func snapshot(processID: pid_t, launchDate: Date?, requiresProbe: Bool, allowsPermissionPrompt: Bool, budget: PlaybackReadBudget,
                                 cache: inout PlaybackMetadataCache<Metadata>,
                                 progress: (PlaybackReadDiagnostic) -> Void) throws -> PlaybackSnapshot {
        // Address only the already-running PID, so a failed read cannot launch Spotify.
        guard let application = SBApplication(processIdentifier: processID) else { throw Failure.missingApplication }
        application.sendMode = eventSendMode(allowsPermissionPrompt: allowsPermissionPrompt)
        let failure = EventFailure()
        application.delegate = failure
        let spotify = application as PreviewSpotifyApplication
        let roundStart = ContinuousClock.now
        func checkBudget(maximum: Int) throws -> Int {
            do { return try budget.timeoutTicks(maximum: maximum) }
            catch {
                let elapsed = roundStart.duration(to: .now).components
                progress(.init(observedAt: Date(), stage: "request.worker.deadline", status: "expired",
                               elapsedMS: Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000), errorCode: nil))
                throw Failure.deadlineExceeded
            }
        }
        func property<T>(_ stage: String, _ getter: () -> T?) throws -> T {
            let maximum = stage == "probe.playerState" ? PlaybackReadGate.Request.probeTimeoutTicks : PlaybackReadGate.Request.propertyTimeoutTicks
            application.timeout = try checkBudget(maximum: maximum)
            let start = ContinuousClock.now
            failure.code = nil
            progress(PlaybackReadDiagnostic(observedAt: Date(), stage: stage, status: "started", elapsedMS: 0, errorCode: nil))
            let value = getter()
            let elapsed = start.duration(to: .now).components
            let milliseconds = Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)
            if let code = failure.code {
                progress(PlaybackReadDiagnostic(observedAt: Date(), stage: stage, status: "failed", elapsedMS: milliseconds, errorCode: code))
                throw Failure.eventFailed(code)
            }
            guard let value else {
                progress(PlaybackReadDiagnostic(observedAt: Date(), stage: stage, status: "missing", elapsedMS: milliseconds, errorCode: nil))
                throw Failure.missingProperty(stage)
            }
            progress(PlaybackReadDiagnostic(observedAt: Date(), stage: stage, status: "succeeded", elapsedMS: milliseconds, errorCode: nil))
            _ = try checkBudget(maximum: maximum)
            return value
        }
        let bridgeRunning: Bool = try property("bridge.isRunning") { application.isRunning }
        guard bridgeRunning else {
            progress(PlaybackReadDiagnostic(observedAt: Date(), stage: "bridge.isRunning", status: "missing", elapsedMS: 0, errorCode: nil))
            throw Failure.bridgeUnavailable
        }
        if requiresProbe {
            let _: PreviewSpotifyState = try property("probe.playerState") { spotify.playerState }
        }
        let first = try property("currentTrack") { spotify.currentTrack }
        let firstID = try property("track.spotifyUrl") { first.spotifyUrl }
        let metadata: Metadata
        let refreshedMetadata: Bool
        if let cached = cache.value(processID: processID, launchDate: launchDate, trackID: firstID) {
            metadata = cached
            refreshedMetadata = false
            progress(.init(observedAt: Date(), stage: "track.metadata.cache", status: "hit", elapsedMS: 0, errorCode: nil))
        } else {
            refreshedMetadata = true
            metadata = try Metadata(name: property("track.name") { first.name }, artist: property("track.artist") { first.artist },
                                    album: property("track.album") { first.album }, duration: property("track.duration") { first.duration })
        }
        let position = try property("playerPosition") { spotify.playerPosition }
        let state = try property("playerState") { spotify.playerState }
        let lastID = try property("currentTrack.spotifyUrl.confirm") { spotify.currentTrack?.spotifyUrl }
        guard firstID == lastID else { throw Failure.trackChanged }
        let snapshot = PlaybackSnapshot(trackID: firstID, trackName: metadata.name, artistName: metadata.artist, albumName: metadata.album,
                                        durationMS: metadata.duration, positionMS: position * 1000, isPlaying: state == .playing)
        guard snapshot.isValid, state != .stopped else { throw Failure.invalidSnapshot }
        if refreshedMetadata {
            cache.store(metadata, processID: processID, launchDate: launchDate, trackID: firstID)
        }
        return snapshot
    }

}
