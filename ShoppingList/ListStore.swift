import Foundation
import SwiftData

/// Pure rules with no persistence. Used by both `ListStore` and the view so the
/// view never re-implements business logic.
enum ListRules {
    /// More checked items than this asks for confirmation before clearing (F7).
    static let clearConfirmationThreshold = 5
    /// Maximum number of suggestion chips (F9).
    static let suggestionLimit = 5

    /// Trims leading and trailing whitespace. Returns nil for empty input.
    static func normalized(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Key used for every case-insensitive comparison.
    static func matchKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func sameName(_ lhs: String, _ rhs: String) -> Bool {
        matchKey(lhs) == matchKey(rhs)
    }

    /// Active items, oldest addedAt first (F5).
    static func activeSorted(_ items: [ListItem]) -> [ListItem] {
        items
            .filter { !$0.isChecked }
            .sorted { $0.addedAt < $1.addedAt }
    }

    /// Checked items, oldest checkedAt first (F5).
    static func checkedSorted(_ items: [ListItem]) -> [ListItem] {
        items
            .filter { $0.isChecked }
            .sorted { ($0.checkedAt ?? .distantPast) < ($1.checkedAt ?? .distantPast) }
    }

    static func clearNeedsConfirmation(checkedCount: Int) -> Bool {
        checkedCount > clearConfirmationThreshold
    }

    /// Suggestion rules (F9): prefix match from 1 character, case-insensitive,
    /// excluding names already active, ranked by useCount then lastUsedAt, max 5.
    static func suggestions(
        for input: String,
        history: [HistoryItem],
        items: [ListItem],
        limit: Int = suggestionLimit
    ) -> [HistoryItem] {
        guard let typed = normalized(input) else { return [] }
        let prefix = matchKey(typed)
        let activeKeys = Set(items.filter { !$0.isChecked }.map { matchKey($0.name) })
        let matches = history.filter { entry in
            let key = matchKey(entry.name)
            return key.hasPrefix(prefix) && !activeKeys.contains(key)
        }
        let ranked = matches.sorted { lhs, rhs in
            if lhs.useCount != rhs.useCount { return lhs.useCount > rhs.useCount }
            if lhs.lastUsedAt != rhs.lastUsedAt { return lhs.lastUsedAt > rhs.lastUsedAt }
            return matchKey(lhs.name) < matchKey(rhs.name)
        }
        return Array(ranked.prefix(limit))
    }
}

/// All list and history mutations. Operates on a `ModelContext` and saves after
/// every change so data survives app termination (F11).
///
/// Every change stamps `modifiedAt` and sets `needsUpload` so `SyncEngine` can send
/// it to the household. Deletes are soft (`removedAt`) for the same reason; the
/// reading methods below only return items that are not removed.
@MainActor
struct ListStore {
    enum AddOutcome: Equatable {
        /// Input was empty after trimming.
        case ignored
        /// A new item was created (or a deleted one was brought back).
        case added
        /// A checked item with the same name moved back to active (F2).
        case reactivated
        /// The name is already active; nothing changed (F2).
        case alreadyActive
    }

    enum RenameOutcome: Equatable {
        /// Empty name, or the same name exactly: nothing changed.
        case cancelled
        /// The item now has the new name.
        case renamed
        /// The new name matched another item; the two were merged into that item.
        case merged
    }

    let context: ModelContext
    private let now: () -> Date
    private let didChange: @MainActor () -> Void

    /// - Parameter didChange: called after every saved change, so the caller can
    ///   start an upload.
    init(
        context: ModelContext,
        now: @escaping () -> Date = { Date() },
        didChange: @escaping @MainActor () -> Void = {}
    ) {
        self.context = context
        self.now = now
        self.didChange = didChange
    }

    // MARK: Reading

    /// Items on the list (not removed).
    func allItems() -> [ListItem] {
        allStoredItems().filter { !$0.isRemoved }
    }

    /// Every stored item, including removed ones.
    func allStoredItems() -> [ListItem] {
        (try? context.fetch(FetchDescriptor<ListItem>())) ?? []
    }

    func allHistory() -> [HistoryItem] {
        (try? context.fetch(FetchDescriptor<HistoryItem>())) ?? []
    }

    func activeItems() -> [ListItem] {
        ListRules.activeSorted(allItems())
    }

    func checkedItems() -> [ListItem] {
        ListRules.checkedSorted(allItems())
    }

    func item(named name: String) -> ListItem? {
        allItems().first { ListRules.sameName($0.name, name) }
    }

    /// The stored item for this name, removed or not. Prefers one on the list.
    func storedItem(named name: String) -> ListItem? {
        item(named: name) ?? allStoredItems().first { ListRules.sameName($0.name, name) }
    }

    func historyItem(named name: String) -> HistoryItem? {
        allHistory().first { ListRules.sameName($0.name, name) }
    }

