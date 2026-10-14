import Photos
import SwiftUI

/// Prepare one post: order its photos, write a caption, choose destinations, and record each
/// platform's publication separately.
struct PostEditorView: View {
    let post: Post

    @EnvironmentObject private var library: PhotoLibraryService
    @EnvironmentObject private var store: WorkflowStore
    @Environment(\.displayScale) private var displayScale

    @State private var isPickingPhotos = false
    @State private var isReordering = false
    @State private var publishSheet: PublishRequest?
    @State private var isConfirmingDelete = false
    @State private var isExportingAlbum = false
    @State private var albumMessage: String?

    var body: some View {
        // Edits go through `store`, so the form participates in its revision counter rather than
        // relying on observation reaching through `Post`'s computed destination accessors.
        let _ = store.revision
        return Form {
            photosSection
            captionSection
            destinationsSection
            publicationSection
            housekeepingSection
        }
        .navigationTitle(post.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                PostStatusBadge(status: post.status)
            }
        }
        .sheet(isPresented: $isPickingPhotos) {
            AssetPickerView(
                title: "Add Photos",
                initialSelection: post.assetIdentifiers,
                confirmTitle: "Update Post"
            ) { identifiers in
                isPickingPhotos = false
                applyPicked(identifiers)
            }
        }
        .sheet(isPresented: $isReordering) {
            PostReorderView(post: post)
        }
        .sheet(item: $publishSheet) { request in
            MarkPublishedView(post: post, platform: request.platform)
        }
        .alert("Delete this post?", isPresented: $isConfirmingDelete) {
            Button("Delete Post", role: .destructive) { store.delete(post) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The photos stay in Apple Photos and stay available for other posts.")
        }
        .alert("Album", isPresented: Binding(get: { albumMessage != nil }, set: { if !$0 { albumMessage = nil } })) {
            Button("OK", role: .cancel) { albumMessage = nil }
        } message: {
            Text(albumMessage ?? "")
        }
    }

    // MARK: Photos

