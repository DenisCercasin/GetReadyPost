import Photos
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: PhotoLibraryService
    @EnvironmentObject private var store: WorkflowStore

    @State private var isExporting = false
    @State private var isImporting = false
    @State private var isConfirmingReset = false
    @State private var missingIdentifiers: [String] = []
    @State private var isCheckingMissing = false
    @State private var statusMessage: String?

    var body: some View {
        NavigationStack {
            List {
                summarySection
                photosAccessSection
                maintenanceSection
                dataSection
                aboutSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .fileExporter(
                isPresented: $isExporting,
                document: BackupFile(data: store.exportBackup() ?? Data()),
                contentType: .json,
                defaultFilename: "Unposted Backup \(Date.now.formatted(date: .numeric, time: .omitted).replacingOccurrences(of: "/", with: "-"))"
            ) { result in
                if case .failure(let error) = result {
                    statusMessage = "Export failed. \(error.localizedDescription)"
                } else {
                    statusMessage = "Backup saved."
                }
            }
            .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
                switch result {
                case .success(let url):
                    do {
                        let data = try Data(contentsOf: url)
                        store.importBackup(data)
                        statusMessage = "Backup imported."
                    } catch {
                        statusMessage = "Couldn't read that file. \(error.localizedDescription)"
                    }
                case .failure(let error):
                    statusMessage = "Import failed. \(error.localizedDescription)"
                }
            }
            .alert("Reset all Unposted data?", isPresented: $isConfirmingReset) {
                Button("Reset", role: .destructive) {
                    store.resetAllData()
                    statusMessage = "All review decisions and posts were removed."
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This clears every review decision and every post. Your photos and albums in Apple Photos are not touched.")
            }
            .alert("Unposted", isPresented: Binding(get: { statusMessage != nil }, set: { if !$0 { statusMessage = nil } })) {
                Button("OK", role: .cancel) { statusMessage = nil }
            } message: {
                Text(statusMessage ?? "")
            }
        }
    }

    // MARK: Sections

    private var summarySection: some View {
        Section("Your Library") {
            LabeledContent("Photos visible", value: "\(library.assets.count)")
            LabeledContent("Keepers", value: "\(store.keeperCount)")
            LabeledContent("Posts", value: "\(store.posts.count)")
            LabeledContent("In deletion queue", value: "\(store.deletionQueueCount)")
            ForEach(Platform.allCases) { platform in
                LabeledContent("Keepers not on \(platform.title)", value: "\(store.unusedKeeperCount(for: platform))")
            }
        }
    }

    private var photosAccessSection: some View {
        Section {
            LabeledContent("Access", value: accessDescription)
            if library.isLimited {
                Button("Select More Photos") { library.presentLimitedLibraryPicker() }
            }
            Button("Open Photos Settings") { PhotoLibraryService.openSettings() }
        } header: {
            Text("Photos Access")
        } footer: {
            if library.isLimited {
                Text("""
                With limited access, Unposted only sees the photos you've picked. Decisions you've \
                already made for other photos are kept and reappear when you widen access.
                """)
            }
        }
    }

    private var maintenanceSection: some View {
        Section {
            Button {
                isCheckingMissing = true
                Task {
                    missingIdentifiers = store.missingMetadataIdentifiers()
                    isCheckingMissing = false
                    if missingIdentifiers.isEmpty {
                        statusMessage = "Nothing to clean up — every tracked photo is still in Apple Photos."
                    }
                }
            } label: {
                HStack {
                    Label("Check for Deleted Photos", systemImage: "magnifyingglass")
                    if isCheckingMissing {
                        Spacer()
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .disabled(isCheckingMissing)

            if !missingIdentifiers.isEmpty {
                Button(role: .destructive) {
                    let count = missingIdentifiers.count
                    store.purgeMetadata(for: missingIdentifiers)
                    missingIdentifiers = []
                    statusMessage = "Removed metadata for \(count) photo\(count == 1 ? "" : "s") that are no longer in Apple Photos."
                } label: {
                    Label("Clean Up \(missingIdentifiers.count) Entr\(missingIdentifiers.count == 1 ? "y" : "ies")", systemImage: "trash")
                }
            }
        } header: {
            Text("Maintenance")
        } footer: {
            Text("""
            Photos deleted outside the app leave metadata behind. Cleaning up removes it and drops \
            those photos from unpublished posts; published posts keep their record.
            """)
        }
    }

    private var dataSection: some View {
        Section {
            Button {
                isExporting = true
            } label: {
                Label("Export Backup", systemImage: "square.and.arrow.up")
            }
            Button {
                isImporting = true
            } label: {
                Label("Import Backup", systemImage: "square.and.arrow.down")
            }
            Button(role: .destructive) {
                isConfirmingReset = true
            } label: {
                Label("Reset All Data", systemImage: "exclamationmark.triangle")
            }
        } header: {
            Text("Backup")
        } footer: {
            Text("A backup contains your review decisions and your posts, including each platform's publication date. It never contains photo data.")
        }
    }

    private var aboutSection: some View {
        Section {
            Text("""
            Unposted is local-first. Your photos and albums stay in Apple Photos; this app stores \
            only your review decisions and the posts you build, on this device.
            """)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private var accessDescription: String {
        switch library.authorization {
        case .authorized: "All Photos"
        case .limited: "Limited selection"
        case .denied: "Denied"
        case .restricted: "Restricted"
        case .notDetermined: "Not requested"
        @unknown default: "Unknown"
        }
    }
}
