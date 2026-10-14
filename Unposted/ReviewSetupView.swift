import Photos
import SwiftUI

/// Chooses what to review: a detected shoot, an album, a date range, or everything undecided.
struct ReviewSetupView: View {
    let onStart: (ReviewRequest) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: PhotoLibraryService
    @EnvironmentObject private var store: WorkflowStore

    @State private var onlyUndecided = true
    @State private var rangeStart = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .now
    @State private var rangeEnd = Date.now
    @State private var isShowingDateRange = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Skip photos I've already decided on", isOn: $onlyUndecided)
                        .font(.subheadline)
                } footer: {
                    Text("A review queue only includes photos without a decision when this is on.")
                }

                Section("Quick Start") {
                    row(
                        title: "Everything Needing Review",
                        subtitle: "\(undecidedIdentifiers.count) photo\(undecidedIdentifiers.count == 1 ? "" : "s")",
                        symbol: "circle.dashed",
                        identifiers: undecidedIdentifiers,
                        label: "Needs Review"
                    )
                    Button {
                        isShowingDateRange = true
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Date Range…").foregroundStyle(.primary)
                                Text("Pick a start and end date")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "calendar")
                        }
                    }
                }

                if !shoots.isEmpty {
                    Section {
                        ForEach(shoots) { shoot in
                            let filtered = apply(filter: shoot.assetIdentifiers)
                            row(
                                title: shoot.title,
                                subtitle: subtitle(for: shoot, filteredCount: filtered.count),
                                symbol: "camera.aperture",
                                identifiers: filtered,
                                label: shoot.title
                            )
                        }
                    } header: {
                        Text("Recent Shoots")
                    } footer: {
                        Text("Shoots are runs of photos taken in one sitting, detected from capture times.")
                    }
                }

                if !library.albums.isEmpty {
                    Section("Albums") {
                        ForEach(library.albums) { album in
                            AlbumReviewRow(album: album, onlyUndecided: onlyUndecided) { identifiers in
                                start(identifiers, label: album.title)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Start a Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $isShowingDateRange) {
                DateRangeReviewView(
                    start: $rangeStart,
                    end: $rangeEnd,
                    identifiers: { apply(filter: identifiers(in: $0, to: $1)) },
                    onStart: { identifiers, label in
                        isShowingDateRange = false
                        start(identifiers, label: label)
                    }
                )
            }
        }
    }

    // MARK: Data

    private var shoots: [Shoot] { library.shoots }

    private var undecidedIdentifiers: [String] {
        _ = store.revision
        return library.assets.map(\.localIdentifier).filter { store.reviewState(for: $0) == .undecided }
    }

    /// Applies the "skip decided" toggle while preserving order.
    private func apply(filter identifiers: [String]) -> [String] {
        guard onlyUndecided else { return identifiers }
        return identifiers.filter { store.reviewState(for: $0) == .undecided }
    }

    private func identifiers(in start: Date, to end: Date) -> [String] {
        let calendar = Calendar.current
        let lower = calendar.startOfDay(for: min(start, end))
        let upper = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: max(start, end))) ?? max(start, end)
        return library.assets
            .filter { asset in
                guard let date = asset.creationDate else { return false }
                return date >= lower && date < upper
            }
            // Reviewing a range reads better oldest-first, like walking through the event.
            .reversed()
            .map(\.localIdentifier)
    }

    private func subtitle(for shoot: Shoot, filteredCount: Int) -> String {
        if onlyUndecided && filteredCount != shoot.count {
            return "\(filteredCount) of \(shoot.count) need review · from \(shoot.start.formatted(date: .omitted, time: .shortened))"
        }
        return shoot.subtitle
    }

    private func row(title: String, subtitle: String, symbol: String, identifiers: [String], label: String) -> some View {
        Button {
            start(identifiers, label: label)
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: symbol)
            }
        }
        .disabled(identifiers.isEmpty)
    }

    private func start(_ identifiers: [String], label: String) {
        guard !identifiers.isEmpty else { return }
        onStart(ReviewRequest(title: label, identifiers: identifiers, startAt: nil))
    }
}

/// Album row that resolves its member identifiers only when tapped, so opening the sheet doesn't
/// fetch every album's contents.
struct AlbumReviewRow: View {
    let album: AlbumSummary
    let onlyUndecided: Bool
    let onStart: ([String]) -> Void

    @EnvironmentObject private var library: PhotoLibraryService
    @EnvironmentObject private var store: WorkflowStore

    var body: some View {
        Button {
            var identifiers = library.assetIdentifiers(inAlbum: album.id)
            if onlyUndecided {
                identifiers = identifiers.filter { store.reviewState(for: $0) == .undecided }
            }
            onStart(identifiers)
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(album.title).foregroundStyle(.primary)
                    Text("\(album.count) photo\(album.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: album.kind == .smart ? "gearshape.2" : "rectangle.stack")
            }
        }
    }
}

/// Date-range picker with a live count, so the user knows what they're about to review.
struct DateRangeReviewView: View {
    @Binding var start: Date
    @Binding var end: Date
    let identifiers: (Date, Date) -> [String]
    let onStart: ([String], String) -> Void

    @Environment(\.dismiss) private var dismiss

    private var matches: [String] { identifiers(start, end) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("From", selection: $start, displayedComponents: .date)
                    DatePicker("To", selection: $end, in: start..., displayedComponents: .date)
                } footer: {
                    Text("\(matches.count) photo\(matches.count == 1 ? "" : "s") match.")
                }

                Section {
                    Button {
                        onStart(matches, label)
                    } label: {
                        Text("Review \(matches.count) Photo\(matches.count == 1 ? "" : "s")")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(matches.isEmpty)
                }
            }
            .navigationTitle("Date Range")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var label: String {
        let calendar = Calendar.current
        if calendar.isDate(start, inSameDayAs: end) {
            return start.formatted(date: .abbreviated, time: .omitted)
        }
        return "\(start.formatted(date: .abbreviated, time: .omitted)) – \(end.formatted(date: .abbreviated, time: .omitted))"
    }
}