    private var photosSection: some View {
        Section {
            if post.assetIdentifiers.isEmpty {
                Text("No photos yet.")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(Array(post.assetIdentifiers.enumerated()), id: \.element) { position, identifier in
                            photoChip(position: position, identifier: identifier)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .scrollIndicators(.hidden)
            }

            Button {
                isPickingPhotos = true
            } label: {
                Label("Add or Remove Photos", systemImage: "photo.badge.plus")
            }

            if post.assetIdentifiers.count > 1 {
                Button {
                    isReordering = true
                } label: {
                    Label("Reorder Photos", systemImage: "arrow.up.arrow.down")
                }
            }
        } header: {
            HStack {
                Text("Photos")
                Spacer()
                if post.assetIdentifiers.count > 1 {
                    Text("Order is the carousel order")
                        .font(.caption2)
                        .textCase(nil)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func photoChip(position: Int, identifier: String) -> some View {
        let side: CGFloat = 86
        return IdentifierThumbnailView(
            identifier: identifier,
            targetSize: CGSize(width: side * displayScale, height: side * displayScale)
        )
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(alignment: .topLeading) {
            Text("\(position + 1)")
                .font(.caption2.weight(.bold))
                .monospacedDigit()
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.black.opacity(0.6), in: Capsule())
                .foregroundStyle(.white)
                .padding(4)
        }
        .contextMenu {
            Button(role: .destructive) {
                store.removePhotos([identifier], from: post)
            } label: {
                Label("Remove From Post", systemImage: "minus.circle")
            }
            if position > 0 {
                Button {
                    store.movePhotos(in: post, fromOffsets: IndexSet(integer: position), toOffset: position - 1)
                } label: {
                    Label("Move Earlier", systemImage: "arrow.left")
                }
            }
            if position < post.assetIdentifiers.count - 1 {
                Button {
                    store.movePhotos(in: post, fromOffsets: IndexSet(integer: position), toOffset: position + 2)
                } label: {
                    Label("Move Later", systemImage: "arrow.right")
                }
            }
        }
    }

    // MARK: Caption

    private var captionSection: some View {
        Section("Title & Caption") {
            TextField("Title (optional)", text: Binding(
                get: { post.title },
                set: { store.update(post, title: $0) }
            ))

            TextField(
                "Caption or note",
                text: Binding(get: { post.caption }, set: { store.update(post, caption: $0) }),
                axis: .vertical
            )
            .lineLimit(3...10)
        }
    }

    // MARK: Destinations

    private var destinationsSection: some View {
        Section {
            ForEach(Platform.allCases) { platform in
                Toggle(isOn: Binding(
                    get: { post.destinations.contains(platform) },
                    set: { store.setDestination(platform, enabled: $0, on: post) }
                )) {
                    Label(platform.title, systemImage: platform.symbolName)
                }
                .tint(platform.tint)
            }
        } header: {
            Text("Destinations")
        } footer: {
            Text("Choose one or both. You publish in each app yourself, then mark them here.")
        }
    }

    // MARK: Publication

    private var publicationSection: some View {
        Section {
            if post.destinations.isEmpty {
                Text("Pick a destination to track publication.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Toggle(isOn: Binding(
                    get: { post.isMarkedReady || !post.publishedPlatforms.isEmpty },
                    set: { store.setReady($0, on: post) }
                )) {
                    Label("Ready to Post", systemImage: "paperplane")
                }
                .disabled(!post.publishedPlatforms.isEmpty)

                ForEach(post.orderedDestinations) { platform in
                    publicationRow(platform)
                }

                Button {
                    Task { await exportAlbum() }
                } label: {
                    HStack {
                        Label("Save as Apple Photos Album", systemImage: "rectangle.stack.badge.plus")
                        if isExportingAlbum {
                            Spacer()
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .disabled(post.assetIdentifiers.isEmpty || isExportingAlbum)
            }
        } header: {
            Text("Publishing")
        } footer: {
            if !post.destinations.isEmpty {
                Text("Saving an album makes the carousel easy to pick, in order, from the Instagram or LinkedIn composer.")
            }
        }
    }

    private func publicationRow(_ platform: Platform) -> some View {
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(platform.title)
                    if let date = post.publishedAt(platform) {
                        Text("Published \(date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Not published yet")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: post.isPublished(on: platform) ? "checkmark.circle.fill" : platform.symbolName)
                    .foregroundStyle(post.isPublished(on: platform) ? platform.tint : .secondary)
            }

            Spacer()

            if post.isPublished(on: platform) {
                Menu {
                    Button {
                        publishSheet = PublishRequest(platform: platform)
                    } label: {
                        Label("Change Date", systemImage: "calendar")
                    }
                    Button(role: .destructive) {
                        store.clearPublished(post, platform: platform)
                    } label: {
                        Label("Mark Not Published", systemImage: "arrow.uturn.backward")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            } else {
                Button("Mark Published") {
                    store.markPublished(post, platform: platform)
                }
                .font(.footnote.weight(.semibold))
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: Housekeeping

    private var housekeepingSection: some View {
        Section {
            if !missingIdentifiers.isEmpty {
                Button(role: .destructive) {
                    store.removePhotos(Set(missingIdentifiers), from: post)
                } label: {
                    Label(
                        "Remove \(missingIdentifiers.count) Missing Photo\(missingIdentifiers.count == 1 ? "" : "s")",
                        systemImage: "exclamationmark.triangle"
                    )
                }
            }
            Button(role: .destructive) {
                isConfirmingDelete = true
            } label: {
                Label("Delete Post", systemImage: "trash")
            }
        } footer: {
            Text("Removing a photo from a post never deletes it. It stays a keeper and stays available for another post.")
        }
    }

    private var missingIdentifiers: [String] {
        library.missingIdentifiers(from: post.assetIdentifiers)
    }

    // MARK: Actions

    /// The picker returns the full desired membership, so this diffs rather than appends.
    private func applyPicked(_ identifiers: [String]) {
        let desired = Set(identifiers)
        let current = Set(post.assetIdentifiers)
        let removed = current.subtracting(desired)
        if !removed.isEmpty { store.removePhotos(removed, from: post) }
        let added = identifiers.filter { !current.contains($0) }
        if !added.isEmpty { store.addPhotos(added, to: post) }
    }

    private func exportAlbum() async {
        isExportingAlbum = true
        defer { isExportingAlbum = false }
        let name = post.displayTitle == "Untitled Post" ? "Unposted Draft" : post.displayTitle
        do {
            try await library.createAlbum(named: name, assetIdentifiers: post.assetIdentifiers)
            albumMessage = "Created the album “\(name)” in Apple Photos."
        } catch PhotoLibraryError.deletionCancelled {
            // User backed out of the Photos prompt.
        } catch {
            albumMessage = error.localizedDescription
        }
    }

    struct PublishRequest: Identifiable {
        let platform: Platform
        var id: String { platform.rawValue }
    }
}

// MARK: - Reordering

/// Drag-to-reorder in a plain `List`, which is the native way to order a carousel.
struct PostReorderView: View {
    let post: Post

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: WorkflowStore
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let _ = store.revision
        return NavigationStack {
            List {
                ForEach(Array(post.assetIdentifiers.enumerated()), id: \.element) { position, identifier in
                    HStack(spacing: 12) {
                        Text("\(position + 1)")
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 22)
                        IdentifierThumbnailView(
                            identifier: identifier,
                            targetSize: CGSize(width: 52 * displayScale, height: 52 * displayScale)
                        )
                        .frame(width: 52, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        Spacer()
                    }
                }
                .onMove { source, destination in
                    store.movePhotos(in: post, fromOffsets: source, toOffset: destination)
                }
                .onDelete { offsets in
                    let identifiers = offsets.map { post.assetIdentifiers[$0] }
                    store.removePhotos(Set(identifiers), from: post)
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Reorder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
    }
}

// MARK: - Mark published

/// Backdating a publication, for when the post went out before it was recorded here.
struct MarkPublishedView: View {
    let post: Post
    let platform: Platform

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: WorkflowStore
    @State private var date: Date = .now

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker(
                        "Published",
                        selection: $date,
                        in: ...Date.now,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                } header: {
                    Text("\(platform.title) publication")
                } footer: {
                    Text("Only \(platform.title) is affected. The other destination keeps its own date.")
                }
            }
            .navigationTitle("Mark Published")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.markPublished(post, platform: platform, at: date)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear { date = post.publishedAt(platform) ?? .now }
        }
    }
}
