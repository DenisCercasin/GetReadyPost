import Photos
import SwiftUI

/// The gallery. One grid, one filter menu, and the handful of posting controls layered on top of
/// an otherwise ordinary Photos-style screen.
struct LibraryView: View {
    @EnvironmentObject private var library: PhotoLibraryService
    @EnvironmentObject private var store: WorkflowStore

    @State private var scope: GalleryScope = .allPhotos
    @State private var isSelecting = false
    @State private var selection = Set<String>()
    @State private var viewingIdentifier: String?
    @State private var reviewRequest: ReviewRequest?
    @State private var isPickingReviewScope = false
    @State private var isShowingSettings = false
    @State private var isShowingDeletionQueue = false
    @State private var addToPostIdentifiers: [String]?

    /// Assets after the active filter, newest first.
    private var visibleAssets: [PHAsset] {
        // `store.revision` participates so the list recomputes when review state changes.
        _ = store.revision
        return store.assets(library.assets, in: scope)
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(scope.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
                .safeAreaInset(edge: .top, spacing: 0) { topChrome }
                .safeAreaInset(edge: .bottom, spacing: 0) { bottomChrome }
                .overlay(alignment: .bottom) { undoOverlay }
        }
        .fullScreenCover(item: Binding(get: { viewingIdentifier.map(IdentifierBox.init) }, set: { viewingIdentifier = $0?.id })) { box in
            PhotoViewerView(
                assets: visibleAssets,
                initialIdentifier: box.id,
                onReviewHere: { identifier in
                    viewingIdentifier = nil
                    reviewRequest = ReviewRequest(
                        title: "Review",
                        identifiers: visibleAssets.map(\.localIdentifier),
                        startAt: identifier
                    )
                },
                onAddToPost: { addToPostIdentifiers = $0 }
            )
        }
        .fullScreenCover(item: $reviewRequest) { request in
            ReviewView(request: request)
        }
        .sheet(isPresented: $isPickingReviewScope) {
            ReviewSetupView { request in
                isPickingReviewScope = false
                reviewRequest = request
            }
        }
        .sheet(isPresented: $isShowingSettings) { SettingsView() }
        .sheet(isPresented: $isShowingDeletionQueue) { DeletionQueueView() }
        .sheet(item: Binding(get: { addToPostIdentifiers.map(IdentifierListBox.init) }, set: { addToPostIdentifiers = $0?.identifiers })) { box in
            AddToPostSheet(identifiers: box.identifiers) {
                isSelecting = false
                selection.removeAll()
            }
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if library.isLoading && library.assets.isEmpty {
            ProgressView("Loading your library…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visibleAssets.isEmpty {
            ContentUnavailableView {
                Label(scope.title, systemImage: scope.symbolName)
            } description: {
                Text(scope.emptyMessage)
            } actions: {
                if scope != .allPhotos {
                    Button("Show All Photos") { scope = .allPhotos }
                }
                if scope == .allPhotos && library.isLimited {
                    Button("Select More Photos") { library.presentLimitedLibraryPicker() }
                }
            }
        } else {
            PhotoGridView(
                assets: visibleAssets,
                selection: $selection,
                isSelecting: isSelecting,
                onOpen: { viewingIdentifier = $0.localIdentifier },
                onAddToPost: { addToPostIdentifiers = $0 }
            )
        }
    }

    @ViewBuilder
    private var topChrome: some View {
        VStack(spacing: 0) {
            if library.isLimited {
                LimitedAccessBanner(visibleCount: library.assets.count) {
                    library.presentLimitedLibraryPicker()
                }
            }
            if let caption = scope.caption, !isSelecting {
                Text("\(visibleAssets.count) · \(caption)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 5)
                    .background(.bar)
            }
            Divider().opacity(library.isLimited || scope.caption != nil ? 1 : 0)
        }
    }

    @ViewBuilder
    private var bottomChrome: some View {
        if isSelecting && !selection.isEmpty {
            SelectionActionBar(
                selection: $selection,
                onAddToPost: { addToPostIdentifiers = Array(selection) },
                onFinish: {
                    isSelecting = false
                    selection.removeAll()
                }
            )
        }
    }

    @ViewBuilder
    private var undoOverlay: some View {
        if let action = store.undoAction, !isSelecting {
            UndoBar(action: action, onUndo: { store.performUndo() }, onDismiss: { store.dismissUndo() })
                .padding(.bottom, 10)
                .animation(.spring(duration: 0.3), value: action.id)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            filterMenu
        }

        ToolbarItem(placement: .topBarTrailing) {
            if isSelecting {
                Button("Done") {
                    isSelecting = false
                    selection.removeAll()
                }
                .fontWeight(.semibold)
            } else {
                Menu {
                    Button {
                        isSelecting = true
                    } label: {
                        Label("Select", systemImage: "checkmark.circle")
                    }
                    .disabled(visibleAssets.isEmpty)

                    Button {
                        isPickingReviewScope = true
                    } label: {
                        Label("Start a Review…", systemImage: "rectangle.stack.badge.play")
                    }

                    if store.deletionQueueCount > 0 {
                        Button {
                            isShowingDeletionQueue = true
                        } label: {
                            Label("Deletion Queue (\(store.deletionQueueCount))", systemImage: "trash")
                        }
                    }

                    Divider()

                    Button {
                        isShowingSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More")
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            if !isSelecting {
                Button {
                    startReviewOfVisible()
                } label: {
                    Label("Review", systemImage: "rectangle.stack.badge.play")
                }
                .disabled(visibleAssets.isEmpty)
            }
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("Filter", selection: $scope) {
                ForEach(GalleryScope.Group.allCases, id: \.rawValue) { group in
                    Section(group.title) {
                        ForEach(GalleryScope.menuScopes(includePreviouslyPosted: store.hasPreviouslyPostedPhotos).filter { $0.group == group }) { option in
                            Label {
                                Text(option.title)
                            } icon: {
                                Image(systemName: option.symbolName)
                            }
                            .tag(option)
                        }
                    }
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: scope == .allPhotos ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .accessibilityLabel("Filter")
    }

    private func startReviewOfVisible() {
        // Reviewing a filtered gallery reviews exactly what is on screen.
        let identifiers = visibleAssets.map(\.localIdentifier)
        guard !identifiers.isEmpty else { return }
        reviewRequest = ReviewRequest(title: scope.title, identifiers: identifiers, startAt: nil)
    }
}

// MARK: - Selection bar

/// Batch actions for a multi-selection. Mirrors the single-photo quick actions.
struct SelectionActionBar: View {
    @Binding var selection: Set<String>
    let onAddToPost: () -> Void
    let onFinish: () -> Void

    @EnvironmentObject private var store: WorkflowStore

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 18) {
                Text("\(selection.count) Selected")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()

                Spacer(minLength: 0)

                action("Keep", systemImage: "checkmark.circle") {
                    store.apply(.keep, to: Array(selection))
                    finish()
                }
                action("Ignore", systemImage: "eye.slash") {
                    store.apply(.ignored, to: Array(selection))
                    finish()
                }
                action("Post", systemImage: "square.stack.badge.plus", action: onAddToPost)
                action("Delete", systemImage: "trash", tint: .red) {
                    store.apply(.deletionQueue, to: Array(selection))
                    finish()
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }

    private func action(_ title: String, systemImage: String, tint: Color = .accentColor, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemImage).font(.title3)
                Text(title).font(.caption2)
            }
        }
        .tint(tint)
        .buttonStyle(.plain)
        .foregroundStyle(tint)
        .accessibilityLabel(title)
    }

    private func finish() {
        selection.removeAll()
        onFinish()
    }
}

// MARK: - Identifiable boxes

/// `fullScreenCover(item:)` and `sheet(item:)` need `Identifiable` payloads.
struct IdentifierBox: Identifiable {
    let id: String
}

struct IdentifierListBox: Identifiable {
    let identifiers: [String]
    var id: String { identifiers.joined(separator: "|") }

    init(identifiers: [String]) {
        self.identifiers = identifiers
    }
}
