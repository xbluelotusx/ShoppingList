import Foundation
import SwiftData
import Testing
@testable import ShoppingList

/// Deterministic clock: every call returns a time one second later than the last.
final class TestClock {
    private(set) var current = Date(timeIntervalSince1970: 1_700_000_000)

    func tick() -> Date {
        current = current.addingTimeInterval(1)
        return current
    }
}

@MainActor
struct ShoppingListTests {
    let container: ModelContainer
    let context: ModelContext
    let store: ListStore

    init() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: ListItem.self, HistoryItem.self,
            configurations: configuration
        )
        context = ModelContext(container)
        let clock = TestClock()
        store = ListStore(context: context, now: { clock.tick() })
    }

    // MARK: Helpers

    private func activeNames() -> [String] { store.activeItems().map(\.name) }
    private func checkedNames() -> [String] { store.checkedItems().map(\.name) }

    private func item(_ name: String) throws -> ListItem {
        try #require(store.item(named: name))
    }

    private func history(_ name: String) throws -> HistoryItem {
        try #require(store.historyItem(named: name))
    }

    /// Adds `name` and then deletes it from the list, `times` times, to build history.
    private func use(_ name: String, times: Int) throws {
        for _ in 0..<times {
            store.add(name)
            store.delete(try item(name))
        }
    }

    // MARK: Input rules

    @Test func trimsWhitespaceOnAdd() throws {
        #expect(store.add("  milk \n") == .added)
        #expect(activeNames() == ["milk"])
        #expect(try history("milk").name == "milk")
    }

    @Test func ignoresEmptyAndWhitespaceInput() {
        #expect(store.add("") == .ignored)
        #expect(store.add("   \t ") == .ignored)
        #expect(store.allItems().isEmpty)
        #expect(store.allHistory().isEmpty)
    }

    @Test func storesNameAsTypedOnFirstEntry() throws {
        store.add("Oat Milk")
        #expect(store.add("oat milk") == .alreadyActive)
        #expect(activeNames() == ["Oat Milk"])
        #expect(try history("OAT MILK").name == "Oat Milk")
    }

    // MARK: F2 duplicates

    @Test func addingActiveDuplicateDoesNothing() throws {
        store.add("milk")
        let addedAt = try item("milk").addedAt
        #expect(store.add("MILK") == .alreadyActive)
        #expect(store.allItems().count == 1)
        #expect(try item("milk").addedAt == addedAt)
        #expect(try history("milk").useCount == 1)
    }

    @Test func addingCheckedDuplicateReactivatesIt() throws {
        store.add("milk")
        store.add("bread")
        store.toggle(try item("milk"))
        let lastUsedBefore = try history("milk").lastUsedAt

        #expect(store.add(" Milk ") == .reactivated)

        let milk = try item("milk")
        #expect(store.allItems().count == 2)
        #expect(milk.name == "milk")
        #expect(milk.isChecked == false)
        #expect(milk.checkedAt == nil)
        #expect(activeNames() == ["bread", "milk"])
        #expect(try history("milk").useCount == 2)
        #expect(try history("milk").lastUsedAt > lastUsedBefore)
    }

    // MARK: F3 / F4 check and uncheck

    @Test func checkingSetsCheckedAt() throws {
        store.add("eggs")
        store.toggle(try item("eggs"))
        let eggs = try item("eggs")
        #expect(eggs.isChecked)
        #expect(eggs.checkedAt != nil)
        #expect(activeNames().isEmpty)
        #expect(checkedNames() == ["eggs"])
    }

    @Test func uncheckingMovesToEndOfActiveWithoutCountingHistory() throws {
        store.add("a")
        store.add("b")
        store.add("c")
        store.toggle(try item("a"))
        store.toggle(try item("a"))

        let a = try item("a")
        #expect(a.isChecked == false)
        #expect(a.checkedAt == nil)
        #expect(activeNames() == ["b", "c", "a"])
        #expect(try history("a").useCount == 1)
    }

    // MARK: F5 ordering

    @Test func activeOldestFirstThenCheckedOldestFirst() throws {
        for name in ["a", "b", "c", "d"] { store.add(name) }
        store.toggle(try item("c"))
        store.toggle(try item("a"))

        #expect(activeNames() == ["b", "d"])
        #expect(checkedNames() == ["c", "a"])
    }

    @Test func pureSortingRules() {
        let base = Date(timeIntervalSince1970: 0)
        let items = [
            ListItem(name: "late", addedAt: base.addingTimeInterval(30)),
            ListItem(name: "early", addedAt: base.addingTimeInterval(10)),
            ListItem(name: "checkedLate", isChecked: true, addedAt: base, checkedAt: base.addingTimeInterval(50)),
            ListItem(name: "checkedEarly", isChecked: true, addedAt: base, checkedAt: base.addingTimeInterval(40)),
        ]
        #expect(ListRules.activeSorted(items).map(\.name) == ["early", "late"])
        #expect(ListRules.checkedSorted(items).map(\.name) == ["checkedEarly", "checkedLate"])
    }

    // MARK: F6 / F7 delete and clear

    @Test func deleteKeepsHistory() throws {
        store.add("milk")
        store.delete(try item("milk"))
        #expect(store.allItems().isEmpty)
        #expect(try history("milk").useCount == 1)
    }

    @Test func clearCheckedRemovesOnlyCheckedAndKeepsHistory() throws {
        for name in ["a", "b", "c"] { store.add(name) }
        store.toggle(try item("a"))
        store.toggle(try item("c"))

        #expect(store.clearChecked() == 2)
        #expect(activeNames() == ["b"])
        #expect(checkedNames().isEmpty)
        #expect(store.allHistory().count == 3)
    }

    @Test func clearConfirmationOnlyAboveFive() {
        #expect(ListRules.clearNeedsConfirmation(checkedCount: 5) == false)
        #expect(ListRules.clearNeedsConfirmation(checkedCount: 6) == true)
    }

    // MARK: F8 history

    @Test func everyAddCreatesOrUpdatesHistory() throws {
        store.add("bananas")
        let first = try history("bananas")
        #expect(first.useCount == 1)
        let firstUsed = first.lastUsedAt

        store.delete(try item("bananas"))
        store.add("Bananas")

        let entry = try history("bananas")
        #expect(store.allHistory().count == 1)
        #expect(entry.name == "bananas")
        #expect(entry.useCount == 2)
        #expect(entry.lastUsedAt > firstUsed)
    }

    @Test func addingFromSuggestionCountsAsUse() throws {
        try use("bananas", times: 1)
        let suggestion = try #require(store.suggestions(for: "ba").first)
        #expect(store.add(suggestion.name) == .added)
        #expect(try history("bananas").useCount == 2)
    }

    // MARK: F9 suggestions

    @Test func suggestionsArePrefixAndCaseInsensitive() throws {
        try use("Bananas", times: 1)
        try use("basil", times: 1)
        try use("apple banana bread", times: 1)

        let names = Set(store.suggestions(for: "BA").map(\.name))
        #expect(names == ["Bananas", "basil"])
        #expect(store.suggestions(for: "b").count == 2)
    }

    @Test func suggestionsEmptyForEmptyInput() throws {
        try use("bananas", times: 1)
        #expect(store.suggestions(for: "").isEmpty)
        #expect(store.suggestions(for: "   ").isEmpty)
    }

    @Test func suggestionsExcludeActiveButIncludeChecked() throws {
        store.add("bread")
        store.add("butter")
        store.toggle(try item("butter"))

        #expect(store.suggestions(for: "b").map(\.name) == ["butter"])
    }

    @Test func suggestionsRankByUseCountThenRecency() throws {
        try use("beans", times: 1)
        try use("beer", times: 3)
        try use("berries", times: 1)   // same count as beans, used more recently
        try use("bread", times: 2)

        #expect(store.suggestions(for: "b").map(\.name) == ["beer", "bread", "berries", "beans"])
    }

    @Test func suggestionsLimitedToFive() throws {
        for name in ["b1", "b2", "b3", "b4", "b5", "b6", "b7"] {
            try use(name, times: 1)
        }
        #expect(store.suggestions(for: "b").count == 5)
    }

    // MARK: Rename

    @Test func renameChangesNameAndAddsHistory() throws {
        store.add("milk")
        let milk = try item("milk")
        #expect(store.rename(milk, to: "  oat milk ") == .renamed)

        #expect(activeNames() == ["oat milk"])
        #expect(try history("oat milk").useCount == 1)
        #expect(try history("milk").useCount == 1)  // old entry stays
    }

    @Test func renameToNameAlreadyInHistoryDoesNotBumpIt() throws {
        try use("oat milk", times: 2)
        store.add("milk")
        store.rename(try item("milk"), to: "Oat Milk")
        #expect(try history("oat milk").useCount == 2)
    }

    @Test func renameWithEmptyNameCancels() throws {
        store.add("milk")
        #expect(store.rename(try item("milk"), to: "   ") == .cancelled)
        #expect(activeNames() == ["milk"])
        #expect(store.allHistory().count == 1)
    }

    @Test func renameCaseOnlyKeepsSingleItem() throws {
        store.add("milk")
        #expect(store.rename(try item("milk"), to: "Milk") == .renamed)
        #expect(activeNames() == ["Milk"])
        #expect(store.allHistory().count == 1)
    }

    @Test func renameMergeKeepsActiveWhenRenamedItemActive() throws {
        store.add("bread")
        store.add("milk")
        store.add("eggs")
        store.toggle(try item("milk"))

        let breadAddedAt = try item("bread").addedAt
        #expect(store.rename(try item("bread"), to: "MILK") == .merged)

        #expect(store.allItems().count == 2)
        let milk = try item("milk")
        #expect(milk.name == "milk")
        #expect(milk.isChecked == false)
        #expect(milk.checkedAt == nil)
        #expect(milk.addedAt == breadAddedAt)
        #expect(activeNames() == ["milk", "eggs"])
        #expect(try history("bread").useCount == 1)
    }

    @Test func renameMergeKeepsActiveWhenTargetActive() throws {
        store.add("milk")
        store.add("bread")
        store.toggle(try item("bread"))

        #expect(store.rename(try item("bread"), to: "milk") == .merged)
        #expect(activeNames() == ["milk"])
        #expect(checkedNames().isEmpty)
    }

    @Test func renameMergeOfTwoCheckedStaysChecked() throws {
        store.add("milk")
        store.add("bread")
        store.toggle(try item("milk"))
        store.toggle(try item("bread"))

        #expect(store.rename(try item("bread"), to: "milk") == .merged)
        #expect(activeNames().isEmpty)
        #expect(checkedNames() == ["milk"])
    }
}
