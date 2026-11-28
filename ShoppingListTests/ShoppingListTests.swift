import CloudKit
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
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
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
        let target = try item("milk")
        #expect(store.rename(target, to: "   ") == .cancelled)
        #expect(activeNames() == ["milk"])
        #expect(store.allHistory().count == 1)
    }

    @Test func renameCaseOnlyKeepsSingleItem() throws {
        store.add("milk")
        let target = try item("milk")
        #expect(store.rename(target, to: "Milk") == .renamed)
        #expect(activeNames() == ["Milk"])
        #expect(store.allHistory().count == 1)
    }

    @Test func renameMergeKeepsActiveWhenRenamedItemActive() throws {
        store.add("bread")
        store.add("milk")
        store.add("eggs")
        store.toggle(try item("milk"))

        let breadAddedAt = try item("bread").addedAt
        let target = try item("bread")
        #expect(store.rename(target, to: "MILK") == .merged)

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

        let target = try item("bread")
        #expect(store.rename(target, to: "milk") == .merged)
        #expect(activeNames() == ["milk"])
        #expect(checkedNames().isEmpty)
    }

    @Test func renameMergeOfTwoCheckedStaysChecked() throws {
        store.add("milk")
        store.add("bread")
        store.toggle(try item("milk"))
        store.toggle(try item("bread"))

        let target = try item("bread")
        #expect(store.rename(target, to: "milk") == .merged)
        #expect(activeNames().isEmpty)
        #expect(checkedNames() == ["milk"])
    }
}

// MARK: Household sharing

@MainActor
struct SharingTests {
    let container: ModelContainer
    let context: ModelContext
    let store: ListStore
    let clock: TestClock

