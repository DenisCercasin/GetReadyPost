import Foundation
import Photos
import SwiftData
import SwiftUI

/// How a single photo has been used, derived entirely from posts. There is no global "posted"
/// flag: a photo published on Instagram is still unused as far as LinkedIn is concerned.
struct PhotoUsage: Equatable {
    var publishedPlatforms: Set<Platform> = []
    /// Platforms a post plans to publish this photo on but hasn't yet.
    var plannedPlatforms: Set<Platform> = []
    var postIdentifiers: [UUID] = []

    var isInAnyPost: Bool { !postIdentifiers.isEmpty }
    var isPublishedAnywhere: Bool { !publishedPlatforms.isEmpty }
}

/// A reversible batch of review decisions.
struct ReviewUndoAction: Identifiable, Equatable {
    let id = UUID()
    let label: String
    /// Identifier → state the photo had before the action.
    let previousStates: [String: ReviewState]

    var count: Int { previousStates.count }
}

/// Single owner of all workflow metadata: review decisions, posts, and the derived usage index.
@MainActor
final class WorkflowStore: ObservableObject {
    /// Bumped on every mutation so views recompute derived lists.
    @Published private(set) var revision = 0
    @Published private(set) var posts: [Post] = []
    @Published private(set) var undoAction: ReviewUndoAction?
    @Published var migrationSummary: LegacyMigrationSummary?
    @Published var errorMessage: String?

    private(set) var records: [String: PhotoRecord] = [:]
    private(set) var usage: [String: PhotoUsage] = [:]

    private var context: ModelContext?
    private var undoDismissTask: Task<Void, Never>?
    private unowned let library: PhotoLibraryService

    init(library: PhotoLibraryService) {
        self.library = library
    }

    // MARK: - Setup

    func configure(context: ModelContext) {
        guard self.context == nil else { return }
        self.context = context
        reloadFromStore()
        runMigrationIfNeeded()
    }

    private func runMigrationIfNeeded() {
        guard let context else { return }
        let summary = LegacyMigrator.runIfNeeded(context: context) { [weak self] albumIDs in
            guard let self else { return [] }
            var ids = Set<String>()
            for albumID in albumIDs {
                ids.formUnion(self.library.assetIdentifiers(inAlbum: albumID))
            }
            return ids
        }
        if let summary {
            reloadFromStore()
            migrationSummary = summary
        }
    }

    /// Re-runs the legacy migration once the Photos index is available, so Posting Album
    /// membership can be resolved. Harmless when the migration already completed.
    func retryMigrationIfPending() {
        guard !LegacyMigrator.hasCompleted else { return }
        runMigrationIfNeeded()
    }

