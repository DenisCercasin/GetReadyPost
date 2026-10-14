import Photos
import SwiftData
import SwiftUI

/// Owns the long-lived services and decides between the permission gate and the app proper.
struct RootView: View {
    let containerErrorMessage: String?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var library: PhotoLibraryService
    @StateObject private var store: WorkflowStore

    @State private var didConfigure = false

    init(containerErrorMessage: String? = nil) {
        self.containerErrorMessage = containerErrorMessage
        let service = PhotoLibraryService()
        _library = StateObject(wrappedValue: service)
        _store = StateObject(wrappedValue: WorkflowStore(library: service))
    }

    var body: some View {
        Group {
            if library.hasAccess {
                MainTabView()
            } else {
                PermissionGateView()
            }
        }
        .environmentObject(library)
        .environmentObject(store)
        .task {
            if !didConfigure {
                didConfigure = true
                store.configure(context: modelContext)
                if let containerErrorMessage {
                    store.errorMessage = containerErrorMessage
                }
            }
            await library.start()
            // Posting Album membership needs the Photos index, so the migration may have deferred.
            store.retryMigrationIfPending()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task {
                    await library.refreshAuthorization()
                    store.retryMigrationIfPending()
                }
            }
        }
        .sheet(item: $store.migrationSummary) { summary in
            MigrationNoticeView(summary: summary) { store.dismissMigrationNotice() }
        }
        .errorAlert(message: $store.errorMessage)
        .errorAlert(message: $library.lastErrorMessage)
    }
}

/// Two tabs only: the gallery is the app, and Posts is the one other place with its own content.
struct MainTabView: View {
    var body: some View {
        TabView {
            LibraryView()
                .tabItem { Label("Library", systemImage: "photo.on.rectangle.angled") }
            PostsView()
                .tabItem { Label("Posts", systemImage: "square.stack") }
        }
    }
}

// MARK: - Permission gate

struct PermissionGateView: View {
    @EnvironmentObject private var library: PhotoLibraryService

    var body: some View {
        ContentUnavailableView {
            Label("Photos Access Needed", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text("""
            Unposted reviews the photos already in your library and keeps track of what you've \
            posted. Your photos stay in Apple Photos and are never uploaded or copied.
            """)
        } actions: {
            if library.authorization == .denied || library.authorization == .restricted {
                Button("Open Photos Settings") { PhotoLibraryService.openSettings() }
                    .buttonStyle(.borderedProminent)
                Text("Allow access to All Photos, or a selection, in Settings → Privacy → Photos.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Button("Allow Photos Access") {
                    Task { await library.start() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }
}

// MARK: - Migration notice

/// One-time explanation of how the previous version's data was carried over. Shown once, because
/// the old `Posted` flag had no platform and the user has to decide what it meant.
struct MigrationNoticeView: View {
    let summary: LegacyMigrationSummary
    let onDismiss: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Unposted now tracks posts per platform instead of one global Posted flag. Here's what came across:")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    if summary.previouslyPostedCount > 0 {
                        row(
                            symbol: "clock.arrow.circlepath",
                            tint: .orange,
                            title: "\(summary.previouslyPostedCount) previously posted photo\(summary.previouslyPostedCount == 1 ? "" : "s")",
                            detail: """
                            These are now keepers tagged “Previously posted”. The old flag didn't \
                            record a platform, so they aren't claimed as Instagram or LinkedIn \
                            publications. Find them with the Previously Posted filter and add them \
                            to a post to track platforms properly.
                            """
                        )
                    }
                    if summary.ignoredCount > 0 {
                        row(
                            symbol: "eye.slash.fill",
                            tint: .secondary,
                            title: "\(summary.ignoredCount) ignored photo\(summary.ignoredCount == 1 ? "" : "s")",
                            detail: "Still ignored, still in Apple Photos, and still out of your posting pool."
                        )
                    }
                    if summary.postingAlbumKeeperCount > 0 {
                        row(
                            symbol: "checkmark.circle.fill",
                            tint: .green,
                            title: "\(summary.postingAlbumKeeperCount) photo\(summary.postingAlbumKeeperCount == 1 ? "" : "s") from Posting Albums",
                            detail: """
                            Posting Albums are gone — the posting pool is now built from your Keep \
                            decisions. Photos in \(albumList) became keepers. Your Apple Photos \
                            albums were not changed.
                            """
                        )
                    } else if !summary.postingAlbumTitles.isEmpty {
                        row(
                            symbol: "rectangle.stack",
                            tint: .secondary,
                            title: "Posting Albums retired",
                            detail: """
                            \(albumList) are no longer used for state. The posting pool is now \
                            built from your Keep decisions. Your Apple Photos albums were not changed.
                            """
                        )
                    }
                }
                .padding()
            }
            .navigationTitle("Your Data Moved Over")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Got It") {
                        onDismiss()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private var albumList: String {
        let titles = summary.postingAlbumTitles.map { "“\($0)”" }
        switch titles.count {
        case 0: return "your Posting Albums"
        case 1: return titles[0]
        case 2: return "\(titles[0]) and \(titles[1])"
        default: return titles.dropLast().joined(separator: ", ") + ", and " + titles[titles.count - 1]
        }
    }

    private func row(symbol: String, tint: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

/// `LegacyMigrationSummary` needs identity to drive a `sheet(item:)`.
extension LegacyMigrationSummary: Identifiable {
    var id: String {
        "\(ignoredCount)-\(previouslyPostedCount)-\(postingAlbumKeeperCount)-\(postingAlbumTitles.joined(separator: "|"))"
    }
}