    init() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        container = try ModelContainer(
            for: ListItem.self, HistoryItem.self,
            configurations: configuration
        )
        context = ModelContext(container)
        let clock = TestClock()
        self.clock = clock
        store = ListStore(context: context, now: { clock.tick() })
    }

    private func stored(_ name: String) throws -> ListItem {
        try #require(store.storedItem(named: name))
    }

    private func markAllUploaded() {
        for item in store.allStoredItems() { item.needsUpload = false }
        for entry in store.allHistory() { entry.needsUpload = false }
    }

    @Test func deleteIsSoftSoOtherPhonesHearAboutIt() throws {
        store.add("milk")
        markAllUploaded()
        store.delete(try #require(store.item(named: "milk")))

        #expect(store.allItems().isEmpty)
        let milk = try stored("milk")
        #expect(milk.removedAt != nil)
        #expect(milk.needsUpload)
    }

    @Test func clearCheckedIsSoft() throws {
        store.add("a")
        store.add("b")
        store.toggle(try #require(store.item(named: "a")))
        store.clearChecked()

        #expect(store.allStoredItems().count == 2)
        #expect(try stored("a").isRemoved)
        #expect(try stored("b").isRemoved == false)
    }

    @Test func addingDeletedNameRevivesTheSameItem() throws {
        store.add("milk")
        let id = try stored("milk").id
        store.delete(try #require(store.item(named: "milk")))

        #expect(store.add("Milk") == .added)
        #expect(store.allStoredItems().count == 1)
        let milk = try stored("milk")
        #expect(milk.id == id)
        #expect(milk.name == "Milk")
        #expect(milk.isRemoved == false)
        #expect(milk.isChecked == false)
    }

    @Test func everyChangeIsMarkedForUpload() throws {
        store.add("eggs")
        #expect(try stored("eggs").needsUpload)
        let eggsHistory = try #require(store.historyItem(named: "eggs"))
        #expect(eggsHistory.needsUpload)

        markAllUploaded()
        let before = try stored("eggs").modifiedAt
        store.toggle(try stored("eggs"))
        #expect(try stored("eggs").needsUpload)
        #expect(try stored("eggs").modifiedAt > before)
        #expect(eggsHistory.needsUpload == false)
    }

    @Test func activeDuplicateChangesNothing() throws {
        store.add("milk")
        markAllUploaded()
        #expect(store.add("milk") == .alreadyActive)
        #expect(try stored("milk").needsUpload == false)
    }

    @Test func renameMovesStateToNewNameAndRemovesOld() throws {
        store.add("milk")
        store.toggle(try stored("milk"))
        let old = try stored("milk")
        let checkedAt = old.checkedAt

        #expect(store.rename(old, to: "oat milk") == .renamed)

        #expect(store.allItems().map(\.name) == ["oat milk"])
        let renamed = try stored("oat milk")
        #expect(renamed.isChecked)
        #expect(renamed.checkedAt == checkedAt)
        #expect(try stored("milk").isRemoved)
    }

    @Test func renameReusesDeletedItemWithThatName() throws {
        store.add("oat milk")
        let id = try stored("oat milk").id
        store.delete(try stored("oat milk"))
        store.add("milk")

        let target = try stored("milk")
        #expect(store.rename(target, to: "Oat Milk") == .renamed)
        #expect(try stored("oat milk").id == id)
        #expect(store.allStoredItems().count == 2)
    }

    @Test func mergeRemovesRenamedItemSoftly() throws {
        store.add("milk")
        store.add("bread")
        let target = try stored("bread")
        #expect(store.rename(target, to: "milk") == .merged)
        #expect(store.allItems().map(\.name) == ["milk"])
        #expect(try stored("bread").isRemoved)
    }

    @Test func didChangeIsCalledAfterSaves() {
        var calls = 0
        let store = ListStore(context: context, didChange: { calls += 1 })
        store.add("milk")
        store.add("")
        #expect(calls == 1)
    }

    @Test func didAddReportsItemsPutOnTheList() throws {
        var added: [String] = []
        let store = ListStore(context: context, didAdd: { added.append($0) })
        store.add("Milk")
        store.add("milk")                                  // already active: not an addition
        store.add("  ")                                    // ignored
        store.toggle(try #require(store.item(named: "Milk")))
        store.add("MILK")                                  // checked item made active again
        store.delete(try #require(store.item(named: "Milk")))
        store.add("Eggs")
        let eggs = try #require(store.item(named: "Eggs"))
        store.rename(eggs, to: "Free-range eggs")          // a rename is not an addition
        #expect(added == ["Milk", "Milk", "Eggs"])
    }

    @Test func deletedItemAddedAgainCountsAsAdded() throws {
        var added: [String] = []
        let store = ListStore(context: context, didAdd: { added.append($0) })
        store.add("Milk")
        store.delete(try #require(store.item(named: "Milk")))
        store.add("milk")
        #expect(added == ["Milk", "milk"])
    }

    // MARK: Added notice

    @Test func batchKeepsEachNameOnce() {
        var batch: [String] = []
        for name in ["Milk", "Eggs", "milk", " MILK "] {
            batch = AddedNoticeRules.adding(name, to: batch)
        }
        #expect(batch == ["Milk", "Eggs"])
    }

    @Test func batchIsSentAfterQuietPeriodOrOnLeaving() {
        let added = Date(timeIntervalSince1970: 1_000)
        let soon = added.addingTimeInterval(AddedNoticeRules.quietPeriod - 1)
        let later = added.addingTimeInterval(AddedNoticeRules.quietPeriod)
        #expect(AddedNoticeRules.isDue(lastAddedAt: added, now: soon, leavingApp: false) == false)
        #expect(AddedNoticeRules.isDue(lastAddedAt: added, now: later, leavingApp: false))
        #expect(AddedNoticeRules.isDue(lastAddedAt: added, now: soon, leavingApp: true))
        // Nothing added: nothing to send, even when leaving.
        #expect(AddedNoticeRules.isDue(lastAddedAt: nil, now: later, leavingApp: true) == false)
    }

    @Test func noticeTextListsFewNamesAndCountsTheRest() {
        #expect(AddedNoticeRules.message(for: []) == nil)
        #expect(AddedNoticeRules.message(for: ["Milk"]) == "Added Milk")
        let three = AddedNoticeRules.message(for: ["Milk", "Eggs", "Bread"])
        #expect(three?.hasPrefix("Added Milk, Eggs") == true)
        #expect(three?.hasSuffix("Bread") == true)
        let twenty = (1...20).map { "Item \($0)" }
        #expect(AddedNoticeRules.message(for: twenty) == "Added Item 1, Item 2, Item 3 and 17 more")
    }

    @Test func noticeProblemSaysTheItemsAreStillShared() {
        let problem = SyncProblem(step: .addedNotice, error: CKError(.permissionFailure))
        #expect(problem.message.hasPrefix("Can't notify the household"))
        #expect(problem.message.contains("AddedNotice"))
    }

    // MARK: Sync rules

    @Test func recordNameIsCaseAndSpaceInsensitive() {
        let a = SyncRules.recordName(type: "ListItem", name: "Milk")
        let b = SyncRules.recordName(type: "ListItem", name: "  milk ")
        #expect(a == b)
        #expect(a.hasPrefix("ListItem-"))
        #expect(a != SyncRules.recordName(type: "HistoryItem", name: "milk"))
        #expect(a != SyncRules.recordName(type: "ListItem", name: "oat milk"))
    }

    @Test func recordNameIsValidForCloudKit() {
        let name = SyncRules.recordName(type: "ListItem", name: String(repeating: "Ünïcødé 🥛 ", count: 100))
        #expect(name.count <= 255)
        // Computed outside #expect: the macro rewrites a direct allSatisfy call
        // into a form that can throw without `try`, which fails to compile.
        let isASCII = name.allSatisfy { $0.isASCII }
        #expect(isASCII)
    }

    @Test func remoteWinsUnlessLocalChangeIsNewer() {
        let early = Date(timeIntervalSince1970: 100)
        let late = Date(timeIntervalSince1970: 200)
        // Nothing waiting to upload: iCloud is the truth.
        #expect(SyncRules.shouldApplyRemote(localNeedsUpload: false, localModifiedAt: late, remoteModifiedAt: early))
        // Local change waiting, remote is newer: remote wins.
        #expect(SyncRules.shouldApplyRemote(localNeedsUpload: true, localModifiedAt: early, remoteModifiedAt: late))
        // Local change waiting and newer: keep it and upload it.
        #expect(SyncRules.shouldApplyRemote(localNeedsUpload: true, localModifiedAt: late, remoteModifiedAt: early) == false)
    }

    // MARK: Sync problems

    @Test func problemNamesStepReasonAndExactCode() {
        let problem = SyncProblem(step: .upload, error: CKError(.networkUnavailable))
        #expect(problem.code == CKError.Code.networkUnavailable.rawValue)
        #expect(problem.message.hasPrefix("Can't upload your changes."))
        #expect(problem.message.contains("No internet connection"))
        #expect(problem.message.contains("CloudKit error \(CKError.Code.networkUnavailable.rawValue)"))
    }

    @Test func permissionProblemPointsAtSecurityRoles() {
        let problem = SyncProblem(step: .upload, error: CKError(.permissionFailure))
        #expect(problem.message.contains("_icloud security role"))
    }

    @Test func rejectedRequestPointsAtSchema() {
        let problem = SyncProblem(step: .liveUpdates, error: CKError(.serverRejectedRequest))
        #expect(problem.message.hasPrefix("Live updates are off"))
        #expect(problem.message.contains("CloudKit Console (Production)"))
    }

    @Test func batchFailureReportsTheRecordsOwnError() {
        let recordError = CKError(.permissionFailure)
        let batch = CKError(.partialFailure, userInfo: [
            CKPartialErrorsByItemIDKey: [CKRecord.ID(recordName: "ListItem-x"): recordError]
        ])
        let problem = SyncProblem(step: .upload, error: batch)
        #expect(problem.code == CKError.Code.permissionFailure.rawValue)
        #expect(problem.message.contains("_icloud security role"))
    }

    @Test func nonCloudKitErrorKeepsItsDescription() {
        struct DiskFull: LocalizedError {
            var errorDescription: String? { "The disk is full." }
        }
        let problem = SyncProblem(step: .download, error: DiskFull())
        #expect(problem.code == nil)
        #expect(problem.message.hasPrefix("Can't download the shared list."))
        #expect(problem.message.contains("(The disk is full.)"))
    }
}

// MARK: Updating from the version before sharing

/// The models exactly as the app shipped them before household sharing.
/// Entity names match the current models, so a store written with these is
/// what a phone updating from that version has on disk.
enum PreSharingModels {
    @Model
    final class ListItem {
        var id: UUID
        var name: String
        var isChecked: Bool
        var addedAt: Date
        var checkedAt: Date?

        init(name: String) {
            self.id = UUID()
            self.name = name
            self.isChecked = false
            self.addedAt = Date()
            self.checkedAt = nil
        }
    }

    @Model
    final class HistoryItem {
        var name: String
        var useCount: Int
        var lastUsedAt: Date

        init(name: String) {
            self.name = name
            self.useCount = 1
            self.lastUsedAt = Date()
        }
    }
}

@MainActor
struct MigrationTests {
    @Test func storeFromBeforeSharingOpensAndIsUploadedOnce() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("list.store")

        // Write a store with the old models, then let go of it.
        try autoreleasepool {
            let schema = Schema([PreSharingModels.ListItem.self, PreSharingModels.HistoryItem.self])
            let container = try ModelContainer(
                for: schema,
                configurations: ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
            )
            let context = ModelContext(container)
            context.insert(PreSharingModels.ListItem(name: "milk"))
            context.insert(PreSharingModels.HistoryItem(name: "milk"))
            try context.save()
        }

        // Open the same file with the current models, as the updated app does.
        let schema = Schema([ListItem.self, HistoryItem.self])
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        )
        let store = ListStore(context: ModelContext(container))

        let milk = try #require(store.item(named: "milk"))
        #expect(milk.isRemoved == false)
        #expect(milk.needsUpload)
        #expect(milk.modifiedAt == .distantPast)
        let entry = try #require(store.historyItem(named: "milk"))
        #expect(entry.needsUpload)
        #expect(entry.useCount == 1)
    }
}
