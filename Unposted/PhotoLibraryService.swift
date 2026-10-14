import Photos
import PhotosUI
import SwiftUI
import UIKit

/// Lightweight, value-type description of an Apple Photos collection for use in SwiftUI lists.
struct AlbumSummary: Identifiable, Hashable {
    enum Kind: Int, Comparable {
        case smart
        case user

        static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let id: String
    let title: String
    let count: Int
    let kind: Kind
}

/// Errors surfaced to the user rather than swallowed.
enum PhotoLibraryError: LocalizedError {
    case notAuthorized
    case deletionCancelled
    case deletionFailed(String)
    case assetsMissing(Int)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            "Unposted doesn't have permission to change your Photos library."
        case .deletionCancelled:
            "Deletion was cancelled."
        case .deletionFailed(let message):
            "Photos couldn't delete these photos. \(message)"
        case .assetsMissing(let count):
            "\(count) photo\(count == 1 ? "" : "s") could no longer be found in Apple Photos."
        }
    }
}

/// Owns everything that talks to PhotoKit: authorization, the asset index, change observation,
/// and the few mutating operations the app performs (batch delete, album membership).
///
/// Original photos and albums always stay in Apple Photos; nothing here copies asset data.
@MainActor
final class PhotoLibraryService: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    /// Carries PhotoKit objects across a concurrency boundary. PhotoKit's classes are not marked
    /// `Sendable` but are safe to read from any thread.
    private struct Snapshot: @unchecked Sendable {
        let assets: [PHAsset]
        let fetchResult: PHFetchResult<PHAsset>
    }

    private struct AlbumSnapshot: @unchecked Sendable {
        let summaries: [AlbumSummary]
        let collections: [String: PHAssetCollection]
    }

    private struct ChangeBox: @unchecked Sendable {
        let change: PHChange
    }

    /// Carries resolved assets into a PhotoKit change block.
    private struct AssetBox: @unchecked Sendable {
        let assets: [PHAsset]
    }

    @Published private(set) var authorization: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    /// All image assets the app is allowed to see, newest first.
    @Published private(set) var assets: [PHAsset] = []
    @Published private(set) var albums: [AlbumSummary] = []
    @Published private(set) var isLoading = false
    /// Incremented whenever the asset list changes, for cheap downstream invalidation.
    @Published private(set) var revision = 0
    @Published var lastErrorMessage: String?

    private var assetIndex: [String: PHAsset] = [:]
    private var assetFetchResult: PHFetchResult<PHAsset>?
    private var albumCollections: [String: PHAssetCollection] = [:]
    private var loadTask: Task<Void, Never>?
    private var isObserving = false
    private var cachedSimilarGroups: SimilarGroupIndex?
    private var cachedSimilarRevision = -1
    private var cachedShoots: [Shoot]?
    private var cachedShootsRevision = -1

    var hasAccess: Bool { authorization == .authorized || authorization == .limited }
    var isLimited: Bool { authorization == .limited }

    override init() {
        super.init()
    }

    deinit {
        if isObserving {
            PHPhotoLibrary.shared().unregisterChangeObserver(self)
        }
    }

    // MARK: - Authorization

    /// Requests access once, then starts observing. Safe to call on every appearance.
    func start() async {
        if authorization == .notDetermined {
            authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        } else {
            authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        }
        guard hasAccess else {
            clear()
            return
        }
        beginObserving()
        await reload()
    }

    /// Re-reads the current status; used when returning from Settings.
    func refreshAuthorization() async {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let changed = current != authorization
        authorization = current
        if hasAccess {
            beginObserving()
            if changed || assets.isEmpty { await reload() }
        } else {
            clear()
        }
    }

    private func beginObserving() {
        guard !isObserving else { return }
        PHPhotoLibrary.shared().register(self)
        isObserving = true
    }

    private func clear() {
        loadTask?.cancel()
        assets = []
        assetIndex = [:]
        assetFetchResult = nil
        albums = []
        albumCollections = [:]
        revision += 1
    }

    // MARK: - Loading

    /// Fetches the asset and album indexes off the main thread, then publishes them.
    func reload() async {
        guard hasAccess else { return }
        loadTask?.cancel()
        isLoading = assets.isEmpty
        let task = Task { [weak self] in
            let snapshot = await Self.loadAssets()
            let albumSnapshot = await Self.loadAlbums()
            guard let self, !Task.isCancelled else { return }
            self.apply(snapshot, albums: albumSnapshot)
        }
        loadTask = task
        await task.value
    }

    private func apply(_ snapshot: Snapshot, albums albumSnapshot: AlbumSnapshot) {
        assetFetchResult = snapshot.fetchResult
        assets = snapshot.assets
        assetIndex = Dictionary(snapshot.assets.map { ($0.localIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
        albums = albumSnapshot.summaries
        albumCollections = albumSnapshot.collections
        isLoading = false
        revision += 1
    }

    private nonisolated static func loadAssets() async -> Snapshot {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let options = PHFetchOptions()
                options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
                options.includeHiddenAssets = false
                let result = PHAsset.fetchAssets(with: .image, options: options)
                let materialized = Self.materialize(result)
                continuation.resume(returning: Snapshot(assets: materialized, fetchResult: result))
            }
        }
    }

    /// One bridged call instead of `count` calls to `object(at:)`.
    private nonisolated static func materialize(_ result: PHFetchResult<PHAsset>) -> [PHAsset] {
        guard result.count > 0 else { return [] }
        return result.objects(at: IndexSet(integersIn: 0..<result.count))
    }

    private nonisolated static func loadAlbums() async -> AlbumSnapshot {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var summaries: [AlbumSummary] = []
                var collections: [String: PHAssetCollection] = [:]

                func append(_ collection: PHAssetCollection, kind: AlbumSummary.Kind) {
                    let options = PHFetchOptions()
                    options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
                    let count = PHAsset.fetchAssets(in: collection, options: options).count
                    guard count > 0 else { return }
                    collections[collection.localIdentifier] = collection
                    summaries.append(
                        AlbumSummary(
                            id: collection.localIdentifier,
                            title: collection.localizedTitle ?? "Untitled",
                            count: count,
                            kind: kind
                        )
                    )
                }

                let userAlbums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
                userAlbums.enumerateObjects { collection, _, _ in
                    guard collection.assetCollectionSubtype == .albumRegular
                        || collection.assetCollectionSubtype == .albumMyPhotoStream
                        || collection.assetCollectionSubtype == .albumSyncedAlbum
                        || collection.assetCollectionSubtype == .albumCloudShared
                    else { return }
                    append(collection, kind: .user)
                }

                for subtype in [PHAssetCollectionSubtype.smartAlbumUserLibrary,
                                .smartAlbumFavorites,
                                .smartAlbumRecentlyAdded,
                                .smartAlbumSelfPortraits,
                                .smartAlbumScreenshots,
                                .smartAlbumBursts] {
                    let smart = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil)
                    smart.enumerateObjects { collection, _, _ in append(collection, kind: .smart) }
                }

                summaries.sort {
                    $0.kind == $1.kind
                        ? $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                        : $0.kind < $1.kind
                }
                continuation.resume(returning: AlbumSnapshot(summaries: summaries, collections: collections))
            }
        }
    }

    // MARK: - Change observation

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        let box = ChangeBox(change: changeInstance)
        Task { @MainActor [weak self] in
            self?.handleChange(box)
        }
    }

    private func handleChange(_ box: ChangeBox) {
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard hasAccess else {
            clear()
            return
        }
        // A full reload also refreshes album counts, which change details don't cover cheaply.
        Task { await self.reload() }
    }

    // MARK: - Derived groupings

    /// Near-duplicate index over the whole library, computed once per library revision. Callers
    /// read this from view bodies, so it must not be recomputed per render.
    var similarGroups: SimilarGroupIndex {
        if cachedSimilarRevision == revision, let cachedSimilarGroups {
            return cachedSimilarGroups
        }
        let index = AssetGrouping.similarGroups(from: assets)
        cachedSimilarGroups = index
        cachedSimilarRevision = revision
        return index
    }

    /// Time-clustered shoots, computed once per library revision.
    var shoots: [Shoot] {
        if cachedShootsRevision == revision, let cachedShoots {
            return cachedShoots
        }
        let result = AssetGrouping.shoots(from: assets)
        cachedShoots = result
        cachedShootsRevision = revision
        return result
    }

    // MARK: - Lookup

    func asset(for identifier: String) -> PHAsset? {
        assetIndex[identifier]
    }

    /// Resolves identifiers against the in-memory index first, then falls back to PhotoKit for
    /// assets outside the current fetch (for example when access is limited).
    func assets(for identifiers: [String]) -> [PHAsset] {
        var missing: [String] = []
        var found: [String: PHAsset] = [:]
        for id in identifiers {
            if let asset = assetIndex[id] { found[id] = asset } else { missing.append(id) }
        }
        if !missing.isEmpty {
            let fetched = PHAsset.fetchAssets(withLocalIdentifiers: missing, options: nil)
            fetched.enumerateObjects { asset, _, _ in found[asset.localIdentifier] = asset }
        }
        return identifiers.compactMap { found[$0] }
    }

    /// Identifiers that no longer resolve to an asset in Apple Photos.
    func missingIdentifiers(from identifiers: [String]) -> [String] {
        guard !identifiers.isEmpty else { return [] }
        let resolved = Set(assets(for: identifiers).map(\.localIdentifier))
        return identifiers.filter { !resolved.contains($0) }
    }

    func collection(for id: String) -> PHAssetCollection? {
        albumCollections[id]
    }

    func assetIdentifiers(inAlbum id: String) -> [String] {
        guard let collection = albumCollections[id] else { return [] }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(in: collection, options: options)
        var ids: [String] = []
        ids.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in ids.append(asset.localIdentifier) }
        return ids
    }

    // MARK: - Mutations

    /// Deletes assets from Apple Photos in one batch. iOS presents its own required confirmation
    /// alert; cancelling it surfaces as `.deletionCancelled`.
    func deleteAssets(withIdentifiers identifiers: [String]) async throws -> [String] {
        guard hasAccess else { throw PhotoLibraryError.notAuthorized }
        let resolved = assets(for: identifiers)
        guard !resolved.isEmpty else { throw PhotoLibraryError.assetsMissing(identifiers.count) }
        let deletedIDs = resolved.map(\.localIdentifier)
        let box = AssetBox(assets: resolved)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(box.assets as NSArray)
            } completionHandler: { success, error in
                if success {
                    continuation.resume()
                } else if let error = error as NSError?, Self.isUserCancellation(error) {
                    continuation.resume(throwing: PhotoLibraryError.deletionCancelled)
                } else {
                    continuation.resume(
                        throwing: PhotoLibraryError.deletionFailed(error?.localizedDescription ?? "Unknown error.")
                    )
                }
            }
        }
        return deletedIDs
    }

    private nonisolated static func isUserCancellation(_ error: NSError) -> Bool {
        error.domain == PHPhotosErrorDomain && error.code == PHPhotosError.userCancelled.rawValue
    }

    /// Creates an Apple Photos album and adds the given assets. Used to hand a finished post's
    /// photos to Photos so they are easy to pick in the Instagram or LinkedIn composer.
    func createAlbum(named name: String, assetIdentifiers: [String]) async throws {
        guard hasAccess else { throw PhotoLibraryError.notAuthorized }
        let resolved = assets(for: assetIdentifiers)
        let box = AssetBox(assets: resolved)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name)
                if !box.assets.isEmpty {
                    request.addAssets(box.assets as NSArray)
                }
            } completionHandler: { success, error in
                if success {
                    continuation.resume()
                } else if let error = error as NSError?, Self.isUserCancellation(error) {
                    continuation.resume(throwing: PhotoLibraryError.deletionCancelled)
                } else {
                    continuation.resume(
                        throwing: PhotoLibraryError.deletionFailed(error?.localizedDescription ?? "Unknown error.")
                    )
                }
            }
        }
        await reload()
    }

    // MARK: - Limited access

    /// Lets the user widen a limited selection without leaving the app.
    func presentLimitedLibraryPicker() {
        guard authorization == .limited else { return }
        guard let controller = Self.topViewController() else { return }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: controller)
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.first(where: { $0.activationState == .foregroundActive })?.windows.first(where: \.isKeyWindow)
            ?? scenes.first?.windows.first
        var controller = window?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
    }

    static func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
