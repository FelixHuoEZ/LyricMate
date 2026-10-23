import AppKit
import CoreServices
import Observation
import SwiftUI

// Separate test identities ask only for permission; no Apple event is sent.
@MainActor
@Observable
private final class PermissionProbe {
    struct Report: Codable {
        let bundleIdentifier: String
        let initialStatus: Int32
        let requestedStatus: Int32
        let recheckedStatus: Int32
        let passed: Bool
    }
    let expected: Int32
    let workspace: URL
    var status = "Ready. No song reads or playback commands."
    var running = false
    var finished = false

    init() {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--workspace"), args.indices.contains(index + 1),
              let identifier = Bundle.main.bundleIdentifier,
              ["local.lyricmate.alpha.acceptance.permission.denied",
               "local.lyricmate.alpha.acceptance.permission.allowed"].contains(identifier) else {
            fatalError("Use a dedicated permission acceptance bundle and temporary workspace")
        }
        expected = args.contains("--expect-denied") || identifier.hasSuffix(".denied") ? -1743 : 0
        let root = URL(fileURLWithPath: args[index + 1], isDirectory: true).resolvingSymlinksInPath()
        let parents = [FileManager.default.temporaryDirectory,
                       URL(fileURLWithPath: "/private/tmp", isDirectory: true)].map { $0.resolvingSymlinksInPath().path }
        guard root.lastPathComponent.hasPrefix("lyricmate-alpha-acceptance."),
              root.lastPathComponent.count < 100,
              parents.contains(root.deletingLastPathComponent().path) else {
            fatalError("Permission reports must use a dedicated temporary directory")
        }
        workspace = root
    }

    func run() async {
        guard !running, !finished else { return }
        guard let process = NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").first,
              !process.isTerminated else {
            status = "Spotify is not running. The test will not launch it."; return
        }
        let pid = process.processIdentifier
        running = true
        status = expected == 0 ? "Choose Allow in the system prompt." : "Choose Don't Allow in the system prompt."
        let result = await Task.detached(priority: .userInitiated) {
            let target = NSAppleEventDescriptor(processIdentifier: pid)
            let initial = AEDeterminePermissionToAutomateTarget(target.aeDesc, AEEventClass(kAECoreSuite), AEEventID(kAEGetData), false)
            // A reused identity must not change an existing permission or trigger another request.
            let requested = initial == -1744 ?
                AEDeterminePermissionToAutomateTarget(target.aeDesc, AEEventClass(kAECoreSuite), AEEventID(kAEGetData), true) : initial
            let rechecked = AEDeterminePermissionToAutomateTarget(target.aeDesc, AEEventClass(kAECoreSuite), AEEventID(kAEGetData), false)
            return (initial, requested, rechecked)
        }.value
        let report = Report(bundleIdentifier: Bundle.main.bundleIdentifier!, initialStatus: result.0,
                            requestedStatus: result.1, recheckedStatus: result.2,
                            passed: result.0 == -1744 && result.1 == expected && result.2 == expected)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(report)
            try data.write(to: workspace.appendingPathComponent(expected == 0 ? "permission-allowed.json" : "permission-denied.json"), options: .atomic)
            status = "Initial \(result.0); request \(result.1); recheck \(result.2). \(report.passed ? "Passed" : "Not passed")"
        } catch { status = "Could not save the permission report." }
        finished = true; running = false
    }
}

@main
struct PermissionProbeApp: App {
    @State private var probe = PermissionProbe()
    var body: some Scene {
        Window("LyricMate Permission Acceptance", id: "permission") {
            VStack(alignment: .leading, spacing: 16) {
                Text(verbatim: Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Permission test")
                    .font(.title2)
                Text("Only macOS permission preflight. No songs, network requests or playback commands.")
                Text(verbatim: probe.status).textSelection(.enabled)
                Button("Request isolated permission") { Task { await probe.run() } }
                    .disabled(probe.running || probe.finished)
                Button("Quit permission test") { NSApp.terminate(nil) }.disabled(probe.running)
            }.padding(24).frame(width: 540)
        }.defaultSize(width: 600, height: 250)
    }
}
