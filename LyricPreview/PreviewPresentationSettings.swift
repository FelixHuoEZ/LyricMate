import Foundation
import Observation

@MainActor
@Observable
final class PreviewPresentationSettings {
    @ObservationIgnored private let defaults: UserDefaults
    var showsFloatingLyrics: Bool { didSet { defaults.set(showsFloatingLyrics, forKey: "presentation.floatingVisible") } }
    var resumesSpotify: Bool { didSet { defaults.set(resumesSpotify, forKey: "startup.resumeSpotify") } }
    var showsMenuLyrics: Bool { didSet { defaults.set(showsMenuLyrics, forKey: "presentation.menuLyrics") } }
    var showsNextLine: Bool { didSet { defaults.set(showsNextLine, forKey: "presentation.nextLine") } }
    var locked: Bool { didSet { defaults.set(locked, forKey: "presentation.locked") } }
    var fontSize: Double {
        didSet {
            let safe = Self.clamp(fontSize, range: 20...48, fallback: 30)
            if fontSize != safe { fontSize = safe }
            defaults.set(safe, forKey: "presentation.fontSize")
        }
    }
    var shadowOpacity: Double {
        didSet {
            let safe = Self.clamp(shadowOpacity, range: 0.35...0.95, fallback: 0.85)
            if shadowOpacity != safe { shadowOpacity = safe }
            defaults.set(safe, forKey: "presentation.shadowOpacity")
        }
    }
    var savedFrame: String? {
        get { defaults.string(forKey: "presentation.frame") }
        set { defaults.set(newValue, forKey: "presentation.frame") }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        showsFloatingLyrics = defaults.bool(forKey: "presentation.floatingVisible")
        resumesSpotify = defaults.bool(forKey: "startup.resumeSpotify")
        showsMenuLyrics = defaults.object(forKey: "presentation.menuLyrics") as? Bool ?? true
        showsNextLine = defaults.object(forKey: "presentation.nextLine") as? Bool ?? true
        locked = defaults.object(forKey: "presentation.locked") as? Bool ?? false
        fontSize = Self.clamp(defaults.object(forKey: "presentation.fontSize") as? Double ?? 30, range: 20...48, fallback: 30)
        shadowOpacity = Self.clamp(defaults.object(forKey: "presentation.shadowOpacity") as? Double ?? 0.85, range: 0.35...0.95, fallback: 0.85)
    }

    private static func clamp(_ value: Double, range: ClosedRange<Double>, fallback: Double) -> Double {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
    }
}
