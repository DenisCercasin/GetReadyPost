import Foundation
import SwiftData
import SwiftUI

// MARK: - Platforms

/// The places the user publishes by hand. Usage is tracked per platform, never globally.
enum Platform: String, Codable, CaseIterable, Identifiable, Hashable {
    case instagram
    case linkedIn

    var id: String { rawValue }

    var title: String {
        switch self {
        case .instagram: "Instagram"
        case .linkedIn: "LinkedIn"
        }
    }

    var symbolName: String {
        switch self {
        case .instagram: "camera"
        case .linkedIn: "briefcase"
        }
    }

    var tint: Color {
        switch self {
        case .instagram: .pink
        case .linkedIn: .blue
        }
    }
}

// MARK: - Review state

/// The decision the user made while reviewing a photo. Mutually exclusive by design:
/// a photo is either undecided, a keeper, deliberately ignored, or queued for deletion.
enum ReviewState: String, Codable, CaseIterable, Identifiable, Hashable {
    /// Never reviewed, or explicitly skipped for now.
    case undecided
    /// Good enough to post. This is the pool posts draw from.
    case keep
    /// Worth retaining in Apple Photos, but never to be posted.
    case ignored
    /// Collected for a batch delete from Apple Photos.
    case deletionQueue

    var id: String { rawValue }

    var title: String {
        switch self {
        case .undecided: "Needs review"
        case .keep: "Keeper"
        case .ignored: "Ignored"
        case .deletionQueue: "Queued for deletion"
        }
    }

    var symbolName: String {
        switch self {
        case .undecided: "circle.dashed"
        case .keep: "checkmark.circle.fill"
        case .ignored: "eye.slash.fill"
        case .deletionQueue: "trash.fill"
        }
    }
}

// MARK: - Photo workflow metadata

/// Local-only workflow metadata for one `PHAsset`. The asset itself always stays in Apple Photos.
@Model final class PhotoRecord {
    @Attribute(.unique) var assetIdentifier: String
    private var reviewStateRaw: String
    var reviewedAt: Date?
    /// Set during migration for photos the previous version had flagged `Posted`.
    /// The old flag had no platform, so this records "used, platform unknown" instead of
    /// inventing an Instagram or LinkedIn publication.
    var legacyPostedAt: Date?
    var createdAt: Date
    var updatedAt: Date

    var reviewState: ReviewState {
        get { ReviewState(rawValue: reviewStateRaw) ?? .undecided }
        set { reviewStateRaw = newValue.rawValue }
    }

    init(
        assetIdentifier: String,
        reviewState: ReviewState = .undecided,
        reviewedAt: Date? = nil,
        legacyPostedAt: Date? = nil
    ) {
        self.assetIdentifier = assetIdentifier
        self.reviewStateRaw = reviewState.rawValue
        self.reviewedAt = reviewedAt
        self.legacyPostedAt = legacyPostedAt
        self.createdAt = .now
        self.updatedAt = .now
    }
}

// MARK: - Posts

/// Lifecycle of a draft post. `published` is derived from the per-platform dates rather than stored,
/// so the two can never disagree.
enum PostStatus: String, Codable, CaseIterable, Identifiable, Hashable {
    case draft
    case ready
    case partiallyPublished
    case published

    var id: String { rawValue }

    var title: String {
        switch self {
        case .draft: "Draft"
        case .ready: "Ready to Post"
        case .partiallyPublished: "Partly Published"
        case .published: "Published"
        }
    }

    var symbolName: String {
        switch self {
        case .draft: "pencil.circle"
        case .ready: "paperplane.circle"
        case .partiallyPublished: "circle.lefthalf.filled"
        case .published: "checkmark.seal.fill"
        }
    }
}

/// A post the user assembles here and publishes by hand elsewhere.
///
/// Photos are held as an ordered list of `PHAsset.localIdentifier`s rather than a SwiftData
/// relationship: ordering comes for free, removing a photo can never cascade into the photo's own
/// metadata, and a photo stays available for other posts.
@Model final class Post {
    @Attribute(.unique) var identifier: UUID
    var title: String
    var caption: String
    var assetIdentifiers: [String]
    private var destinationRaws: [String]
    /// User-set readiness. Publication state is derived from the dates below.
    var isMarkedReady: Bool
    var instagramPublishedAt: Date?
    var linkedInPublishedAt: Date?
    var createdAt: Date
    var updatedAt: Date

