import Foundation
import Photos

/// A run of photos taken in one sitting. Used to offer "review this shoot" without asking the
/// user to build an album first.
struct Shoot: Identifiable, Hashable {
    let id: String
    let assetIdentifiers: [String]
    let start: Date
    let end: Date

    var count: Int { assetIdentifiers.count }

    var title: String {
        let calendar = Calendar.current
        if calendar.isDate(start, inSameDayAs: end) {
            return start.formatted(date: .abbreviated, time: .omitted)
        }
        return "\(start.formatted(date: .abbreviated, time: .omitted)) – \(end.formatted(date: .abbreviated, time: .omitted))"
    }

    var subtitle: String {
        let time = start.formatted(date: .omitted, time: .shortened)
        return "\(count) photo\(count == 1 ? "" : "s") · from \(time)"
    }
}

/// Groups of near-duplicate shots: an Apple Photos burst, or a run of frames taken seconds apart.
struct SimilarGroupIndex {
    /// Group id per asset identifier. Assets with no near-duplicates are absent.
    private let groupByAsset: [String: Int]
    private let groups: [[String]]

    init(groupByAsset: [String: Int] = [:], groups: [[String]] = []) {
        self.groupByAsset = groupByAsset
        self.groups = groups
    }

    /// Every identifier in the same burst / near-duplicate run as `identifier`, in capture order,
    /// or an empty array when the photo has no siblings.
    func group(for identifier: String) -> [String] {
        guard let index = groupByAsset[identifier], groups.indices.contains(index) else { return [] }
        return groups[index]
    }

    func hasSiblings(_ identifier: String) -> Bool {
        group(for: identifier).count > 1
    }
}

enum AssetGrouping {
    /// Splits a newest-first asset list wherever consecutive captures are more than `gap` apart.
    static func shoots(
        from assets: [PHAsset],
        gap: TimeInterval = 6 * 3600,
        minimumCount: Int = 2,
        limit: Int = 60
    ) -> [Shoot] {
        guard !assets.isEmpty else { return [] }
        var result: [Shoot] = []
        var current: [PHAsset] = []

        func flush() {
            defer { current = [] }
            guard current.count >= minimumCount else { return }
            // `current` is newest-first; present it oldest-first within the shoot.
            let ordered = current.reversed().map(\.localIdentifier)
            let dates = current.compactMap(\.creationDate)
            guard let start = dates.min(), let end = dates.max(),
                  let id = current.last?.localIdentifier
            else { return }
            result.append(Shoot(id: id, assetIdentifiers: ordered, start: start, end: end))
        }

        for asset in assets {
            guard let date = asset.creationDate else { continue }
            if let previous = current.last?.creationDate, previous.timeIntervalSince(date) > gap {
                flush()
            }
            current.append(asset)
            if result.count >= limit { break }
        }
        flush()
        return Array(result.prefix(limit))
    }

    /// Builds the near-duplicate index. Bursts group by `burstIdentifier`; everything else groups
    /// by capture proximity, which catches the "I took five of the same shot" case.
    static func similarGroups(
        from assets: [PHAsset],
        window: TimeInterval = 10
    ) -> SimilarGroupIndex {
        guard assets.count > 1 else { return SimilarGroupIndex() }

        var groups: [[String]] = []
        var groupByAsset: [String: Int] = [:]
        var burstGroupIndex: [String: Int] = [:]
        var run: [PHAsset] = []

        func commit(_ identifiers: [String]) {
            guard identifiers.count > 1 else { return }
            let index = groups.count
            groups.append(identifiers)
            for id in identifiers { groupByAsset[id] = index }
        }

        func flushRun() {
            defer { run = [] }
            commit(run.reversed().map(\.localIdentifier))
        }

        for asset in assets {
            if let burst = asset.burstIdentifier {
                flushRun()
                if let index = burstGroupIndex[burst] {
                    groups[index].append(asset.localIdentifier)
                    groupByAsset[asset.localIdentifier] = index
                } else {
                    let index = groups.count
                    groups.append([asset.localIdentifier])
                    groupByAsset[asset.localIdentifier] = index
                    burstGroupIndex[burst] = index
                }
                continue
            }
            guard let date = asset.creationDate else {
                flushRun()
                continue
            }
            if let previous = run.last?.creationDate, previous.timeIntervalSince(date) > window {
                flushRun()
            }
            run.append(asset)
        }
        flushRun()

        // Bursts seeded with a single frame are not comparison groups.
        let singletons = groupByAsset.filter { groups[$0.value].count < 2 }.map(\.key)
        for identifier in singletons { groupByAsset.removeValue(forKey: identifier) }

        return SimilarGroupIndex(groupByAsset: groupByAsset, groups: groups)
    }
}
