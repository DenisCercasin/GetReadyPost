import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Export/import payload. Version 2 carries review states and posts; version 1 files written by
/// the previous release are still readable and are folded through the same mapping the in-app
/// migration uses.
struct BackupDocument: Codable {
    static let currentVersion = 2

    struct Photo: Codable {
        var assetIdentifier: String
        var reviewState: String
        var reviewedAt: Date?
        var legacyPostedAt: Date?

        // v1 fields, decoded when present.
        var isPosted: Bool?
        var isIgnored: Bool?
        var postedAt: Date?
    }

    struct PostEntry: Codable {
        var identifier: UUID
        var title: String
        var caption: String
        var assetIdentifiers: [String]
        var destinations: [String]
        var isMarkedReady: Bool
        var instagramPublishedAt: Date?
        var linkedInPublishedAt: Date?
        var createdAt: Date
        var updatedAt: Date
    }

    struct Album: Codable {
        var localIdentifier: String
        var title: String
    }

    var version: Int
    var exportedAt: Date
    var photos: [Photo]
    var posts: [PostEntry]?
    /// Retained so a v1 backup round-trips its Posting Album designations even though v2 no
    /// longer uses them for state.
    var postingAlbums: [Album]?

    // MARK: Normalisation

    /// Review state for a photo entry, mapping v1 flags when the v2 field is absent.
    func resolvedState(for photo: Photo) -> (state: ReviewState, legacyPostedAt: Date?) {
        if version >= 2, let state = ReviewState(rawValue: photo.reviewState) {
            return (state, photo.legacyPostedAt)
        }
        if photo.isIgnored == true { return (.ignored, nil) }
        if photo.isPosted == true { return (.keep, photo.postedAt ?? Date.distantPast) }
        if let state = ReviewState(rawValue: photo.reviewState) { return (state, photo.legacyPostedAt) }
        return (.undecided, photo.legacyPostedAt)
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Wrapper used by `fileExporter` / `fileImporter`.
struct BackupFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
