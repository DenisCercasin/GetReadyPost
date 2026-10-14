import Photos
import SwiftUI

/// A day-sectioned, lazily-loaded photo grid — the app's main surface.
///
/// Cell size is computed once per layout pass and handed to every cell so PhotoKit requests share
/// one target size, which keeps `PHCachingImageManager` effective.
struct PhotoGridView: View {
    let assets: [PHAsset]
    @Binding var selection: Set<String>
    let isSelecting: Bool
    let onOpen: (PHAsset) -> Void
    let onAddToPost: ([String]) -> Void

    @EnvironmentObject private var store: WorkflowStore
    @Environment(\.displayScale) private var displayScale

    private let columnCount = 3
    private let spacing: CGFloat = 2

    var body: some View {
        GeometryReader { proxy in
            let side = max(1, (proxy.size.width - spacing * CGFloat(columnCount - 1)) / CGFloat(columnCount))
            let target = CGSize(width: side * displayScale, height: side * displayScale)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14, pinnedViews: [.sectionHeaders]) {
                    ForEach(sections) { section in
                        Section {
                            LazyVGrid(
                                columns: Array(repeating: GridItem(.fixed(side), spacing: spacing), count: columnCount),
                                spacing: spacing
                            ) {
                                ForEach(section.entries, id: \.asset.localIdentifier) { entry in
                                    cell(entry: entry, side: side, target: target)
                                }
                            }
                        } header: {
                            sectionHeader(section)
                        }
                    }
                }
                .padding(.bottom, 24)
            }
            .scrollIndicators(.automatic)
            .onAppear { ThumbnailProvider.shared.reset(assets: assets, targetSize: target) }
            .onChange(of: contentsKey) { _, _ in
                ThumbnailProvider.shared.reset(assets: assets, targetSize: target)
            }
        }
    }

    @ViewBuilder
    private func cell(entry: Entry, side: CGFloat, target: CGSize) -> some View {
        let identifier = entry.asset.localIdentifier
        PhotoGridCell(
            asset: entry.asset,
            targetSize: target,
            side: side,
            state: store.reviewState(for: identifier),
            usage: store.usage(for: identifier),
            wasPreviouslyPosted: store.wasPreviouslyPosted(identifier),
            isSelected: selection.contains(identifier),
            isSelecting: isSelecting
        )
        .onTapGesture {
            if isSelecting {
                toggle(identifier)
            } else {
                onOpen(entry.asset)
            }
        }
        .onAppear { ThumbnailProvider.shared.noteVisible(index: entry.index) }
        .contextMenu {
            PhotoQuickActionsMenu(identifiers: [identifier], onAddToPost: onAddToPost)
        }
    }

    private func sectionHeader(_ section: DaySection) -> some View {
        HStack {
            Text(section.title)
                .font(.title3.weight(.semibold))
            Spacer()
            if isSelecting {
                Button(allSelected(section) ? "Deselect" : "Select All") {
                    let ids = section.entries.map(\.asset.localIdentifier)
                    if allSelected(section) {
                        selection.subtract(ids)
                    } else {
                        selection.formUnion(ids)
                    }
                }
                .font(.footnote.weight(.medium))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    private func allSelected(_ section: DaySection) -> Bool {
        section.entries.allSatisfy { selection.contains($0.asset.localIdentifier) }
    }

    private func toggle(_ identifier: String) {
        if selection.contains(identifier) {
            selection.remove(identifier)
        } else {
            selection.insert(identifier)
        }
    }

    /// Cheap stand-in for "the backing list changed". Comparing counts alone misses a filter
    /// switch that happens to return the same number of photos.
    private var contentsKey: String {
        "\(assets.count)|\(assets.first?.localIdentifier ?? "")|\(assets.last?.localIdentifier ?? "")"
    }

    // MARK: Day sections

    struct Entry {
        let index: Int
        let asset: PHAsset
    }

    struct DaySection: Identifiable {
        let id: String
        let title: String
        let entries: [Entry]
    }

    /// Groups the (already newest-first) assets by capture day, the way Apple Photos does.
    private var sections: [DaySection] {
        let calendar = Calendar.current
        var result: [DaySection] = []
        var currentKey: Date?
        var current: [Entry] = []

        func flush() {
            guard let key = currentKey, !current.isEmpty else { current = []; return }
            result.append(DaySection(id: key.description, title: Self.title(for: key), entries: current))
            current = []
        }

        for (index, asset) in assets.enumerated() {
            let day = calendar.startOfDay(for: asset.creationDate ?? Date.distantPast)
            if day != currentKey {
                flush()
                currentKey = day
            }
            current.append(Entry(index: index, asset: asset))
        }
        flush()
        return result
    }

    private static func title(for day: Date) -> String {
        if day == Date.distantPast { return "Undated" }
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(date: .abbreviated, time: .omitted)
    }
}

// MARK: - Cell

struct PhotoGridCell: View {
    let asset: PHAsset
    let targetSize: CGSize
    let side: CGFloat
    let state: ReviewState
    let usage: PhotoUsage
    let wasPreviouslyPosted: Bool
    let isSelected: Bool
    let isSelecting: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            AssetThumbnailView(asset: asset, targetSize: targetSize)
                .frame(width: side, height: side)
                // Ignored and queued photos read as set aside without being hidden.
                .opacity(isDimmed ? 0.45 : 1)
                .overlay {
                    if isSelecting && isSelected {
                        Rectangle().fill(Color.accentColor.opacity(0.25))
                    }
                }

            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(isSelected ? .white : .white.opacity(0.9), isSelected ? Color.accentColor : .clear)
                    .shadow(color: .black.opacity(0.4), radius: 2)
                    .padding(5)
            } else {
                PhotoStateBadges(state: state, usage: usage, wasPreviouslyPosted: wasPreviouslyPosted)
            }
        }
        .frame(width: side, height: side)
        .contentShape(Rectangle())
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var isDimmed: Bool {
        !isSelecting && (state == .ignored || state == .deletionQueue)
    }

    private var accessibilityLabel: String {
        var parts = [asset.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? "Photo"]
        if state != .undecided { parts.append(state.title) }
        let published = Platform.allCases.filter { usage.publishedPlatforms.contains($0) }
        if !published.isEmpty {
            parts.append("Published on " + published.map(\.title).joined(separator: " and "))
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Quick actions

/// The same four decisions as Review mode, available from a long press anywhere in the gallery.
/// Buttons keep the actions discoverable; the swipes in Review mode are an accelerator, not the
/// only route.
struct PhotoQuickActionsMenu: View {
    let identifiers: [String]
    /// Presenting a sheet from inside `contextMenu` content doesn't work, so the owning screen
    /// presents it.
    let onAddToPost: ([String]) -> Void

    @EnvironmentObject private var store: WorkflowStore

    var body: some View {
        Group {
            Button {
                store.apply(.keep, to: identifiers)
            } label: {
                Label("Keep for Posting", systemImage: "checkmark.circle")
            }

            Button {
                store.apply(.ignored, to: identifiers)
            } label: {
                Label("Ignore", systemImage: "eye.slash")
            }

            Button {
                onAddToPost(identifiers)
            } label: {
                Label("Add to Post…", systemImage: "square.stack.badge.plus")
            }

            if identifiers.contains(where: { store.reviewState(for: $0) != .undecided }) {
                Button {
                    store.apply(.undecided, to: identifiers)
                } label: {
                    Label("Clear Decision", systemImage: "arrow.uturn.backward")
                }
            }

            Divider()

            Button(role: .destructive) {
                store.apply(.deletionQueue, to: identifiers)
            } label: {
                Label("Queue for Deletion", systemImage: "trash")
            }
        }
    }
}
