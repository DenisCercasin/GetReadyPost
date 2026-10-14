import Photos
import SwiftUI

/// Side-by-side comparison of near-duplicate shots, so picking one keeper out of five similar
/// frames doesn't require remembering what the previous one looked like.
struct CompareView: View {
    let identifiers: [String]

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: PhotoLibraryService
    @EnvironmentObject private var store: WorkflowStore

    @State private var focusedIdentifier: String?
    @State private var isSplit = false

    private var assets: [PHAsset] { library.assets(for: identifiers) }

    private var focused: PHAsset? {
        guard let focusedIdentifier else { return assets.first }
        return assets.first { $0.localIdentifier == focusedIdentifier } ?? assets.first
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Group {
                if isSplit {
                    SplitCompareView(assets: Array(assets.prefix(4)))
                } else if let focused {
                    ZoomableAssetView(asset: focused) {}
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .background {
                        LinearGradient(
                            colors: [.black.opacity(0.85), .black.opacity(0)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .ignoresSafeArea(edges: .top)
                    }
                Spacer(minLength: 0)
                VStack(spacing: 0) {
                    filmstrip
                    actions
                }
                .background {
                    LinearGradient(
                        colors: [.black.opacity(0), .black.opacity(0.9)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .ignoresSafeArea(edges: .bottom)
                }
            }
        }
        .onAppear { focusedIdentifier = focusedIdentifier ?? identifiers.first }
    }

    private var header: some View {
        HStack {
            Button("Done") { dismiss() }
                .font(.body.weight(.semibold))

            Spacer()

            Text("\(assets.count) Similar Shots")
                .font(.footnote.weight(.semibold))

            Spacer()

            Button {
                isSplit.toggle()
            } label: {
                Image(systemName: isSplit ? "rectangle" : "rectangle.split.2x2")
                    .font(.body.weight(.semibold))
            }
            .accessibilityLabel(isSplit ? "Show one at a time" : "Show side by side")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var filmstrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(assets, id: \.localIdentifier) { asset in
                    let identifier = asset.localIdentifier
                    let state = store.reviewState(for: identifier)
                    AssetThumbnailView(asset: asset, targetSize: CGSize(width: 180, height: 180))
                        .frame(width: 62, height: 62)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(
                                    identifier == (focusedIdentifier ?? assets.first?.localIdentifier) ? Color.white : .clear,
                                    lineWidth: 2.5
                                )
                        }
                        .overlay(alignment: .bottomTrailing) {
                            if state != .undecided {
                                Image(systemName: state.symbolName)
                                    .font(.caption2)
                                    .foregroundStyle(state == .keep ? .green : state == .deletionQueue ? .red : .white)
                                    .padding(2)
                                    .background(.black.opacity(0.55), in: Circle())
                                    .padding(3)
                            }
                        }
                        .onTapGesture { focusedIdentifier = identifier }
                        .accessibilityLabel(
                            "\(asset.creationDate?.formatted(date: .omitted, time: .standard) ?? "Photo")\(state == .undecided ? "" : ", \(state.title)")"
                        )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .scrollIndicators(.hidden)
    }

    private var actions: some View {
        VStack(spacing: 8) {
            Button {
                keepFocusedAndQueueOthers()
            } label: {
                Label("Keep This One, Queue the Rest", systemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(focused == nil)

            HStack(spacing: 8) {
                Button {
                    guard let identifier = focused?.localIdentifier else { return }
                    store.apply(.keep, to: [identifier])
                } label: {
                    Label("Keep", systemImage: "checkmark")
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.white)

                Button {
                    guard let identifier = focused?.localIdentifier else { return }
                    store.apply(.deletionQueue, to: [identifier])
                    moveToNext(after: identifier)
                } label: {
                    Label("Queue", systemImage: "trash")
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.red)

                Button {
                    store.apply(.keep, to: identifiers)
                } label: {
                    Label("Keep All", systemImage: "square.stack")
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }
            .font(.footnote)
            .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    /// The core comparison decision: one winner, the rest collected for batch deletion.
    private func keepFocusedAndQueueOthers() {
        guard let keeper = focused?.localIdentifier else { return }
        store.apply(.keep, to: [keeper], undoLabel: "Picked a keeper from \(identifiers.count)")
        let others = identifiers.filter { $0 != keeper }
        guard !others.isEmpty else { return }
        store.apply(.deletionQueue, to: others, undoLabel: "Queued \(others.count) similar shot\(others.count == 1 ? "" : "s")")
    }

    private func moveToNext(after identifier: String) {
        guard let position = assets.firstIndex(where: { $0.localIdentifier == identifier }) else { return }
        let next = assets.indices.contains(position + 1) ? position + 1 : max(0, position - 1)
        focusedIdentifier = assets.indices.contains(next) ? assets[next].localIdentifier : nil
    }
}

/// Up to four shots at once, for judging sharpness and expression across a burst.
struct SplitCompareView: View {
    let assets: [PHAsset]

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { proxy in
            let columns = assets.count <= 2 ? 1 : 2
            let rows = Int(ceil(Double(assets.count) / Double(columns)))
            let width = proxy.size.width / CGFloat(columns)
            let height = proxy.size.height / CGFloat(max(rows, 1))

            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(width), spacing: 0), count: columns),
                spacing: 0
            ) {
                ForEach(assets, id: \.localIdentifier) { asset in
                    AssetThumbnailView(
                        asset: asset,
                        targetSize: CGSize(width: width * displayScale, height: height * displayScale),
                        contentMode: .fit
                    )
                    .frame(width: width, height: height)
                }
            }
        }
    }
}
