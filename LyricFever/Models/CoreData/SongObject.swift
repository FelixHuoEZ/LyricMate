//
//  SongObject+CoreDataClass.swift
//  SpotifyLyricsInMenubar
//
//  Created by Avi Wadhwa on 06/08/23.
//
//

import Foundation
import CoreData

@objc(SongObject)
public class SongObject: NSManagedObject {
    enum CodingKeys: String, CodingKey {
        case lines, language, syncType
    }

    convenience init(from LocalLyrics: [LyricLine], with context: NSManagedObjectContext, trackID: String, trackName: String) {
        self.init(context: context)
        self.id = trackID
        self.title = trackName
        self.downloadDate = Date.now
        self.language = ""
        if !LocalLyrics.isEmpty {
            self.lyricsTimestamps = LocalLyrics.map {$0.startTimeMS}
            self.lyricsWords = LocalLyrics.map {$0.words}
        } else {
            self.lyricsTimestamps = []
            self.lyricsWords = []
        }

    }

    @MainActor
    static func cache(_ lyrics: [LyricLine], in context: NSManagedObjectContext, trackID: String, trackName: String) throws {
        let request = fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", trackID)
        let existing = try context.fetch(request)
        let song = existing.first ?? SongObject(from: lyrics, with: context, trackID: trackID, trackName: trackName)
        song.title = trackName
        song.downloadDate = Date.now
        song.lyricsTimestamps = lyrics.map(\.startTimeMS)
        song.lyricsWords = lyrics.map(\.words)
        // Older refreshes inserted duplicate rows; keep one current record for this player ID.
        for duplicate in existing.dropFirst() { context.delete(duplicate) }
    }
}
