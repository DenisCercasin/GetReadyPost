import Foundation

/// What the gallery is showing. Deliberately a flat list of answerable questions rather than a
/// matrix of toggles, so the filter stays one unobtrusive menu instead of a dashboard.
enum GalleryScope: String, CaseIterable, Identifiable, Hashable {
    /// Everything the app can see, ignored photos included.
    case allPhotos
    case needsReview
    case keepers
    /// Keepers not yet published anywhere.
    case availableToPost
    case unusedOnInstagram
    case unusedOnLinkedIn
    case usedOnInstagram
    case usedOnLinkedIn
    /// Imported from the previous version's global `Posted` flag, platform unknown.
    case previouslyPosted
    case ignored
    case deletionQueue

    var id: String { rawValue }

    /// Section the scope appears under in the filter menu.
    enum Group: Int, CaseIterable {
        case library
        case posting
        case used
        case housekeeping

        var title: String {
            switch self {
            case .library: "Library"
            case .posting: "Ready to Use"
            case .used: "Already Used"
            case .housekeeping: "Set Aside"
            }
        }
    }

    var group: Group {
        switch self {
        case .allPhotos, .needsReview: .library
        case .keepers, .availableToPost, .unusedOnInstagram, .unusedOnLinkedIn: .posting
        case .usedOnInstagram, .usedOnLinkedIn, .previouslyPosted: .used
        case .ignored, .deletionQueue: .housekeeping
        }
    }

    var title: String {
        switch self {
        case .allPhotos: "All Photos"
        case .needsReview: "Needs Review"
        case .keepers: "Keepers"
        case .availableToPost: "Available to Post"
        case .unusedOnInstagram: "Not on Instagram"
        case .unusedOnLinkedIn: "Not on LinkedIn"
        case .usedOnInstagram: "Posted to Instagram"
        case .usedOnLinkedIn: "Posted to LinkedIn"
        case .previouslyPosted: "Previously Posted"
        case .ignored: "Ignored"
        case .deletionQueue: "Deletion Queue"
        }
    }

    var symbolName: String {
        switch self {
        case .allPhotos: "photo.on.rectangle.angled"
        case .needsReview: "circle.dashed"
        case .keepers: "checkmark.circle"
        case .availableToPost: "sparkles"
        case .unusedOnInstagram: "camera"
        case .unusedOnLinkedIn: "briefcase"
        case .usedOnInstagram: "camera.fill"
        case .usedOnLinkedIn: "briefcase.fill"
        case .previouslyPosted: "clock.arrow.circlepath"
        case .ignored: "eye.slash"
        case .deletionQueue: "trash"
        }
    }

    /// Shown under the navigation title so the active filter is always legible.
    var caption: String? {
        switch self {
        case .allPhotos: nil
        case .needsReview: "No decision yet"
        case .keepers: "Kept for posting"
        case .availableToPost: "Keepers not published anywhere"
        case .unusedOnInstagram: "Keepers still unposted on Instagram"
        case .unusedOnLinkedIn: "Keepers still unposted on LinkedIn"
        case .usedOnInstagram: "Published on Instagram"
        case .usedOnLinkedIn: "Published on LinkedIn"
        case .previouslyPosted: "Imported from the old Posted flag"
        case .ignored: "Kept in Photos, never posted"
        case .deletionQueue: "Waiting for batch delete"
        }
    }

    var emptyMessage: String {
        switch self {
        case .allPhotos: "No photos in your library yet."
        case .needsReview: "Everything has been reviewed. Nice."
        case .keepers: "Review a shoot and tap Keep to build your posting pool."
        case .availableToPost: "Every keeper has been published somewhere."
        case .unusedOnInstagram: "Every keeper has gone out on Instagram."
        case .unusedOnLinkedIn: "Every keeper has gone out on LinkedIn."
        case .usedOnInstagram: "Nothing marked published on Instagram yet."
        case .usedOnLinkedIn: "Nothing marked published on LinkedIn yet."
        case .previouslyPosted: "Nothing was imported from the previous version."
        case .ignored: "Photos you ignore stay in Apple Photos and show up here."
        case .deletionQueue: "Photos you queue for deletion collect here."
        }
    }

    /// Scopes offered in the filter menu. `previouslyPosted` is hidden unless there is something
    /// in it, so a clean install never sees a migration-only filter.
    static func menuScopes(includePreviouslyPosted: Bool) -> [GalleryScope] {
        allCases.filter { $0 != .previouslyPosted || includePreviouslyPosted }
    }
}
