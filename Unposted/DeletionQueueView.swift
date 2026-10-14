import Photos
import SwiftUI

/// Reviewable deletion queue. Nothing leaves Apple Photos until the user taps Delete here and
/// confirms the system alert that iOS presents on top of it.
struct DeletionQueueView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: PhotoLibraryService
    @EnvironmentObject private var store: WorkflowStore

    @State private var selection = Set<String>()
    @State private var isDeleting = false
    @State private var resultMessage: String?

    private var identifiers: [String] {
        _ = store.revision
        return store.deletionQueueIdentifiers()
    }

    private var assets: [PHAsset] { library.assets(for: identifiers) }

    var body: some View {
        NavigationStack {
            Group {
                if assets.isEmpty {
                    ContentUnavailableView {
                        Label("Deletion Queue Is Empty", systemImage: "trash")
                    } description: {
                        Text("Photos you queue while reviewing collect here, so you can delete them from Apple Photos in one batch.")
                    }
                } else {
                    grid
                }
            }
            .navigationTitle("Deletion Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if !assets.isEmpty {
                        Menu {
                            Button {
                                selection = Set(identifiers)
                            } label: {
                                Label("Select All", systemImage: "checkmark.circle")
                            }
                            Button {
                                selection.removeAll()
                            } label: {
                                Label("Deselect All", systemImage: "circle")
                            }
                            Divider()
                            Button {
                                store.apply(.undecided, to: identifiers, undoLabel: "Emptied the deletion queue")
                                selection.removeAll()
                            } label: {
                                Label("Remove All From Queue", systemImage: "arrow.uturn.backward")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !assets.isEmpty { deleteBar }
            }
            .alert("Deletion", isPresented: Binding(get: { resultMessage != nil }, set: { if !$0 { resultMessage = nil } })) {
                Button("OK", role: .cancel) { resultMessage = nil }
            } message: {
                Text(resultMessage ?? "")
            }
        }
    }

    private var grid: some View {
        GeometryReader { proxy in
            let columnCount = 3
            let spacing: CGFloat = 2
            let side = max(1, (proxy.size.width - spacing * CGFloat(columnCount - 1)) / CGFloat(columnCount))

            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(side), spacing: spacing), count: columnCount),
                    spacing: spacing
                ) {
                    ForEach(assets, id: \.localIdentifier) { asset in
                        let identifier = asset.localIdentifier
                        let isSelected = selection.contains(identifier)
                        AssetThumbnailView(asset: asset, targetSize: CGSize(width: side * 3, height: side * 3))
                            .frame(width: side, height: side)
                            .overlay {
                                if isSelected { Rectangle().fill(Color.red.opacity(0.22)) }
                            }
                            .overlay(alignment: .topTrailing) {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(isSelected ? .white : .white.opacity(0.9), isSelected ? Color.red : .clear)
                                    .shadow(color: .black.opacity(0.4), radius: 2)
                                    .padding(5)
                            }
                            .onTapGesture {
                                if isSelected { selection.remove(identifier) } else { selection.insert(identifier) }
                            }
                            .contextMenu {
                                Button {
                                    store.apply(.undecided, to: [identifier], undoLabel: "Removed from the queue")
                                    selection.remove(identifier)
                                } label: {
                                    Label("Remove From Queue", systemImage: "arrow.uturn.backward")
                                }
                                Button {
                                    store.apply(.keep, to: [identifier])
                                    selection.remove(identifier)
                                } label: {
                                    Label("Keep for Posting", systemImage: "checkmark.circle")
                                }
                            }
                    }
                }
            }
        }
    }

    private var deleteBar: some View {
        VStack(spacing: 8) {
            Divider()
            Text(selection.isEmpty
                 ? "Select photos to delete, or delete the whole queue."
                 : "\(selection.count) of \(assets.count) selected.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(role: .destructive) {
                Task { await delete(Array(selection.isEmpty ? Set(identifiers) : selection)) }
            } label: {
                HStack {
                    if isDeleting {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "trash")
                    }
                    Text(selection.isEmpty
                         ? "Delete All \(assets.count) From Apple Photos"
                         : "Delete \(selection.count) From Apple Photos")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(isDeleting)
            .padding(.horizontal, 16)

            Text("Apple Photos will ask you to confirm. Deleted photos go to Recently Deleted.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.bottom, 6)
        }
        .background(.bar)
    }

    private func delete(_ targets: [String]) async {
        guard !targets.isEmpty else { return }
        isDeleting = true
        defer { isDeleting = false }
        do {
            // iOS presents its own required confirmation inside this call.
            let deleted = try await library.deleteAssets(withIdentifiers: targets)
            store.handleAssetsDeleted(deleted)
            selection.removeAll()
            await library.reload()
            resultMessage = "Deleted \(deleted.count) photo\(deleted.count == 1 ? "" : "s") from Apple Photos."
        } catch PhotoLibraryError.deletionCancelled {
            // Nothing was deleted and the queue is untouched; no alert needed.
        } catch {
            resultMessage = error.localizedDescription
        }
    }
}
