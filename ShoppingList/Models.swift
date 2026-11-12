import Foundation
import SwiftData

/// One entry on the shopping list.
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

    init(
        id: UUID = UUID(),
        name: String,
        isChecked: Bool = false,
        addedAt: Date = Date(),
        checkedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.isChecked = isChecked
        self.addedAt = addedAt
        self.checkedAt = checkedAt
    }
}

/// A remembered item name used for suggestions. Names are unique case-insensitively
/// (enforced by `ListStore`, since SwiftData uniqueness is case-sensitive).
@Model
final class HistoryItem {
    var name: String
    var useCount: Int
    var lastUsedAt: Date

    init(name: String, useCount: Int = 1, lastUsedAt: Date = Date()) {
        self.name = name
        self.useCount = useCount
        self.lastUsedAt = lastUsedAt
    }
}
