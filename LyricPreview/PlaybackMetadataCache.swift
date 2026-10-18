import Foundation

struct PlaybackMetadataCache<Value> {
    private var entry: (processID: Int32, launchDate: Date?, trackID: String, value: Value, storedAt: ContinuousClock.Instant)?
    private let lifetime: Duration = .seconds(30)

    func value(processID: Int32, launchDate: Date? = nil, trackID: String, at now: ContinuousClock.Instant = .now) -> Value? {
        guard let entry, entry.processID == processID, entry.launchDate == launchDate, entry.trackID == trackID,
              now >= entry.storedAt, now < entry.storedAt.advanced(by: lifetime) else { return nil }
        return entry.value
    }

    mutating func store(_ value: Value, processID: Int32, launchDate: Date? = nil, trackID: String, at now: ContinuousClock.Instant = .now) {
        entry = (processID, launchDate, trackID, value, now)
    }

    mutating func reset() { entry = nil }
}
