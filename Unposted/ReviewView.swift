import Photos
import SwiftUI

/// What to review: an explicit, ordered list of identifiers plus an optional starting point.
struct ReviewRequest: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let identifiers: [String]
    let startAt: String?
}

/// Focused review of one queue of photos.
///
/// Gesture contract, chosen so it can't collide with ordinary gallery browsing:
/// - horizontal drag = move between photos, exactly like the gallery viewer
/// - vertical drag = decide (up keeps, down queues for deletion)
/// - every action also has a button, so nothing is swipe-only
///
/// This mode is entered deliberately and has no swipe-to-dismiss, so a decision swipe can never
/// be read as "close the screen".
struct ReviewView: View {
    let request: ReviewRequest

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: PhotoLibraryService
    @EnvironmentObject private var store: WorkflowStore

    @State private var index = 0
    @State private var drag: CGSize = .zero
    @State private var isAnimatingOut = false
    @State private var compareGroup: [String]?
    @State private var addToPostIdentifiers: [String]?
    @State private var isFinished = false

    /// Horizontal/vertical travel needed before a drag counts as a decision.
    private let actionThreshold: CGFloat = 110
    private let navigationThreshold: CGFloat = 80

    private var identifiers: [String] { request.identifiers }

    private var currentIdentifier: String? {
        identifiers.indices.contains(index) ? identifiers[index] : nil
    }

