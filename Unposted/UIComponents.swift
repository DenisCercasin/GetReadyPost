import Photos
import SwiftUI

// MARK: - Thumbnails

/// A single PhotoKit-backed thumbnail. The target size is passed in rather than measured per cell
/// so the grid can size every cell once and keep `PHCachingImageManager` requests uniform.
struct AssetThumbnailView: View {
    let asset: PHAsset
    let targetSize: CGSize
    var contentMode: ContentMode = .fill

    @State private var image: UIImage?
    @State private var requestID: PHImageRequestID?

    var body: some View {
        Rectangle()
            .fill(Color(uiColor: .secondarySystemFill))
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                }
            }
            .clipped()
        .task(id: asset.localIdentifier) { load() }
        .onDisappear {
            ThumbnailProvider.shared.cancel(requestID)
            requestID = nil
        }
    }

    private func load() {
        image = ThumbnailProvider.shared.cachedImage(for: asset, size: targetSize)
        guard image == nil else { return }
        requestID = ThumbnailProvider.shared.requestThumbnail(for: asset, size: targetSize) { loaded in
            guard let loaded else { return }
            image = loaded
        }
    }
}

/// Thumbnail that resolves its own asset from an identifier, for post photo strips where the
/// asset may have been deleted from Apple Photos.
struct IdentifierThumbnailView: View {
    let identifier: String
    let targetSize: CGSize
    var contentMode: ContentMode = .fill

    @EnvironmentObject private var library: PhotoLibraryService

    var body: some View {
        Group {
            if let asset = library.asset(for: identifier) ?? library.assets(for: [identifier]).first {
                AssetThumbnailView(asset: asset, targetSize: targetSize, contentMode: contentMode)
            } else {
                MissingAssetPlaceholder()
            }
        }
    }
}

struct MissingAssetPlaceholder: View {
    var body: some View {
        ZStack {
            Rectangle().fill(Color(uiColor: .tertiarySystemFill))
            Image(systemName: "questionmark.square.dashed")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Badges

/// Corner markers on a grid cell. Deliberately small: the photo is the content, the state is a hint.
struct PhotoStateBadges: View {
    let state: ReviewState
    let usage: PhotoUsage
    let wasPreviouslyPosted: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            if let symbol = stateSymbol {
                Image(systemName: symbol)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 1.5)
            }
            if !publishedPlatforms.isEmpty {
                HStack(spacing: 2) {
                    ForEach(publishedPlatforms) { platform in
                        Circle()
                            .fill(platform.tint)
                            .frame(width: 7, height: 7)
                            .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 0.8))
                    }
                }
            } else if wasPreviouslyPosted {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 1.5)
            }
        }
        .padding(4)
    }

    private var publishedPlatforms: [Platform] {
        Platform.allCases.filter { usage.publishedPlatforms.contains($0) }
    }

    private var stateSymbol: String? {
        switch state {
        case .undecided: nil
        case .keep: "checkmark.circle.fill"
        case .ignored: "eye.slash.fill"
        case .deletionQueue: "trash.circle.fill"
        }
    }
}

/// Inline capsule describing per-platform usage, used in the viewer and post rows.
struct PlatformUsageChips: View {
    let usage: PhotoUsage
    let wasPreviouslyPosted: Bool
    var compact = false

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Platform.allCases) { platform in
                chip(for: platform)
            }
            if wasPreviouslyPosted {
                chip(
                    symbol: "clock.arrow.circlepath",
                    text: "Previously posted",
                    tint: .orange,
                    filled: true
                )
            }
        }
    }

    @ViewBuilder
    private func chip(for platform: Platform) -> some View {
        let isPublished = usage.publishedPlatforms.contains(platform)
        let isPlanned = usage.plannedPlatforms.contains(platform)
        chip(
            symbol: isPublished ? "checkmark.circle.fill" : platform.symbolName,
            text: isPlanned && !isPublished ? "\(platform.title) planned" : platform.title,
            tint: isPublished ? platform.tint : .secondary,
            filled: isPublished
        )
    }

    @ViewBuilder
    private func chip(symbol: String, text: String, tint: Color, filled: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            if !compact {
                Text(text)
            }
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, compact ? 5 : 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(filled ? tint.opacity(0.2) : Color.primary.opacity(0.08)))
        .foregroundStyle(tint)
        .accessibilityLabel(text)
    }
}

struct PostStatusBadge: View {
    let status: PostStatus

    var body: some View {
        Label(status.title, systemImage: status.symbolName)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(tint.opacity(0.16)))
            .foregroundStyle(tint)
    }

    private var tint: Color {
        switch status {
        case .draft: .secondary
        case .ready: .orange
        case .partiallyPublished: .purple
        case .published: .green
        }
    }
}

// MARK: - Undo

/// Transient bar confirming the last review action, with one tap to reverse it.
struct UndoBar: View {
    let action: ReviewUndoAction
    let onUndo: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.uturn.backward.circle.fill")
                .foregroundStyle(.secondary)
            Text(action.label)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("Undo", action: onUndo)
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.borderless)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .padding(.horizontal, 20)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

// MARK: - Limited access

/// Shown when Photos access is limited, so the narrowed library never looks like data loss.
struct LimitedAccessBanner: View {
    let visibleCount: Int
    let onManage: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Limited Photos access")
                    .font(.footnote.weight(.semibold))
                Text("\(visibleCount) photo\(visibleCount == 1 ? "" : "s") visible to Unposted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button("Manage", action: onManage)
                .font(.footnote.weight(.semibold))
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color(uiColor: .secondarySystemBackground))
    }
}

// MARK: - Misc

/// Small count pill used in toolbars and menus.
struct CountPill: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.caption2.weight(.bold))
            .monospacedDigit()
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.accentColor))
            .foregroundStyle(.white)
    }
}

extension View {
    /// Presents `message` as an alert and clears it on dismissal.
    func errorAlert(message: Binding<String?>) -> some View {
        alert(
            "Something went wrong",
            isPresented: Binding(get: { message.wrappedValue != nil }, set: { if !$0 { message.wrappedValue = nil } })
        ) {
            Button("OK", role: .cancel) { message.wrappedValue = nil }
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}
