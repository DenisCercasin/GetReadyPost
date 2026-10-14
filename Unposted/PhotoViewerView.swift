import Photos
import SwiftUI

/// Ordinary full-screen browsing: page sideways, pinch or double-tap to zoom, tap to hide the
/// chrome. No action swipes live here — those belong to Review mode, so that browsing a shoot
/// can never change a photo's state by accident.
struct PhotoViewerView: View {
    let assets: [PHAsset]
    let initialIdentifier: String
    let onReviewHere: (String) -> Void
    let onAddToPost: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: WorkflowStore

    @State private var index = 0
    @State private var isChromeVisible = true
    @State private var compareGroup: [String]?

    private var currentAsset: PHAsset? {
        assets.indices.contains(index) ? assets[index] : nil
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $index) {
                ForEach(Array(assets.enumerated()), id: \.element.localIdentifier) { offset, asset in
                    ZoomableAssetView(asset: asset) {
                        withAnimation(.easeInOut(duration: 0.2)) { isChromeVisible.toggle() }
                    }
                    .tag(offset)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            if isChromeVisible {
                VStack {
                    topBar
                    Spacer()
                    if let asset = currentAsset {
                        ViewerActionBar(
                            asset: asset,
                            onCompare: { compareGroup = $0 },
                            onAddToPost: { onAddToPost([asset.localIdentifier]) }
                        )
                    }
                }
                .transition(.opacity)
            }
        }
        .statusBarHidden(!isChromeVisible)
        .onAppear {
            index = assets.firstIndex { $0.localIdentifier == initialIdentifier } ?? 0
        }
        .fullScreenCover(item: Binding(get: { compareGroup.map(IdentifierListBox.init) }, set: { compareGroup = $0?.identifiers })) { box in
            CompareView(identifiers: box.identifiers)
        }
    }

    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .padding(10)
                    .background(.black.opacity(0.35), in: Circle())
            }
            .accessibilityLabel("Done")

            Spacer()

            if let asset = currentAsset {
                VStack(spacing: 1) {
                    Text(asset.creationDate?.formatted(date: .abbreviated, time: .omitted) ?? "Undated")
                        .font(.footnote.weight(.semibold))
                    Text(asset.creationDate?.formatted(date: .omitted, time: .shortened) ?? "")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.75))
                }
            }

            Spacer()

            Menu {
                if let asset = currentAsset {
                    Button {
                        onReviewHere(asset.localIdentifier)
                    } label: {
                        Label("Review From Here", systemImage: "rectangle.stack.badge.play")
                    }
                    let posts = store.posts(containing: asset.localIdentifier)
                    if posts.isEmpty {
                        Section("Usage") {
                            Text("Not in any post")
                        }
                    } else {
                        Section("In \(posts.count) post\(posts.count == 1 ? "" : "s")") {
                            ForEach(posts) { post in
                                Text("\(post.displayTitle) · \(post.status.title)")
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .padding(10)
                    .background(.black.opacity(0.35), in: Circle())
            }
            .accessibilityLabel("More")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.top, 6)
    }
}

// MARK: - Action bar

/// Buttons for the four review decisions, plus usage. Keeping them visible here is what makes the
/// actions discoverable — Review mode's swipes are the shortcut for the same four.
struct ViewerActionBar: View {
    let asset: PHAsset
    let onCompare: ([String]) -> Void
    let onAddToPost: () -> Void

    @EnvironmentObject private var store: WorkflowStore
    @EnvironmentObject private var library: PhotoLibraryService

    private var identifier: String { asset.localIdentifier }
    private var state: ReviewState { store.reviewState(for: identifier) }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                if state != .undecided {
                    Label(state.title, systemImage: state.symbolName)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(.white.opacity(0.18)))
                }
                PlatformUsageChips(
                    usage: store.usage(for: identifier),
                    wasPreviouslyPosted: store.wasPreviouslyPosted(identifier)
                )
                .environment(\.colorScheme, .dark)
            }

            let siblings = similarGroup
            if siblings.count > 1 {
                Button {
                    onCompare(siblings)
                } label: {
                    Label("Compare \(siblings.count) Similar", systemImage: "square.on.square.dashed")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }

            HStack(spacing: 6) {
                actionButton("Keep", "checkmark.circle.fill", isActive: state == .keep) {
                    store.apply(state == .keep ? .undecided : .keep, to: [identifier])
                }
                actionButton("Ignore", "eye.slash.fill", isActive: state == .ignored) {
                    store.apply(state == .ignored ? .undecided : .ignored, to: [identifier])
                }
                actionButton("Post", "square.stack.badge.plus", isActive: false, action: onAddToPost)
                actionButton("Delete", "trash.fill", isActive: state == .deletionQueue, tint: .red) {
                    store.apply(state == .deletionQueue ? .undecided : .deletionQueue, to: [identifier])
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background {
            LinearGradient(
                colors: [.black.opacity(0), .black.opacity(0.75)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }

    /// Near-duplicates of this photo, computed from the full library so the group is complete even
    /// when the gallery is filtered.
    private var similarGroup: [String] {
        library.similarGroups.group(for: identifier)
    }

    private func actionButton(
        _ title: String,
        _ symbol: String,
        isActive: Bool,
        tint: Color = .accentColor,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.title3)
                Text(title).font(.caption2.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(isActive ? tint.opacity(0.9) : Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }
}

// MARK: - Zoomable image

/// Pinch and double-tap zoom with panning. Pan is only active while zoomed, so the enclosing
/// `TabView` keeps its horizontal paging at 1×.
struct ZoomableAssetView: View {
    let asset: PHAsset
    let onTap: () -> Void

    @State private var image: UIImage?
    @State private var isDegraded = false
    @State private var requestID: PHImageRequestID?
    @State private var scale: CGFloat = 1
    @State private var gestureScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var dragStart: CGSize = .zero

    @Environment(\.displayScale) private var displayScale

    private let maximumScale: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            let currentScale = scale * gestureScale
            ZStack {
                Color.black
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(currentScale)
                        .offset(x: offset.width, y: offset.height)
                } else {
                    ProgressView().tint(.white)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .contentShape(Rectangle())
            .gesture(
                MagnifyGesture()
                    .onChanged { value in
                        gestureScale = value.magnification
                    }
                    .onEnded { _ in
                        let combined = min(max(scale * gestureScale, 1), maximumScale)
                        scale = combined
                        gestureScale = 1
                        if combined == 1 {
                            withAnimation(.easeOut(duration: 0.2)) { offset = .zero }
                        }
                    }
            )
            .simultaneousGesture(
                // Only engages when zoomed in; at 1× the TabView owns horizontal drags.
                DragGesture()
                    .onChanged { value in
                        guard scale > 1 else { return }
                        offset = CGSize(
                            width: dragStart.width + value.translation.width,
                            height: dragStart.height + value.translation.height
                        )
                    }
                    .onEnded { _ in
                        guard scale > 1 else { return }
                        offset = clamp(offset, in: proxy.size, scale: scale)
                        dragStart = offset
                    }
            )
            .onTapGesture(count: 2) {
                withAnimation(.spring(duration: 0.3)) {
                    if scale > 1 {
                        scale = 1
                        offset = .zero
                        dragStart = .zero
                    } else {
                        scale = 2.5
                    }
                }
            }
            .onTapGesture { onTap() }
            .task(id: asset.localIdentifier) { load(size: proxy.size) }
            .onDisappear {
                ThumbnailProvider.shared.cancel(requestID)
                requestID = nil
            }
        }
    }

    /// Keeps the image from being panned entirely off screen.
    private func clamp(_ offset: CGSize, in size: CGSize, scale: CGFloat) -> CGSize {
        let maxX = max(0, (size.width * scale - size.width) / 2)
        let maxY = max(0, (size.height * scale - size.height) / 2)
        return CGSize(
            width: min(max(offset.width, -maxX), maxX),
            height: min(max(offset.height, -maxY), maxY)
        )
    }

    private func load(size: CGSize) {
        let target = CGSize(
            width: max(size.width, 1) * displayScale,
            height: max(size.height, 1) * displayScale
        )
        requestID = ThumbnailProvider.shared.requestDisplayImage(for: asset, size: target) { loaded, degraded in
            guard let loaded else { return }
            // Never replace a sharp image with a degraded one.
            if degraded && image != nil && !isDegraded { return }
            image = loaded
            isDegraded = degraded
        }
    }
}