    private var currentAsset: PHAsset? {
        currentIdentifier.flatMap { library.asset(for: $0) }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if isFinished || identifiers.isEmpty {
                ReviewSummaryView(request: request, onDone: { dismiss() })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Full-bleed photo with floating chrome, the way the system photo viewer works.
                // It also keeps the card immune to safe-area insets inherited from the presenter.
                card
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
                    footer
                        .background {
                            LinearGradient(
                                colors: [.black.opacity(0), .black.opacity(0.85)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .ignoresSafeArea(edges: .bottom)
                        }
                }
            }
        }
        .onAppear {
            if let startAt = request.startAt, let position = identifiers.firstIndex(of: startAt) {
                index = position
            }
        }
        .fullScreenCover(item: Binding(get: { compareGroup.map(IdentifierListBox.init) }, set: { compareGroup = $0?.identifiers })) { box in
            CompareView(identifiers: box.identifiers)
        }
        .sheet(item: Binding(get: { addToPostIdentifiers.map(IdentifierListBox.init) }, set: { addToPostIdentifiers = $0?.identifiers })) { box in
            AddToPostSheet(identifiers: box.identifiers)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            Button("Done") { dismiss() }
                .font(.body.weight(.semibold))

            Spacer()

            VStack(spacing: 2) {
                Text(request.title)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                Text("\(min(index + 1, identifiers.count)) of \(identifiers.count)")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
                    .monospacedDigit()
            }

            Spacer()

            Button {
                store.performUndo()
                goBack()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.body.weight(.semibold))
            }
            .disabled(store.undoAction == nil)
            .opacity(store.undoAction == nil ? 0.35 : 1)
            .accessibilityLabel("Undo last decision")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            ProgressView(value: Double(index), total: Double(max(identifiers.count, 1)))
                .tint(.white)
                .scaleEffect(y: 0.6)
                .padding(.horizontal, 18)
        }
    }

    // MARK: Card

    private var card: some View {
        GeometryReader { proxy in
            ZStack {
                if let asset = currentAsset {
                    ReviewCardImage(asset: asset)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .offset(x: drag.width, y: drag.height)
                        .rotationEffect(.degrees(Double(drag.width / 28)))
                        .overlay(alignment: .top) { pendingLabel(.keep, visible: drag.height < -40) }
                        .overlay(alignment: .bottom) { pendingLabel(.deletionQueue, visible: drag.height > 40) }
                        .gesture(dragGesture(width: proxy.size.width))
                } else if currentIdentifier != nil {
                    // The asset vanished from Photos while the review was open.
                    VStack(spacing: 12) {
                        Image(systemName: "questionmark.square.dashed").font(.largeTitle)
                        Text("This photo is no longer in Apple Photos.")
                            .font(.footnote)
                        Button("Skip") { advance() }
                            .buttonStyle(.borderedProminent)
                    }
                    .foregroundStyle(.white)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
        }
    }

    private func pendingLabel(_ state: ReviewState, visible: Bool) -> some View {
        Label(state == .keep ? "Keep" : "Queue for Deletion", systemImage: state.symbolName)
            .font(.headline)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                Capsule().fill(state == .keep ? Color.green.opacity(0.85) : Color.red.opacity(0.85))
            )
            .foregroundStyle(.white)
            .padding(24)
            .opacity(visible ? 1 : 0)
            .animation(.easeOut(duration: 0.12), value: visible)
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { value in
                guard !isAnimatingOut else { return }
                drag = value.translation
            }
            .onEnded { value in
                guard !isAnimatingOut else { return }
                let horizontal = value.translation.width
                let vertical = value.translation.height

                if abs(vertical) > abs(horizontal) {
                    if vertical < -actionThreshold {
                        decide(.keep, slideTo: CGSize(width: 0, height: -900))
                        return
                    }
                    if vertical > actionThreshold {
                        decide(.deletionQueue, slideTo: CGSize(width: 0, height: 900))
                        return
                    }
                } else if abs(horizontal) > navigationThreshold {
                    // Horizontal stays navigation, matching the gallery viewer.
                    horizontal < 0 ? advance() : goBack()
                    withAnimation(.none) { drag = .zero }
                    return
                }
                withAnimation(.spring(duration: 0.3)) { drag = .zero }
            }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 10) {
            if let identifier = currentIdentifier {
                HStack(spacing: 8) {
                    let state = store.reviewState(for: identifier)
                    if state != .undecided {
                        Label(state.title, systemImage: state.symbolName)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(.white.opacity(0.18)))
                            .foregroundStyle(.white)
                    }
                    PlatformUsageChips(
                        usage: store.usage(for: identifier),
                        wasPreviouslyPosted: store.wasPreviouslyPosted(identifier)
                    )
                    .environment(\.colorScheme, .dark)
                }

                let siblings = library.similarGroups.group(for: identifier)
                if siblings.count > 1 {
                    Button {
                        compareGroup = siblings
                    } label: {
                        Label("Compare \(siblings.count) Similar Shots", systemImage: "square.on.square.dashed")
                            .font(.footnote.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                }
            }

            HStack(spacing: 8) {
                button("Ignore", "eye.slash.fill", tint: .gray) {
                    decide(.ignored, slideTo: CGSize(width: -700, height: 120))
                }
                button("Delete", "trash.fill", tint: .red) {
                    decide(.deletionQueue, slideTo: CGSize(width: 0, height: 900))
                }
                button("Skip", "arrow.right.circle.fill", tint: .secondary) {
                    advance()
                }
                button("Keep", "checkmark.circle.fill", tint: .green) {
                    decide(.keep, slideTo: CGSize(width: 0, height: -900))
                }
            }

            Text("Swipe up to keep · down to queue · sideways to move between photos")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private func button(_ title: String, _ symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.title2)
                Text(title).font(.caption2.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(tint.opacity(0.22), in: RoundedRectangle(cornerRadius: 14))
            .foregroundStyle(tint == .secondary ? Color.white.opacity(0.85) : tint)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    // MARK: Navigation

    private func decide(_ state: ReviewState, slideTo target: CGSize) {
        guard let identifier = currentIdentifier, !isAnimatingOut else { return }
        isAnimatingOut = true
        store.apply(state, to: [identifier])
        withAnimation(.easeOut(duration: 0.22)) { drag = target }
        // Advance only after the card has left, so the decision reads as committed.
        Task {
            try? await Task.sleep(for: .milliseconds(220))
            drag = .zero
            isAnimatingOut = false
            advance()
        }
    }

    private func advance() {
        withAnimation(.none) { drag = .zero }
        if index + 1 < identifiers.count {
            index += 1
        } else {
            isFinished = true
        }
    }

    private func goBack() {
        withAnimation(.none) { drag = .zero }
        index = max(0, index - 1)
        isFinished = false
    }
}

// MARK: - Card image

/// Full-bleed image for the review card. Deliberately not zoomable: the card owns its gestures.
struct ReviewCardImage: View {
    let asset: PHAsset

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var isDegraded = false
    @State private var requestID: PHImageRequestID?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    ProgressView().tint(.white)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .task(id: asset.localIdentifier) {
                let target = CGSize(
                    width: max(proxy.size.width, 1) * displayScale,
                    height: max(proxy.size.height, 1) * displayScale
                )
                requestID = ThumbnailProvider.shared.requestDisplayImage(for: asset, size: target) { loaded, degraded in
                    guard let loaded else { return }
                    if degraded && image != nil && !isDegraded { return }
                    image = loaded
                    isDegraded = degraded
                }
            }
            .onDisappear {
                ThumbnailProvider.shared.cancel(requestID)
                requestID = nil
            }
        }
    }
}

// MARK: - Summary

/// Shown at the end of a review run so the session has a clear finish and an obvious next step.
struct ReviewSummaryView: View {
    let request: ReviewRequest
    let onDone: () -> Void

    @EnvironmentObject private var store: WorkflowStore
    @State private var isShowingDeletionQueue = false
    @State private var addToPostIdentifiers: [String]?

    private var counts: [ReviewState: Int] {
        var result: [ReviewState: Int] = [:]
        for identifier in request.identifiers {
            let state = store.reviewState(for: identifier)
            result[state, default: 0] += 1
        }
        return result
    }

    private var keepers: [String] {
        request.identifiers.filter { store.reviewState(for: $0) == .keep }
    }

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)

            VStack(spacing: 6) {
                Text("Review Complete")
                    .font(.title2.weight(.semibold))
                Text(request.title)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
            }

            VStack(spacing: 10) {
                summaryRow(.keep, count: counts[.keep] ?? 0)
                summaryRow(.ignored, count: counts[.ignored] ?? 0)
                summaryRow(.deletionQueue, count: counts[.deletionQueue] ?? 0)
                summaryRow(.undecided, count: counts[.undecided] ?? 0)
            }
            .frame(maxWidth: 320)

            VStack(spacing: 10) {
                if !keepers.isEmpty {
                    Button {
                        addToPostIdentifiers = keepers
                    } label: {
                        Label("Create a Post · \(keepers.count) Keeper\(keepers.count == 1 ? "" : "s")", systemImage: "square.stack.badge.plus")
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                if (counts[.deletionQueue] ?? 0) > 0 {
                    Button {
                        isShowingDeletionQueue = true
                    } label: {
                        Label("Review Deletion Queue", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
                Button("Done", action: onDone)
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: 320)
        }
        .padding(28)
        .foregroundStyle(.white)
        .sheet(isPresented: $isShowingDeletionQueue) { DeletionQueueView() }
        .sheet(item: Binding(get: { addToPostIdentifiers.map(IdentifierListBox.init) }, set: { addToPostIdentifiers = $0?.identifiers })) { box in
            AddToPostSheet(identifiers: box.identifiers)
        }
    }

    private func summaryRow(_ state: ReviewState, count: Int) -> some View {
        HStack {
            Label(state.title, systemImage: state.symbolName)
                .font(.subheadline)
            Spacer()
            Text("\(count)")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .opacity(count == 0 ? 0.45 : 1)
    }
}