    func suggestions(for input: String) -> [HistoryItem] {
        ListRules.suggestions(for: input, history: allHistory(), items: allItems())
    }

    // MARK: Writing

    /// F1, F2, F8. Typed input and suggestion taps both go through here.
    @discardableResult
    func add(_ raw: String) -> AddOutcome {
        guard let name = ListRules.normalized(raw) else { return .ignored }
        let date = now()

        if let existing = storedItem(named: name) {
            if existing.isRemoved {
                // Bring a deleted item back as a fresh entry, as typed this time.
                existing.name = name
                existing.removedAt = nil
                activate(existing, at: date)
                recordUse(of: name, at: date)
                save()
                return .added
            }
            if !existing.isChecked {
                return .alreadyActive
            }
            activate(existing, at: date)
            recordUse(of: name, at: date)
            save()
            return .reactivated
        }

        context.insert(ListItem(name: name, addedAt: date, modifiedAt: date))
        recordUse(of: name, at: date)
        save()
        return .added
    }

    /// F3 and F4. Unchecking puts the item at the end of the active section and
    /// does not touch history.
    func toggle(_ item: ListItem) {
        let date = now()
        if item.isChecked {
            activate(item, at: date)
        } else {
            item.isChecked = true
            item.checkedAt = date
            touch(item, at: date)
        }
        save()
    }

    /// F6. History is not touched.
    func delete(_ item: ListItem) {
        remove(item, at: now())
        save()
    }

    /// F7. Removes every checked item and returns how many were removed.
    /// History is not touched.
    @discardableResult
    func clearChecked() -> Int {
        let date = now()
        let checked = allItems().filter { $0.isChecked }
        for item in checked {
            remove(item, at: date)
        }
        save()
        return checked.count
    }

    /// F10 and the rename rules.
    @discardableResult
    func rename(_ item: ListItem, to raw: String) -> RenameOutcome {
        guard let newName = ListRules.normalized(raw), newName != item.name else {
            return .cancelled
        }
        let date = now()

        let other = allItems().first {
            $0.id != item.id && ListRules.sameName($0.name, newName)
        }

        if let survivor = other {
            // Merge into the existing item, keeping its stored casing.
            if survivor.isChecked && !item.isChecked {
                // Only the renamed item was active: survivor takes its place.
                survivor.isChecked = false
                survivor.checkedAt = nil
                survivor.addedAt = item.addedAt
                touch(survivor, at: date)
            }
            // If the survivor was already active it keeps its position.
            // If both were checked, the survivor keeps its checkedAt.
            remove(item, at: date)
            addToHistoryIfNew(newName, at: date)
            save()
            return .merged
        }

        if ListRules.sameName(item.name, newName) {
            // Case-only change: same item, new casing.
            item.name = newName
            touch(item, at: date)
        } else {
            // Each name is its own shared record, so a rename moves the item's
            // state to the new name and removes the old one. A previously deleted
            // item with the new name is reused.
            let target: ListItem
            if let removed = storedItem(named: newName) {
                target = removed
            } else {
                target = ListItem(name: newName, addedAt: item.addedAt, modifiedAt: date)
                context.insert(target)
            }
            target.name = newName
            target.isChecked = item.isChecked
            target.addedAt = item.addedAt
            target.checkedAt = item.checkedAt
            target.removedAt = nil
            touch(target, at: date)
            remove(item, at: date)
        }
        addToHistoryIfNew(newName, at: date)
        save()
        return .renamed
    }

    // MARK: Private

    private func activate(_ item: ListItem, at date: Date) {
        item.isChecked = false
        item.checkedAt = nil
        item.addedAt = date
        touch(item, at: date)
    }

    private func remove(_ item: ListItem, at date: Date) {
        item.removedAt = date
        touch(item, at: date)
    }

    private func touch(_ item: ListItem, at date: Date) {
        item.modifiedAt = date
        item.needsUpload = true
    }

    private func touch(_ entry: HistoryItem, at date: Date) {
        entry.modifiedAt = date
        entry.needsUpload = true
    }

    /// History rule for adds: create with useCount 1, or bump useCount and lastUsedAt.
    private func recordUse(of name: String, at date: Date) {
        if let entry = historyItem(named: name) {
            entry.useCount += 1
            entry.lastUsedAt = date
            touch(entry, at: date)
        } else {
            context.insert(HistoryItem(name: name, useCount: 1, lastUsedAt: date, modifiedAt: date))
        }
    }

    /// History rule for renames: add the new name with useCount 1 if it is not
    /// in history yet; an existing entry (and the old name's entry) is left alone.
    private func addToHistoryIfNew(_ name: String, at date: Date) {
        if historyItem(named: name) == nil {
            context.insert(HistoryItem(name: name, useCount: 1, lastUsedAt: date, modifiedAt: date))
        }
    }

    private func save() {
        do {
            try context.save()
        } catch {
            assertionFailure("Failed to save: \(error)")
        }
        didChange()
    }
}
