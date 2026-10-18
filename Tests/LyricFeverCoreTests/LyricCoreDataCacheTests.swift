import CoreData
import XCTest
@testable import LyricFeverCore

@MainActor
final class LyricCoreDataCacheTests: XCTestCase {
    private func context() throws -> NSManagedObjectContext {
        let entity = NSEntityDescription()
        entity.name = "SongObject"
        entity.managedObjectClassName = NSStringFromClass(SongObject.self)
        let fields: [(String, NSAttributeType)] = [
            ("id", .stringAttributeType), ("title", .stringAttributeType), ("language", .stringAttributeType),
            ("downloadDate", .dateAttributeType), ("lyricsWords", .transformableAttributeType), ("lyricsTimestamps", .transformableAttributeType)
        ]
        entity.properties = fields.map { name, type in
            let attribute = NSAttributeDescription()
            attribute.name = name
            attribute.attributeType = type
            if type == .transformableAttributeType {
                attribute.valueTransformerName = NSValueTransformerName.secureUnarchiveFromDataTransformerName.rawValue
            }
            return attribute
        }
        let model = NSManagedObjectModel()
        model.entities = [entity]
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        try coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil)
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        return context
    }

    func testRefreshReplacesLyricsRatherThanInsertingAnotherRecord() async throws {
        let context = try context()
        try SongObject.cache([LyricLine(startTime: 1000, words: "Old")], in: context, trackID: "player-id", trackName: "Song")
        try context.save()
        try SongObject.cache([LyricLine(startTime: 2000, words: "New")], in: context, trackID: "player-id", trackName: "Song")
        try context.save()
        context.reset()
        let stored = try context.fetch(SongObject.fetchRequest())
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.lyricsWords, ["New"])
        XCTAssertEqual(stored.first?.lyricsTimestamps, [2000])
        XCTAssertEqual(stored.first?.id, "player-id")
    }

    func testDuplicateCleanupDoesNotChangeOtherSong() async throws {
        let context = try context()
        for word in ["Old1", "Old2"] { _ = SongObject(from: [LyricLine(startTime: 1000, words: word)], with: context, trackID: "A", trackName: "Song A") }
        _ = SongObject(from: [LyricLine(startTime: 1000, words: "Other")], with: context, trackID: "B", trackName: "Song B")
        try context.save()
        try SongObject.cache([LyricLine(startTime: 2000, words: "Current")], in: context, trackID: "A", trackName: "Song A")
        try context.save()
        let stored = try context.fetch(SongObject.fetchRequest())
        XCTAssertEqual(stored.count, 2)
        XCTAssertEqual(stored.first(where: { $0.id == "A" })?.lyricsWords, ["Current"])
        XCTAssertEqual(stored.first(where: { $0.id == "B" })?.lyricsWords, ["Other"])
    }

    func testRawOffsetSurvivesCacheRoundTripWithoutDisplayFooter() async throws {
        let context = try context()
        let raw = LyricsParser(lyrics: "[offset:-250]\n[00:10]Alpha\n[00:20]Beta").lyrics
        try SongObject.cache(raw, in: context, trackID: "player-id", trackName: "Song")
        try context.save()
        context.reset()
        let stored = try XCTUnwrap(context.fetch(SongObject.fetchRequest()).first)
        XCTAssertEqual(stored.lyricsTimestamps, [9750, 19750])
        XCTAssertEqual(stored.lyricsWords, ["Alpha", "Beta"])
        let restored = zip(stored.lyricsTimestamps, stored.lyricsWords).map { LyricLine(startTime: $0, words: $1) }
        let display = NetworkFetchReturn(lyrics: restored, colorData: nil).processed(withSongName: "Song", duration: 30000)
        XCTAssertEqual(display.lyrics.first?.startTimeMS, 9750)
        XCTAssertEqual(display.lyrics.count, 3)
        XCTAssertEqual(stored.lyricsWords.count, 2)
    }
}