    func reloadFromStore() {
        guard let context else { return }
        let fetchedRecords = (try? context.fetch(FetchDescriptor<PhotoRecord>())) ?? []
        records = Dictionary(fetchedRecords.map { ($0.assetIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
        posts = ((try? context.fetch(FetchDescriptor<Post>())) ?? []).sorted { $0.sortDate > $1.sortDate }
        rebuildUsage()
        revision += 1
    }

    private func save() {
        guard let context else { return }
        do {
            try context.save()
        } catch {
            errorMessage = "Couldn't save your changes. \(error.localizedDescription)"
        }
    }

    // MARK: - Usage index

    private func rebuildUsage() {
        var index: [String: PhotoUsage] = [:]
        for post in posts {
            let published = post.publishedPlatforms
            let planned = Set(post.pendingPlatforms)
            for identifier in post.assetIdentifiers {
                var entry = index[identifier] ?? PhotoUsage()
                entry.publishedPlatforms.formUnion(published)
                entry.plannedPlatforms.formUnion(planned)
                entry.postIdentifiers.append(post.identifier)
                index[identifier] = entry
            }
        }
        usage = index
    }

    func usage(for identifier: String) -> PhotoUsage {
        usage[identifier] ?? PhotoUsage()
    }

    func reviewState(for identifier: String) -> ReviewState {
        records[identifier]?.reviewState ?? .undecided
    }

    func record(for identifier: String) -> PhotoRecord? {
        records[identifier]
    }

    /// True when the previous version had flagged this photo as posted (platform unknown).
    func wasPreviouslyPosted(_ identifier: String) -> Bool {
        records[identifier]?.legacyPostedAt != nil
    }

    var hasPreviouslyPostedPhotos: Bool {
        records.values.contains { $0.legacyPostedAt != nil }
    }

    /// Posts referencing a photo, newest first.
    func posts(containing identifier: String) -> [Post] {
        posts.filter { $0.contains(identifier) }
    }

    // MARK: - Review decisions

    @discardableResult
    func apply(_ state: ReviewState, to identifiers: [String], undoLabel: String? = nil) -> Int {
        guard let context, !identifiers.isEmpty else { return 0 }
        var previous: [String: ReviewState] = [:]

        for identifier in identifiers {
            let existing = records[identifier]
            previous[identifier] = existing?.reviewState ?? .undecided
            let target: PhotoRecord
            if let existing {
                target = existing
            } else {
                target = PhotoRecord(assetIdentifier: identifier)
                context.insert(target)
                records[identifier] = target
            }
            target.reviewState = state
            target.reviewedAt = state == .undecided ? nil : .now
            target.updatedAt = .now
        }
        save()
        revision += 1
        registerUndo(label: undoLabel ?? defaultUndoLabel(for: state, count: identifiers.count), previous: previous)
        return identifiers.count
    }

    private func defaultUndoLabel(for state: ReviewState, count: Int) -> String {
        let noun = count == 1 ? "photo" : "\(count) photos"
        switch state {
        case .keep: return "Kept \(noun)"
        case .ignored: return "Ignored \(noun)"
        case .deletionQueue: return "Queued \(noun)"
        case .undecided: return "Cleared \(noun)"
        }
    }

    // MARK: - Undo

    private func registerUndo(label: String, previous: [String: ReviewState]) {
        guard !previous.isEmpty else { return }
        undoAction = ReviewUndoAction(label: label, previousStates: previous)
        undoDismissTask?.cancel()
        let token = undoAction?.id
        undoDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, self.undoAction?.id == token else { return }
            self.undoAction = nil
        }
    }

    func performUndo() {
        guard let action = undoAction, let context else { return }
        for (identifier, state) in action.previousStates {
            guard let record = records[identifier] else { continue }
            record.reviewState = state
            record.reviewedAt = state == .undecided ? nil : record.reviewedAt
            record.updatedAt = .now
        }
        // Records created purely by the undone action carry no information; drop them.
        for (identifier, state) in action.previousStates where state == .undecided {
            if let record = records[identifier], record.legacyPostedAt == nil {
                context.delete(record)
                records[identifier] = nil
            }
        }
        save()
        undoAction = nil
        undoDismissTask?.cancel()
        revision += 1
    }

    func dismissUndo() {
        undoAction = nil
        undoDismissTask?.cancel()
    }

    // MARK: - Filtering

    /// Identifiers in the deletion queue, newest capture first.
    func deletionQueueIdentifiers() -> [String] {
        let queued = Set(records.values.filter { $0.reviewState == .deletionQueue }.map(\.assetIdentifier))
        guard !queued.isEmpty else { return [] }
        return library.assets.map(\.localIdentifier).filter { queued.contains($0) }
    }

    var deletionQueueCount: Int {
        records.values.reduce(into: 0) { total, record in
            if record.reviewState == .deletionQueue { total += 1 }
        }
    }

    func matches(_ identifier: String, scope: GalleryScope) -> Bool {
        let state = reviewState(for: identifier)
        let use = usage(for: identifier)
        let legacyPosted = wasPreviouslyPosted(identifier)

        switch scope {
        case .allPhotos:
            return true
        case .needsReview:
            return state == .undecided
        case .keepers:
            return state == .keep
        case .availableToPost:
            return state == .keep && !use.isPublishedAnywhere && !legacyPosted
        case .unusedOnInstagram:
            return state == .keep && !use.publishedPlatforms.contains(.instagram) && !legacyPosted
        case .unusedOnLinkedIn:
            return state == .keep && !use.publishedPlatforms.contains(.linkedIn) && !legacyPosted
        case .usedOnInstagram:
            return use.publishedPlatforms.contains(.instagram)
        case .usedOnLinkedIn:
            return use.publishedPlatforms.contains(.linkedIn)
        case .previouslyPosted:
            return legacyPosted
        case .ignored:
            return state == .ignored
        case .deletionQueue:
            return state == .deletionQueue
        }
    }

    func assets(_ assets: [PHAsset], in scope: GalleryScope) -> [PHAsset] {
        guard scope != .allPhotos else { return assets }
        return assets.filter { matches($0.localIdentifier, scope: scope) }
    }

    func count(for scope: GalleryScope, in assets: [PHAsset]) -> Int {
        guard scope != .allPhotos else { return assets.count }
        return assets.reduce(into: 0) { total, asset in
            if matches(asset.localIdentifier, scope: scope) { total += 1 }
        }
    }

    /// Photos a post can draw from: keepers and not-yet-reviewed photos, never ignored or queued.
    func isEligibleForPosts(_ identifier: String) -> Bool {
        let state = reviewState(for: identifier)
        return state == .keep || state == .undecided
    }

    // MARK: - Posts

    @discardableResult
    func createPost(assetIdentifiers: [String] = [], title: String = "", destinations: Set<Platform> = []) -> Post? {
        guard let context else { return nil }
        let post = Post(title: title, assetIdentifiers: assetIdentifiers, destinations: destinations)
        context.insert(post)
        // Photos put into a post are implicitly keepers.
        let needsKeep = assetIdentifiers.filter { reviewState(for: $0) == .undecided }
        if !needsKeep.isEmpty {
            for identifier in needsKeep {
                let record = records[identifier] ?? {
                    let created = PhotoRecord(assetIdentifier: identifier)
                    context.insert(created)
                    records[identifier] = created
                    return created
                }()
                record.reviewState = .keep
                record.reviewedAt = .now
                record.updatedAt = .now
            }
        }
        save()
        reloadFromStore()
        return posts.first { $0.identifier == post.identifier }
    }

    func delete(_ post: Post) {
        guard let context else { return }
        context.delete(post)
        save()
        reloadFromStore()
    }

    /// Adds photos to a post. Photos stay available for other posts.
    func addPhotos(_ identifiers: [String], to post: Post) {
        guard let context else { return }
        post.append(identifiers)
        for identifier in identifiers where reviewState(for: identifier) == .undecided {
            let record = records[identifier] ?? {
                let created = PhotoRecord(assetIdentifier: identifier)
                context.insert(created)
                records[identifier] = created
                return created
            }()
            record.reviewState = .keep
            record.reviewedAt = .now
            record.updatedAt = .now
        }
        commitPostChange()
    }

    /// Removing a photo from a post only drops the reference. The photo keeps its keeper state and
    /// becomes available again for a future post.
    func removePhotos(_ identifiers: Set<String>, from post: Post) {
        post.remove(identifiers)
        commitPostChange()
    }

    func reorderPhotos(in post: Post, to identifiers: [String]) {
        post.assetIdentifiers = identifiers
        post.updatedAt = .now
        commitPostChange()
    }

    func movePhotos(in post: Post, fromOffsets source: IndexSet, toOffset destination: Int) {
        var identifiers = post.assetIdentifiers
        identifiers.move(fromOffsets: source, toOffset: destination)
        reorderPhotos(in: post, to: identifiers)
    }

    func update(_ post: Post, title: String? = nil, caption: String? = nil) {
        if let title { post.title = title }
        if let caption { post.caption = caption }
        post.updatedAt = .now
        commitPostChange()
    }

    func setDestination(_ platform: Platform, enabled: Bool, on post: Post) {
        var destinations = post.destinations
        if enabled {
            destinations.insert(platform)
        } else {
            destinations.remove(platform)
            // Dropping a destination also clears its publication; otherwise usage would claim a
            // publication the user has walked back.
            post.setPublished(platform, at: nil)
        }
        post.destinations = destinations
        post.updatedAt = .now
        commitPostChange()
    }

    func setReady(_ isReady: Bool, on post: Post) {
        post.isMarkedReady = isReady
        post.updatedAt = .now
        commitPostChange()
    }

    /// Marks one destination published. The other destination is untouched, so a post going to
    /// both platforms can be published on each at a different time.
    func markPublished(_ post: Post, platform: Platform, at date: Date = .now) {
        if !post.destinations.contains(platform) {
            post.destinations = post.destinations.union([platform])
        }
        post.setPublished(platform, at: date)
        commitPostChange()
    }

    func clearPublished(_ post: Post, platform: Platform) {
        post.setPublished(platform, at: nil)
        commitPostChange()
    }

    private func commitPostChange() {
        save()
        posts.sort { $0.sortDate > $1.sortDate }
        rebuildUsage()
        revision += 1
    }

    var postsByStatus: [(status: PostStatus, posts: [Post])] {
        let order: [PostStatus] = [.draft, .ready, .partiallyPublished, .published]
        return order.compactMap { status in
            let matching = posts.filter { $0.status == status }
            return matching.isEmpty ? nil : (status, matching)
        }
    }

    // MARK: - Deleted and missing assets

    /// Called after a successful batch delete: drops the metadata and cleans unpublished posts.
    func handleAssetsDeleted(_ identifiers: [String]) {
        guard let context, !identifiers.isEmpty else { return }
        let set = Set(identifiers)
        for identifier in identifiers {
            if let record = records[identifier] {
                context.delete(record)
                records[identifier] = nil
            }
        }
        // Published posts keep their references as a record of what went out; drafts don't.
        for post in posts where post.publishedPlatforms.isEmpty {
            if post.assetIdentifiers.contains(where: set.contains) {
                post.remove(set)
            }
        }
        save()
        reloadFromStore()
        dismissUndo()
    }

    /// Identifiers with metadata whose asset is gone from Apple Photos.
    func missingMetadataIdentifiers() -> [String] {
        let tracked = Array(records.keys)
        guard !tracked.isEmpty else { return [] }
        return library.missingIdentifiers(from: tracked)
    }

    func purgeMetadata(for identifiers: [String]) {
        handleAssetsDeleted(identifiers)
    }

    // MARK: - Backup

    func exportBackup() -> Data? {
        let photos = records.values
            .filter { $0.reviewState != .undecided || $0.legacyPostedAt != nil }
            .map {
                BackupDocument.Photo(
                    assetIdentifier: $0.assetIdentifier,
                    reviewState: $0.reviewState.rawValue,
                    reviewedAt: $0.reviewedAt,
                    legacyPostedAt: $0.legacyPostedAt
                )
            }
            .sorted { $0.assetIdentifier < $1.assetIdentifier }

        let postEntries = posts.map {
            BackupDocument.PostEntry(
                identifier: $0.identifier,
                title: $0.title,
                caption: $0.caption,
                assetIdentifiers: $0.assetIdentifiers,
                destinations: $0.destinations.map(\.rawValue).sorted(),
                isMarkedReady: $0.isMarkedReady,
                instagramPublishedAt: $0.instagramPublishedAt,
                linkedInPublishedAt: $0.linkedInPublishedAt,
                createdAt: $0.createdAt,
                updatedAt: $0.updatedAt
            )
        }

        let document = BackupDocument(
            version: BackupDocument.currentVersion,
            exportedAt: .now,
            photos: photos,
            posts: postEntries,
            postingAlbums: nil
        )
        do {
            return try BackupDocument.encoder.encode(document)
        } catch {
            errorMessage = "Couldn't build the backup. \(error.localizedDescription)"
            return nil
        }
    }

    /// Merges a backup into the current store. Existing posts with the same identifier are updated
    /// rather than duplicated.
    func importBackup(_ data: Data) {
        guard let context else { return }
        do {
            let document = try BackupDocument.decoder.decode(BackupDocument.self, from: data)

            for photo in document.photos {
                let resolved = document.resolvedState(for: photo)
                let record = records[photo.assetIdentifier] ?? {
                    let created = PhotoRecord(assetIdentifier: photo.assetIdentifier)
                    context.insert(created)
                    records[photo.assetIdentifier] = created
                    return created
                }()
                record.reviewState = resolved.state
                record.legacyPostedAt = resolved.legacyPostedAt
                record.reviewedAt = photo.reviewedAt ?? record.reviewedAt
                record.updatedAt = .now
            }

            let existing = Dictionary(posts.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
            for entry in document.posts ?? [] {
                let post = existing[entry.identifier] ?? {
                    let created = Post(identifier: entry.identifier)
                    context.insert(created)
                    return created
                }()
                post.title = entry.title
                post.caption = entry.caption
                post.assetIdentifiers = entry.assetIdentifiers
                post.destinations = Set(entry.destinations.compactMap(Platform.init(rawValue:)))
                post.isMarkedReady = entry.isMarkedReady
                post.instagramPublishedAt = entry.instagramPublishedAt
                post.linkedInPublishedAt = entry.linkedInPublishedAt
                post.updatedAt = .now
            }

            try context.save()
            reloadFromStore()
        } catch {
            errorMessage = "That backup couldn't be read. \(error.localizedDescription)"
        }
    }

    /// Removes all app metadata. Never touches photos or albums in Apple Photos.
    func resetAllData() {
        guard let context else { return }
        for record in records.values { context.delete(record) }
        for post in posts { context.delete(post) }
        for legacy in (try? context.fetch(FetchDescriptor<PhotoMetadata>())) ?? [] { context.delete(legacy) }
        for album in (try? context.fetch(FetchDescriptor<PostingAlbum>())) ?? [] { context.delete(album) }
        save()
        LegacyMigrator.resetCompletionFlag()
        records = [:]
        posts = []
        usage = [:]
        migrationSummary = nil
        dismissUndo()
        reloadFromStore()
    }

    func dismissMigrationNotice() {
        migrationSummary = nil
        LegacyMigrator.clearStoredSummary()
    }

    // MARK: - Summary counts

    /// Answers "which good photos have I still not posted?" for the given platform.
    func unusedKeeperCount(for platform: Platform) -> Int {
        records.values.reduce(into: 0) { total, record in
            guard record.reviewState == .keep, record.legacyPostedAt == nil else { return }
            if !usage(for: record.assetIdentifier).publishedPlatforms.contains(platform) { total += 1 }
        }
    }

    var keeperCount: Int {
        records.values.reduce(into: 0) { total, record in
            if record.reviewState == .keep { total += 1 }
        }
    }
}
