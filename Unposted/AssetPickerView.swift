import Photos
import SwiftUI

/// Picks photos for a post. Defaults to the posting pool — keepers and undecided photos — with a
/// filter for the cases that matter, so ignored and queued photos never show up by accident.
struct AssetPickerView: View {
    let title: String
    /// Ordered, because this is also the post's carousel order when reopening an existing post.
    let initialSelection: [String]
    let confirmTitle: String
    let onConfirm: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: PhotoLibraryService
    @EnvironmentObject private var store: WorkflowStore
    @Environment(\.displayScale) private var displayScale

    @State private var selection: [String] = []
    @State private var pool: Pool = .available

    /// Pools are phrased as the questions a user actually has when assembling a post.
    enum Pool: String, CaseIterable, Identifiable {
        case available
        case unusedOnInstagram
        case unusedOnLinkedIn
        case allKeepers
        case everything

        var id: String { rawValue }

        var title: String {
            switch self {
            case .available: "Available to Post"
            case .unusedOnInstagram: "Not on Instagram"
            case .unusedOnLinkedIn: "Not on LinkedIn"
            case .allKeepers: "All Keepers"
            case .everything: "All Photos"
            }
        }

        var scope: GalleryScope? {
            switch self {
            case .available: .availableToPost
            case .unusedOnInstagram: .unusedOnInstagram
            case .unusedOnLinkedIn: .unusedOnLinkedIn
            case .allKeepers: .keepers
            case .everything: nil
            }
        }
    }

    private var candidates: [PHAsset] {
        _ = store.revision
        let base: [PHAsset]
        if let scope = pool.scope {
            base = store.assets(library.assets, in: scope)
        } else {
            // "All Photos" still excludes ignored and queued photos: those are decisions, not noise.
            base = library.assets.filter { store.isEligibleForPosts($0.localIdentifier) }
        }
        // Already-selected photos stay visible even if the pool wouldn't include them.
        let selected = Set(selection)
        let missing = library.assets.filter { selected.contains($0.localIdentifier) && !base.contains($0) }
        return missing.isEmpty ? base : (base + missing).sorted {
            ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Pool", selection: $pool) {
                    ForEach(Pool.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .labelsHidden()

                if candidates.isEmpty {
                    ContentUnavailableView {
                        Label(pool.title, systemImage: "photo.on.rectangle.angled")
                    } description: {
                        Text("No photos in this pool. Review a shoot and keep a few, or widen the filter above.")
                    }
                } else {
                    grid
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmTitle) { onConfirm(selection) }
                        .fontWeight(.semibold)
                        .disabled(selection.isEmpty)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !selection.isEmpty { selectionStrip }
            }
            .onAppear {
                if selection.isEmpty { selection = orderedInitialSelection }
            }
        }
    }

    /// Preserves the post's existing order on reopen.
    private var orderedInitialSelection: [String] { initialSelection }

    private var grid: some View {
        GeometryReader { proxy in
            let columnCount = 3
            let spacing: CGFloat = 2
            let side = max(1, (proxy.size.width - spacing * CGFloat(columnCount - 1)) / CGFloat(columnCount))
            let target = CGSize(width: side * displayScale, height: side * displayScale)

            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(side), spacing: spacing), count: columnCount),
                    spacing: spacing
                ) {
                    ForEach(candidates, id: \.localIdentifier) { asset in
                        let identifier = asset.localIdentifier
                        let position = selection.firstIndex(of: identifier)
                        AssetThumbnailView(asset: asset, targetSize: target)
                            .frame(width: side, height: side)
                            .overlay {
                                if position != nil { Rectangle().fill(Color.accentColor.opacity(0.22)) }
                            }
                            .overlay(alignment: .topTrailing) { marker(position: position) }
                            .onTapGesture { toggle(identifier) }
                    }
                }
            }
        }
    }

    /// The badge shows the carousel position, not just a checkmark, because order matters here.
    private func marker(position: Int?) -> some View {
        Group {
            if let position {
                Text("\(position + 1)")
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.accentColor))
            } else {
                Image(systemName: "circle")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(color: .black.opacity(0.4), radius: 2)
            }
        }
        .padding(5)
    }

    private var selectionStrip: some View {
        VStack(spacing: 6) {
            Divider()
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(Array(selection.enumerated()), id: \.element) { position, identifier in
                        IdentifierThumbnailView(
                            identifier: identifier,
                            targetSize: CGSize(width: 48 * displayScale, height: 48 * displayScale)
                        )
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(alignment: .topLeading) {
                            Text("\(position + 1)")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 4)
                                .background(.black.opacity(0.6), in: Capsule())
                                .foregroundStyle(.white)
                                .padding(2)
                        }
                        .onTapGesture { toggle(identifier) }
                    }
                }
                .padding(.horizontal, 14)
            }
            .scrollIndicators(.hidden)
            Text("\(selection.count) selected · tap to remove · order follows selection")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)
        }
        .background(.bar)
    }

    private func toggle(_ identifier: String) {
        if let position = selection.firstIndex(of: identifier) {
            selection.remove(at: position)
        } else {
            selection.append(identifier)
        }
    }
}

// MARK: - Add to post

/// Routes a set of photos into a new draft or an existing unpublished post.
struct AddToPostSheet: View {
    let identifiers: [String]
    var onComplete: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: WorkflowStore

    @State private var destinations: Set<Platform> = []
    @State private var title = ""

    /// Published posts are excluded: adding photos to something already out is almost always a
    /// mistake, and a new post is the right move.
    private var openPosts: [Post] {
        store.posts.filter { $0.publishedPlatforms.isEmpty }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PostThumbnailStack(identifiers: Array(identifiers.prefix(4)), side: 54)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(identifiers.count) photo\(identifiers.count == 1 ? "" : "s")")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("New Post") {
                    TextField("Title (optional)", text: $title)
                    ForEach(Platform.allCases) { platform in
                        Toggle(isOn: Binding(
                            get: { destinations.contains(platform) },
                            set: { isOn in
                                if isOn { destinations.insert(platform) } else { destinations.remove(platform) }
                            }
                        )) {
                            Label(platform.title, systemImage: platform.symbolName)
                        }
                        .tint(platform.tint)
                    }
                    Button {
                        store.createPost(assetIdentifiers: identifiers, title: title, destinations: destinations)
                        finish()
                    } label: {
                        Label("Create Draft Post", systemImage: "plus.square.on.square")
                    }
                }

                if !openPosts.isEmpty {
                    Section("Add to Existing Draft") {
                        ForEach(openPosts) { post in
                            Button {
                                store.addPhotos(identifiers, to: post)
                                finish()
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(post.displayTitle).foregroundStyle(.primary)
                                        Text("\(post.assetIdentifiers.count) photo\(post.assetIdentifiers.count == 1 ? "" : "s") · \(post.status.title)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "plus.circle")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add to Post")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func finish() {
        onComplete?()
        dismiss()
    }
}
