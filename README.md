# Unposted

A local-first companion for Apple Photos that turns a pile of event photos into finished social
posts. Review a shoot quickly, keep the good shots, collect the bad ones for a batch delete, build
a post, publish it by hand, and record what went out on which platform — so you can always find the
good photos you haven't used yet.

Originals and albums stay in Apple Photos. SwiftData stores only your review decisions and your
posts, on the device.

## The flow

**Review a shoot → keep or ignore → prepare a post → publish manually → mark its platform status →
find unused good photos later.**

1. **Gallery.** The photo grid is the main screen: day sections, a full-screen viewer, and a single
   filter menu in the toolbar. Long-press any photo for Keep / Ignore / Add to Post / Queue for
   deletion. Select mode applies the same actions to many photos at once.
2. **Review.** *Review* in the toolbar reviews exactly what the gallery is showing; *Start a
   Review…* in the overflow menu picks a detected shoot, an album, a date range, or everything
   undecided. Each photo gets four decisions — Keep, Ignore, Queue for deletion, Skip — the queue
   advances automatically, and Undo is always one tap away.
3. **Compare.** When a photo has near-duplicates (an Apple Photos burst, or frames seconds apart),
   Review offers *Compare N Similar Shots*: a filmstrip, a 1-up or 2×2 view, and one button that
   keeps the winner and queues the rest.
4. **Deletion queue.** Queued photos collect in a reviewable grid. *Delete from Apple Photos*
   deletes them in one batch; iOS presents its own required confirmation and the photos go to
   Recently Deleted. Cancelling changes nothing.
5. **Posts.** Build a post from one or many photos, drag to set the carousel order, add a caption,
   and choose Instagram, LinkedIn, or both. Posts are Draft → Ready to Post → Published.
6. **Publish.** You publish in the real app, then mark each destination published here, with its own
   date. A post going to both platforms can be published on each at a different time.

## How usage is tracked

There is no global "posted" flag. A photo's usage is derived from the posts it belongs to and each
post's **per-platform** publication date. A photo published on Instagram is still unused as far as
LinkedIn is concerned, and removing a photo from a draft — or leaving it out of the final post —
simply makes it available again.

The filter menu turns that into direct questions:

| Scope | Shows |
| --- | --- |
| All Photos | everything, ignored photos included |
| Needs Review | no decision yet |
| Keepers | kept for posting |
| Available to Post | keepers not published anywhere |
| Not on Instagram / Not on LinkedIn | **keepers you still haven't posted there** |
| Posted to Instagram / Posted to LinkedIn | published on that platform |
| Ignored | kept in Photos, never to be posted |
| Deletion Queue | waiting for the batch delete |

The Posts tab shows the same answer as two counters: *keepers still unposted* on each platform.

Ignored photos stay in Apple Photos and remain visible under **All Photos**, but never appear in
the posting pool or the photo picker.

## State model

`PhotoRecord` holds one `ReviewState` per asset (`undecided` / `keep` / `ignored` / `deletionQueue`)
keyed by `PHAsset.localIdentifier`. `Post` holds an ordered list of identifiers, a caption, a
destination set, and one optional publication date per platform; `PostStatus` derives `published`
from those dates so status and publication can never disagree.

`PHPhotoLibraryChangeObserver` reloads the index after Photos changes. Fetching and album scanning
happen off the main thread, the grid uses fixed-size cells with a sliding `PHCachingImageManager`
window plus a decoded-image cache, and full-resolution requests happen only in the viewer, the
review card, and Compare.

## Migrating from the previous version

The old `Posted` / `Ignored` flags and Posting Albums are migrated once, on first launch, and a
one-time sheet explains what happened:

- `Ignored` → `ReviewState.ignored`.
- `Posted` → a **keeper** tagged *Previously posted*. The old flag recorded no platform, so it is
  never claimed as an Instagram or LinkedIn publication. Those photos are excluded from
  "Available to Post" and the per-platform "Not on…" filters, and have their own **Previously
  Posted** filter so you can assign them to real posts.
- Posting Album membership → `keep`, since those photos had already been curated as good for
  posting. Posting Albums no longer drive state; your Apple Photos albums are untouched.

Legacy rows are kept in the store rather than deleted, so the migration can be re-derived.
Backups are version 2 (review states + posts, including each platform's publication date) and
version 1 files still import through the same mapping.

## Gestures

Ordinary browsing never changes a photo's state:

- **Gallery / viewer** — tap to open, swipe sideways to page, pinch or double-tap to zoom, tap to
  hide the chrome. No action swipes.
- **Review mode** — entered deliberately, and the only place with action swipes: **up** keeps,
  **down** queues for deletion, **sideways** moves between photos (the same direction as the
  viewer). Every one of those actions also has a button, and there is no swipe-to-dismiss, so a
  decision swipe can never be read as "close this screen".

## Limited Photos access

With limited access a banner reports how many photos are visible and offers *Manage* to widen the
selection without leaving the app. Decisions made for photos outside the selection are kept and
reappear when access widens.

## Run on an iPhone

1. Open `Unposted.xcodeproj` in Xcode 15 or newer.
2. In the **Unposted** target's Signing & Capabilities, pick your team and set a unique bundle
   identifier if needed.
3. Select your iPhone and Run. Approve Photos access when prompted.

Deployment target is iOS 17. The target's generated Info.plist includes
`NSPhotoLibraryUsageDescription` and `NSPhotoLibraryAddUsageDescription`.

## Source layout

| File | Role |
| --- | --- |
| `WorkflowModels.swift` | `ReviewState`, `Platform`, `PhotoRecord`, `Post`, legacy v1 models, schema |
| `WorkflowStore.swift` | all metadata mutations, the derived usage index, filtering, undo, backup |
| `LegacyMigrator.swift` | one-time v1 → v2 migration |
| `GalleryFilter.swift` | `GalleryScope` — the filter menu's vocabulary |
| `PhotoLibraryService.swift` | authorization, asset/album index, change observation, batch delete |
| `ThumbnailProvider.swift` | caching image manager, sliding prefetch window, decoded-image cache |
| `AssetGrouping.swift` | shoot detection and near-duplicate grouping |
| `LibraryView.swift` / `PhotoGridView.swift` | the gallery |
| `PhotoViewerView.swift` | full-screen browsing |
| `ReviewView.swift` / `ReviewSetupView.swift` / `CompareView.swift` | focused review |
| `DeletionQueueView.swift` | the reviewable batch delete |
| `PostsView.swift` / `PostEditorView.swift` / `AssetPickerView.swift` | post preparation |
| `SettingsView.swift` | access, maintenance, backup |
