import Photos
import SwiftUI
import UIKit

/// Shared PhotoKit image pipeline for the grid and the viewer.
///
/// Keeps a `PHCachingImageManager` warm over a sliding window around what the user is scrolling
/// through, plus a small decoded-image cache so cells that scroll back into view are instant.
@MainActor
final class ThumbnailProvider {
    static let shared = ThumbnailProvider()

    private let manager: PHCachingImageManager
    private let cache = NSCache<NSString, UIImage>()
    private var cachedAssets: [PHAsset] = []
    private var cachedWindow: Range<Int> = 0..<0
    private var cachedTargetSize: CGSize = .zero
    private var pendingWindowUpdate: Task<Void, Never>?

    /// How many assets ahead of and behind the visible range to keep warm.
    private let windowPadding = 120

    private init() {
        manager = PHCachingImageManager()
        manager.allowsCachingHighQualityImages = false
        cache.countLimit = 400
    }

    // MARK: - Requests

    private static func key(_ asset: PHAsset, _ size: CGSize) -> NSString {
        "\(asset.localIdentifier)|\(Int(size.width))x\(Int(size.height))" as NSString
    }

    func cachedImage(for asset: PHAsset, size: CGSize) -> UIImage? {
        cache.object(forKey: Self.key(asset, size))
    }

    /// Requests a thumbnail. The handler may be called twice: once with a fast degraded image and
    /// again with the final one, which is what makes scrolling feel immediate.
    @discardableResult
    func requestThumbnail(
        for asset: PHAsset,
        size: CGSize,
        handler: @escaping (UIImage?) -> Void
    ) -> PHImageRequestID? {
        if let cached = cachedImage(for: asset, size: size) {
            handler(cached)
            return nil
        }
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        let key = Self.key(asset, size)
        return manager.requestImage(
            for: asset,
            targetSize: size,
            contentMode: .aspectFill,
            options: options
        ) { [weak self] image, info in
            guard let image else { return }
            let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            // PhotoKit calls back on a private queue; everything below touches main-actor state.
            DispatchQueue.main.async {
                if !isDegraded { self?.cache.setObject(image, forKey: key) }
                handler(image)
            }
        }
    }

    /// Full-screen image for the viewer and the compare screen.
    @discardableResult
    func requestDisplayImage(
        for asset: PHAsset,
        size: CGSize,
        handler: @escaping (UIImage?, Bool) -> Void
    ) -> PHImageRequestID {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = true
        return manager.requestImage(
            for: asset,
            targetSize: size,
            contentMode: .aspectFit,
            options: options
        ) { image, info in
            let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            // Same here: the handler updates SwiftUI state and must run on the main actor.
            DispatchQueue.main.async {
                handler(image, isDegraded)
            }
        }
    }

    func cancel(_ requestID: PHImageRequestID?) {
        guard let requestID else { return }
        manager.cancelImageRequest(requestID)
    }

    // MARK: - Caching window

    /// Called when the backing list changes. Resets the window so stale assets stop being cached.
    func reset(assets: [PHAsset], targetSize: CGSize) {
        pendingWindowUpdate?.cancel()
        if !cachedAssets.isEmpty {
            manager.stopCachingImagesForAllAssets()
        }
        cachedAssets = assets
        cachedTargetSize = targetSize
        cachedWindow = 0..<0
        updateWindow(around: 0)
    }

    /// Coalesces the rapid-fire index reports that come from cells appearing during a fast scroll.
    func noteVisible(index: Int) {
        pendingWindowUpdate?.cancel()
        pendingWindowUpdate = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            self?.updateWindow(around: index)
        }
    }

    private func updateWindow(around index: Int) {
        guard !cachedAssets.isEmpty, cachedTargetSize != .zero else { return }
        let lower = max(0, index - windowPadding)
        let upper = min(cachedAssets.count, index + windowPadding)
        guard lower < upper else { return }
        let newWindow = lower..<upper
        guard newWindow != cachedWindow else { return }

        let toStart = indices(in: newWindow, excluding: cachedWindow)
        let toStop = indices(in: cachedWindow, excluding: newWindow)

        if !toStop.isEmpty {
            manager.stopCachingImages(
                for: toStop.map { cachedAssets[$0] },
                targetSize: cachedTargetSize,
                contentMode: .aspectFill,
                options: nil
            )
        }
        if !toStart.isEmpty {
            manager.startCachingImages(
                for: toStart.map { cachedAssets[$0] },
                targetSize: cachedTargetSize,
                contentMode: .aspectFill,
                options: nil
            )
        }
        cachedWindow = newWindow
    }

    private func indices(in range: Range<Int>, excluding other: Range<Int>) -> [Int] {
        guard !range.isEmpty else { return [] }
        guard !other.isEmpty else { return Array(range) }
        return range.filter { !other.contains($0) }
    }

    /// Dropped when the app is backgrounded or the library is reloaded wholesale.
    func purge() {
        pendingWindowUpdate?.cancel()
        manager.stopCachingImagesForAllAssets()
        cache.removeAllObjects()
        cachedAssets = []
        cachedWindow = 0..<0
    }
}
