import Foundation
import Photos
import SwiftData

/// One-time translation of v1 metadata into the v2 review/post model.
///
/// v1 stored three things: an `isIgnored` flag, an `isPosted` flag, and a set of Apple Photos
/// albums designated as "Posting Albums" (whose membership produced a derived `Selected` state).
/// v2 has no global posted flag and no Selected state, so:
///
/// - `isIgnored`  → `ReviewState.ignored`
/// - `isPosted`   → `ReviewState.keep` plus `legacyPostedAt`. The old flag carried no platform, so
///                  it is recorded as "used, platform unknown" rather than fabricating an
///                  Instagram or LinkedIn publication.
/// - Posting Album membership → `ReviewState.keep`, since those photos had been curated as
///                  good-for-posting. Album rows are left in place and nothing in Apple Photos is
///                  touched.
///
/// Legacy rows are never deleted, so the migration can be re-derived if needed.
struct LegacyMigrationSummary: Equatable {
    var ignoredCount = 0
    var previouslyPostedCount = 0
    var postingAlbumKeeperCount = 0
    var postingAlbumTitles: [String] = []

    var didChangeAnything: Bool {
        ignoredCount > 0 || previouslyPostedCount > 0 || postingAlbumKeeperCount > 0
    }
}

enum LegacyMigrator {
    private static let completedKey = "unposted.legacyMigrationCompleted.v2"
    private static let summaryKey = "unposted.legacyMigrationSummary.v2"

    static var hasCompleted: Bool {
        UserDefaults.standard.bool(forKey: completedKey)
    }

    /// Summary of the last migration, kept so the one-time notice survives a relaunch.
    static var storedSummary: LegacyMigrationSummary? {
        guard let data = UserDefaults.standard.data(forKey: summaryKey),
              let decoded = try? JSONDecoder().decode(StoredSummary.self, from: data)
        else { return nil }
        return decoded.summary
    }

    static func clearStoredSummary() {
        UserDefaults.standard.removeObject(forKey: summaryKey)
    }

    /// Resets the completion flag so a fresh store is migrated again on next launch.
    static func resetCompletionFlag() {
        UserDefaults.standard.removeObject(forKey: completedKey)
        clearStoredSummary()
    }

    /// Runs the migration if it has not run before. Returns a summary when something was migrated.
    @discardableResult
    @MainActor
    static func runIfNeeded(
        context: ModelContext,
        postingAlbumMembership: (Set<String>) -> Set<String>
    ) -> LegacyMigrationSummary? {
        guard !hasCompleted else { return nil }

        var summary = LegacyMigrationSummary()

        let legacyPhotos = (try? context.fetch(FetchDescriptor<PhotoMetadata>())) ?? []
        let legacyAlbums = (try? context.fetch(FetchDescriptor<PostingAlbum>())) ?? []

        // Index existing v2 records so a partially-migrated store converges instead of duplicating.
        var records: [String: PhotoRecord] = [:]
        for record in (try? context.fetch(FetchDescriptor<PhotoRecord>())) ?? [] {
            records[record.assetIdentifier] = record
        }

        func record(for id: String) -> PhotoRecord {
            if let existing = records[id] { return existing }
            let created = PhotoRecord(assetIdentifier: id)
            context.insert(created)
            records[id] = created
            return created
        }

        for legacy in legacyPhotos {
            // `isPosted` wins: v1 cleared `isIgnored` whenever it set `isPosted`.
            if legacy.isPosted {
                let target = record(for: legacy.assetIdentifier)
                if target.reviewState == .undecided { target.reviewState = .keep }
                if target.legacyPostedAt == nil {
                    target.legacyPostedAt = legacy.postedAt ?? legacy.updatedAt
                }
                target.reviewedAt = target.reviewedAt ?? legacy.updatedAt
                target.updatedAt = .now
                summary.previouslyPostedCount += 1
            } else if legacy.isIgnored {
                let target = record(for: legacy.assetIdentifier)
                if target.reviewState == .undecided { target.reviewState = .ignored }
                target.reviewedAt = target.reviewedAt ?? legacy.updatedAt
                target.updatedAt = .now
                summary.ignoredCount += 1
            }
        }

        // Posting Album membership becomes an explicit keep decision.
        if !legacyAlbums.isEmpty {
            summary.postingAlbumTitles = legacyAlbums.map(\.title).sorted()
            let memberIDs = postingAlbumMembership(Set(legacyAlbums.map(\.localIdentifier)))
            for id in memberIDs {
                let target = record(for: id)
                guard target.reviewState == .undecided else { continue }
                target.reviewState = .keep
                target.reviewedAt = target.reviewedAt ?? .now
                target.updatedAt = .now
                summary.postingAlbumKeeperCount += 1
            }
        }

        do {
            try context.save()
        } catch {
            // Leave the flag unset so the migration is retried rather than silently skipped.
            return nil
        }

        UserDefaults.standard.set(true, forKey: completedKey)
        if summary.didChangeAnything || !summary.postingAlbumTitles.isEmpty {
            if let data = try? JSONEncoder().encode(StoredSummary(summary: summary)) {
                UserDefaults.standard.set(data, forKey: summaryKey)
            }
            return summary
        }
        return nil
    }

    private struct StoredSummary: Codable {
        var ignoredCount: Int
        var previouslyPostedCount: Int
        var postingAlbumKeeperCount: Int
        var postingAlbumTitles: [String]

        init(summary: LegacyMigrationSummary) {
            ignoredCount = summary.ignoredCount
            previouslyPostedCount = summary.previouslyPostedCount
            postingAlbumKeeperCount = summary.postingAlbumKeeperCount
            postingAlbumTitles = summary.postingAlbumTitles
        }

        var summary: LegacyMigrationSummary {
            var result = LegacyMigrationSummary()
            result.ignoredCount = ignoredCount
            result.previouslyPostedCount = previouslyPostedCount
            result.postingAlbumKeeperCount = postingAlbumKeeperCount
            result.postingAlbumTitles = postingAlbumTitles
            return result
        }
    }
}
