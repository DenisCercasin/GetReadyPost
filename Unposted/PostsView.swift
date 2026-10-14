import Photos
import SwiftUI

/// Posts grouped by state. The counters at the top answer "what have I still not posted?"
/// without needing a separate dashboard.
struct PostsView: View {
    @EnvironmentObject private var library: PhotoLibraryService
    @EnvironmentObject private var store: WorkflowStore

    @State private var newPostIdentifier: UUID?
    @State private var isPickingPhotosForNewPost = false

    var body: some View {
        NavigationStack {
            Group {
                if store.posts.isEmpty {
                    ContentUnavailableView {
                        Label("No Posts Yet", systemImage: "square.stack")
                    } description: {
                        Text("Create a post from the photos you kept, order them, then mark each platform published once you've posted it.")
                    } actions: {
                        Button("New Post") { isPickingPhotosForNewPost = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    list
                }
            }
            .navigationTitle("Posts")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isPickingPhotosForNewPost = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New Post")
                }
            }
            .navigationDestination(item: $newPostIdentifier) { identifier in
                if let post = store.posts.first(where: { $0.identifier == identifier }) {
                    PostEditorView(post: post)
                }
            }
            .sheet(isPresented: $isPickingPhotosForNewPost) {
                AssetPickerView(
                    title: "Choose Photos",
                    initialSelection: [],
                    confirmTitle: "Create Post"
                ) { identifiers in
                    isPickingPhotosForNewPost = false
                    if let post = store.createPost(assetIdentifiers: identifiers) {
                        newPostIdentifier = post.identifier
                    }
                }
            }
        }
    }

    private var list: some View {
        List {
            Section {
                UnusedKeepersSummary()
            }

            ForEach(store.postsByStatus, id: \.status) { group in
                Section(group.status.title) {
                    ForEach(group.posts) { post in
                        NavigationLink {
                            PostEditorView(post: post)
                        } label: {
                            PostRow(post: post)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                store.delete(post)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

/// The question the app exists to answer, kept to two rows at the top of the Posts list.
struct UnusedKeepersSummary: View {
    @EnvironmentObject private var store: WorkflowStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Keepers still unposted")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                ForEach(Platform.allCases) { platform in
                    let count = store.unusedKeeperCount(for: platform)
                    HStack(spacing: 7) {
                        Image(systemName: platform.symbolName)
                            .foregroundStyle(platform.tint)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("\(count)")
                                .font(.title3.weight(.semibold))
                                .monospacedDigit()
                            Text(platform.title)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                    .background(platform.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            Text("Filter the Library by “Not on Instagram” or “Not on LinkedIn” to see them.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct PostRow: View {
    let post: Post

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        HStack(spacing: 12) {
            PostThumbnailStack(identifiers: Array(post.assetIdentifiers.prefix(3)), side: 52)

            VStack(alignment: .leading, spacing: 5) {
                Text(post.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text("\(post.assetIdentifiers.count) photo\(post.assetIdentifiers.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !post.orderedDestinations.isEmpty {
                        Text("·").foregroundStyle(.secondary).font(.caption)
                        ForEach(post.orderedDestinations) { platform in
                            Image(systemName: post.isPublished(on: platform) ? "checkmark.circle.fill" : platform.symbolName)
                                .font(.caption)
                                .foregroundStyle(post.isPublished(on: platform) ? platform.tint : .secondary)
                        }
                    }
                }

                PostStatusBadge(status: post.status)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

/// Overlapping thumbnails that read as "a post", like a stack of prints.
struct PostThumbnailStack: View {
    let identifiers: [String]
    let side: CGFloat

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack(alignment: .leading) {
            if identifiers.isEmpty {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color(uiColor: .tertiarySystemFill))
                    .frame(width: side, height: side)
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                    }
            } else {
                ForEach(Array(identifiers.enumerated().reversed()), id: \.element) { offset, identifier in
                    IdentifierThumbnailView(
                        identifier: identifier,
                        targetSize: CGSize(width: side * displayScale, height: side * displayScale)
                    )
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7).stroke(Color(uiColor: .systemBackground), lineWidth: 1.5)
                    }
                    .offset(x: CGFloat(offset) * 9)
                    .zIndex(Double(-offset))
                }
            }
        }
        .frame(width: side + CGFloat(max(identifiers.count - 1, 0)) * 9, height: side)
    }
}
