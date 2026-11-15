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
    /// Last local or remote change. The newer side wins when phones disagree.
    var modifiedAt: Date = Date.distantPast
    /// True while this phone has a change iCloud has not received yet.
    /// Defaults to true so items that existed before sharing are uploaded once.
    var needsUpload: Bool = true

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
        self.modifiedAt = modifiedAt
        self.needsUpload = needsUpload
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
    /// Last local or remote change. The newer side wins when phones disagree.
    var modifiedAt: Date = Date.distantPast
    /// True while this phone has a change iCloud has not received yet.
    var needsUpload: Bool = true

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
        self.modifiedAt = modifiedAt
        self.needsUpload = needsUpload
    }
}