    init(
        identifier: UUID = UUID(),
        title: String = "",
        caption: String = "",
        assetIdentifiers: [String] = [],
        destinations: Set<Platform> = [],
        isMarkedReady: Bool = false
    ) {
        self.identifier = identifier
        self.title = title
        self.caption = caption
        self.assetIdentifiers = assetIdentifiers
        self.destinationRaws = destinations.map(\.rawValue).sorted()
        self.isMarkedReady = isMarkedReady
        self.instagramPublishedAt = nil
        self.linkedInPublishedAt = nil
        self.createdAt = .now
        self.updatedAt = .now
    }

    // MARK: Destinations

    var destinations: Set<Platform> {
        get { Set(destinationRaws.compactMap(Platform.init(rawValue:))) }
        set { destinationRaws = newValue.map(\.rawValue).sorted() }
    }

    /// Destinations in a stable display order.
    var orderedDestinations: [Platform] {
        Platform.allCases.filter { destinations.contains($0) }
    }

    func publishedAt(_ platform: Platform) -> Date? {
        switch platform {
        case .instagram: instagramPublishedAt
        case .linkedIn: linkedInPublishedAt
        }
    }

    func setPublished(_ platform: Platform, at date: Date?) {
        switch platform {
        case .instagram: instagramPublishedAt = date
        case .linkedIn: linkedInPublishedAt = date
        }
        updatedAt = .now
    }

    func isPublished(on platform: Platform) -> Bool {
        publishedAt(platform) != nil
    }

    /// Platforms this post has actually gone out on. A platform can be published even if it was
    /// later dropped from `destinations`, so publication is read from the dates directly.
    var publishedPlatforms: Set<Platform> {
        Set(Platform.allCases.filter { isPublished(on: $0) })
    }

    /// Chosen destinations still waiting to be published.
    var pendingPlatforms: [Platform] {
        orderedDestinations.filter { !isPublished(on: $0) }
    }

    // MARK: Status

    var status: PostStatus {
        let published = publishedPlatforms
        if !published.isEmpty {
            return pendingPlatforms.isEmpty ? .published : .partiallyPublished
        }
        return isMarkedReady ? .ready : .draft
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let firstCaptionLine = caption
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if !firstCaptionLine.isEmpty { return String(firstCaptionLine.prefix(60)) }
        return "Untitled Post"
    }

    /// Sort key that keeps the most recently relevant post on top of its section.
    var sortDate: Date {
        publishedPlatforms
            .compactMap { publishedAt($0) }
            .max() ?? updatedAt
    }

    // MARK: Photo membership

    func contains(_ assetIdentifier: String) -> Bool {
        assetIdentifiers.contains(assetIdentifier)
    }

    /// Appends only identifiers not already present, preserving the caller's order.
    func append(_ identifiers: [String]) {
        for id in identifiers where !assetIdentifiers.contains(id) {
            assetIdentifiers.append(id)
        }
        updatedAt = .now
    }

    func remove(_ identifiers: Set<String>) {
        assetIdentifiers.removeAll { identifiers.contains($0) }
        updatedAt = .now
    }
}

// MARK: - Legacy models (v1)

/// v1 metadata, kept in the schema so an existing store still opens and can be migrated.
/// Read by `LegacyMigrator` and never written again.
@Model final class PhotoMetadata {
    @Attribute(.unique) var assetIdentifier: String
    var isPosted: Bool
    var isIgnored: Bool
    var postedAt: Date?
    var createdAt: Date
    var updatedAt: Date

    init(assetIdentifier: String, isPosted: Bool = false, isIgnored: Bool = false, postedAt: Date? = nil) {
        self.assetIdentifier = assetIdentifier
        self.isPosted = isPosted
        self.isIgnored = isIgnored
        self.postedAt = postedAt
        self.createdAt = .now
        self.updatedAt = .now
    }
}

/// v1 "Posting Album" designation. v2 derives the posting pool from review decisions instead,
/// so these rows exist only as migration input and as a record of what the user had designated.
@Model final class PostingAlbum {
    @Attribute(.unique) var localIdentifier: String
    var title: String
    var createdAt: Date

    init(localIdentifier: String, title: String) {
        self.localIdentifier = localIdentifier
        self.title = title
        self.createdAt = .now
    }
}

// MARK: - Schema

enum AppSchema {
    static let models: [any PersistentModel.Type] = [
        PhotoRecord.self,
        Post.self,
        PhotoMetadata.self,
        PostingAlbum.self,
    ]
}
