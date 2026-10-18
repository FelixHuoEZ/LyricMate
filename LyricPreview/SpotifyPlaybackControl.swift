import AppKit
import ScriptingBridge

@objc private protocol PreviewSpotifyControlApplication: NSObjectProtocol {
    @objc optional var currentTrack: PreviewSpotifyControlTrack { get }
    @objc optional var playerPosition: Double { get }
    @objc optional func previousTrack()
    @objc optional func nextTrack()
    @objc optional func playpause()
    @objc optional func setPlayerPosition(_ position: Double)
}

@objc private protocol PreviewSpotifyControlTrack: NSObjectProtocol {
    @objc optional var spotifyUrl: String { get }
    @objc optional var duration: Int { get }
}

extension SBApplication: PreviewSpotifyControlApplication {}
extension SBObject: PreviewSpotifyControlTrack {}

final class SpotifyPlaybackControl: @unchecked Sendable {
    typealias Work = @Sendable (PlaybackControlRequest) throws -> Void
    private let queue: DispatchQueue
    private let work: Work?

    init(queue: DispatchQueue, work: Work? = nil) { self.queue = queue; self.work = work }

    func send(_ request: PlaybackControlRequest,
              diagnostics: PlaybackControlDiagnostics? = nil,
              completion: @escaping @Sendable (Result<Void, PlaybackControlFailure>) -> Void) {
        queue.async {
            autoreleasepool {
                diagnostics?.workerStarted(request.token)
                do {
                    guard ContinuousClock.now < request.deadline else { throw PlaybackControlFailure.expired }
                    if let work = self.work {
                        try Self.measure(request, diagnostics: diagnostics, stage: .command) { try work(request) }
                    } else { try Self.execute(request, diagnostics: diagnostics) }
                    diagnostics?.workerFinished(request.token, failure: nil)
                    completion(.success(()))
                } catch let error as PlaybackControlFailure {
                    diagnostics?.workerFinished(request.token, failure: error)
                    completion(.failure(error))
                } catch {
                    diagnostics?.workerFinished(request.token, failure: .unexpected)
                    completion(.failure(.unexpected))
                }
            }
        }
    }

    private final class EventFailure: NSObject, SBApplicationDelegate {
        var code: Int?
        func eventDidFail(_ event: UnsafePointer<AppleEvent>, withError error: Error) -> Any? {
            code = (error as NSError).code
            return nil
        }
    }

    private static func measure<T>(_ request: PlaybackControlRequest, diagnostics: PlaybackControlDiagnostics?,
                                   stage: PlaybackControlDiagnostics.Stage, _ action: () throws -> T) throws -> T {
        diagnostics?.mark(request.token, stage: stage, status: .started)
        do {
            let result = try action()
            diagnostics?.mark(request.token, stage: stage, status: .succeeded)
            return result
        } catch {
            diagnostics?.mark(request.token, stage: stage, status: .failed, failure: error as? PlaybackControlFailure ?? .unexpected)
            throw error
        }
    }

    private static func execute(_ request: PlaybackControlRequest, diagnostics: PlaybackControlDiagnostics?) throws {
        let application: SBApplication = try measure(request, diagnostics: diagnostics, stage: .processValidation) {
            guard let running = NSRunningApplication(processIdentifier: request.process.processID), !running.isTerminated,
                  running.bundleIdentifier == PlaybackProcessDiscovery.spotifyBundleID,
                  running.launchDate == request.process.launchDate,
                  let application = SBApplication(processIdentifier: request.process.processID) else {
                throw PlaybackControlFailure.unavailable
            }
            return application
        }
        let failure = EventFailure()
        application.delegate = failure
        let spotify = application as PreviewSpotifyControlApplication
        let budget = PlaybackReadBudget(deadline: request.deadline)
        func perform<T>(_ stage: PlaybackControlDiagnostics.Stage, validate: (T) throws -> Void = { _ in },
                        _ action: () -> T?) throws -> T {
            try measure(request, diagnostics: diagnostics, stage: stage) {
                do { application.timeout = try budget.timeoutTicks(maximum: 60) }
                catch { throw PlaybackControlFailure.expired }
                failure.code = nil
                let value = action()
                if let code = failure.code { throw PlaybackControlFailure.event(code) }
                guard let value else { throw PlaybackControlFailure.unsupported }
                try validate(value)
                return value
            }
        }
        func confirmTrack(_ stage: PlaybackControlDiagnostics.Stage = .trackValidation) throws {
            let _: String = try perform(stage, validate: { id in
                guard id == request.trackID else { throw PlaybackControlFailure.trackChanged }
            }) { spotify.currentTrack?.spotifyUrl }
        }
        try confirmTrack()
        switch request.command {
        case .previousTrack: let _: Void = try perform(.command) { spotify.previousTrack?() }
        case .nextTrack: let _: Void = try perform(.command) { spotify.nextTrack?() }
        case .togglePlayback: let _: Void = try perform(.command) { spotify.playpause?() }
        case .backward10, .forward10:
            let position = try perform(.positionRead) { spotify.playerPosition }
            let duration = try perform(.durationRead) { spotify.currentTrack?.duration }
            let target = try request.command.seekTarget(position: position, duration: Double(duration) / 1000)
            try confirmTrack(.seekValidation)
            let _: Void = try perform(.command) { spotify.setPlayerPosition?(target) }
        }
    }
}
