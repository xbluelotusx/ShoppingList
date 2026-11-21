import Foundation
import SwiftData

/// One entry on the shopping list.
///
/// There is at most one `ListItem` per name (case-insensitive), ever. Deleting an
/// item marks it removed (`removedAt`) instead of erasing it, so the removal can be
/// sent to every phone in the household. Adding the same name again brings the
/// removed item back.
@Model
final class ListItem {
    var id: UUID
    /// Trimmed, stored as typed on first entry; matched case-insensitively.
    var name: String
    var isChecked: Bool
    /// Sorts the active section (oldest first).
    var addedAt: Date
    /// Sorts the checked section (oldest first). Nil while the item is active.
    var checkedAt: Date?
    /// Set when the item is deleted or cleared. Removed items are hidden everywhere.
    var removedAt: Date?
    /// Stored as optionals so a store written by the version before sharing
    /// (which has no such columns) opens with SwiftData's automatic migration.
    /// Rows from that version read as nil. Use `modifiedAt` and `needsUpload`.
    /// `originalName` also covers stores written by the first sharing build,
    /// where these were non-optional columns named `modifiedAt` / `needsUpload`.
    @Attribute(originalName: "modifiedAt") var storedModifiedAt: Date?
    @Attribute(originalName: "needsUpload") var storedNeedsUpload: Bool?

    /// Last local or remote change. The newer side wins when phones disagree.
    /// Items from before sharing count as older than any change.
    var modifiedAt: Date {
        get { storedModifiedAt ?? .distantPast }
        set { storedModifiedAt = newValue }
    }

    /// True while this phone has a change iCloud has not received yet.
    /// Items that existed before sharing read as true, so they are uploaded once.
    var needsUpload: Bool {
        get { storedNeedsUpload ?? true }
        set { storedNeedsUpload = newValue }
    }

    init(
        id: UUID = UUID(),
        name: String,
        isChecked: Bool = false,
        addedAt: Date = Date(),
        checkedAt: Date? = nil,
        removedAt: Date? = nil,
        modifiedAt: Date = Date(),
        needsUpload: Bool = true
    ) {
        self.id = id
        self.name = name
        self.isChecked = isChecked
        self.addedAt = addedAt
        self.checkedAt = checkedAt
        self.removedAt = removedAt
        self.storedModifiedAt = modifiedAt
        self.storedNeedsUpload = needsUpload
    }

    var isRemoved: Bool { removedAt != nil }
}

/// A remembered item name used for suggestions. Names are unique case-insensitively
/// (enforced by `ListStore`, since SwiftData uniqueness is case-sensitive).
/// History is shared with the household like the list.
@Model
final class HistoryItem {
    var name: String
    var useCount: Int
    var lastUsedAt: Date
    /// Optional in storage for the same migration reason as `ListItem`.
    @Attribute(originalName: "modifiedAt") var storedModifiedAt: Date?
    @Attribute(originalName: "needsUpload") var storedNeedsUpload: Bool?

    /// Last local or remote change. The newer side wins when phones disagree.
    var modifiedAt: Date {
        get { storedModifiedAt ?? .distantPast }
        set { storedModifiedAt = newValue }
    }

    /// True while this phone has a change iCloud has not received yet.
    var needsUpload: Bool {
        get { storedNeedsUpload ?? true }
        set { storedNeedsUpload = newValue }
    }

    init(
        name: String,
        useCount: Int = 1,
        lastUsedAt: Date = Date(),
        modifiedAt: Date = Date(),
        needsUpload: Bool = true
    ) {
        self.name = name
        self.useCount = useCount
        self.lastUsedAt = lastUsedAt
        self.storedModifiedAt = modifiedAt
        self.storedNeedsUpload = needsUpload
    }
}
