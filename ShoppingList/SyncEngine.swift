import CloudKit
import CryptoKit
import Foundation
import os
import SwiftData

/// Pure sync rules with no CloudKit or persistence, so they can be unit tested.
enum SyncRules {
    static let itemRecordType = "ListItem"
    static let historyRecordType = "HistoryItem"

    /// Every name (case-insensitive) is one record in iCloud, on every phone.
    /// Two phones adding "Milk" while offline therefore write the same record
    /// instead of creating duplicates.
    static func recordName(type: String, name: String) -> String {
        let digest = SHA256.hash(data: Data(ListRules.matchKey(name).utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(type)-\(hex)"
    }

    /// Whether a version downloaded from iCloud replaces the local one.
    /// Local changes not uploaded yet win only if they are newer.
    static func shouldApplyRemote(
        localNeedsUpload: Bool,
        localModifiedAt: Date,
        remoteModifiedAt: Date
    ) -> Bool {
        !localNeedsUpload || remoteModifiedAt >= localModifiedAt
    }

    /// How far back each download looks before the last one, so records saved
    /// on the server while the previous download ran are not missed.
    static let downloadOverlap: TimeInterval = 120
    /// How often the app checks iCloud while it is open.
    static let pollInterval: Duration = .seconds(20)
}

/// Keeps the local SwiftData store in step with the app's public iCloud database,
/// which every copy of the app (the household, via TestFlight) shares.
///
/// Each pass downloads what changed since the last pass, then uploads local
/// changes. It runs on launch, after every local change, every 20 seconds while
/// the app is open, on pull to refresh, and when iCloud sends a change push.
@MainActor
@Observable
final class SyncEngine {
    enum Status: Equatable {
        case idle
        case syncing
        /// Not signed in to iCloud: the list is read but changes are not sent.
        case noAccount
        case failed
    }

    /// Set by the app so the push notification handler can reach it.
    static weak var shared: SyncEngine?

    private(set) var status: Status = .idle

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private var container: CKContainer?
    @ObservationIgnored private var isSyncing = false
    @ObservationIgnored private var needsAnotherPass = false
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let log = Logger(subsystem: "ShoppingList", category: "Sync")

    private let lastDownloadKey = "sync.lastDownload"
    private let subscribedKey = "sync.subscribed.v1"

    init(context: ModelContext) {
        self.context = context
    }

    // MARK: Triggers

    /// Connects to iCloud. Until this is called the engine does nothing, which
    /// keeps previews and tests away from CloudKit.
    func start() {
        guard container == nil else { return }
        container = CKContainer.default()
        sync()
    }

    /// Starts a pass, or queues one if a pass is already running.
    func sync() {
        guard container != nil else { return }
        if isSyncing {
            needsAnotherPass = true
            return
        }
        Task { await runPasses() }
    }

    /// Runs a pass and returns when it is finished (pull to refresh, pushes).
    func syncNow() async {
        guard container != nil else { return }
        if isSyncing {
            needsAnotherPass = true
            while isSyncing {
                try? await Task.sleep(for: .milliseconds(100))
            }
        } else {
            await runPasses()
        }
    }

    /// Polls while the app is on screen.
    func setActive(_ active: Bool) {
        pollTask?.cancel()
        pollTask = nil
        guard active, container != nil else { return }
        sync()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: SyncRules.pollInterval)
                guard !Task.isCancelled else { return }
                self?.sync()
            }
        }
    }

    // MARK: Pass

    private func runPasses() async {
        isSyncing = true
        status = .syncing
        repeat {
            needsAnotherPass = false
            await pass()
        } while needsAnotherPass
        isSyncing = false
    }

    private func pass() async {
        guard let container else { return }
        let database = container.publicCloudDatabase
        do {
            try await download(from: database)
            let account = try await container.accountStatus()
            guard account == .available else {
                status = .noAccount
                return
            }
            try await upload(to: database)
            try await subscribeIfNeeded(database)
            status = .idle
        } catch {
            log.error("Sync failed: \(error.localizedDescription, privacy: .public)")
            status = .failed
        }
    }

    // MARK: Download

    private func download(from database: CKDatabase) async throws {
        let lastDownload = defaults.object(forKey: lastDownloadKey) as? Date
        let since = lastDownload?.addingTimeInterval(-SyncRules.downloadOverlap) ?? .distantPast
        var newest = lastDownload ?? .distantPast

        var items = Dictionary(
            ListStore(context: context).allStoredItems().map { (ListRules.matchKey($0.name), $0) },
            uniquingKeysWith: { first, second in first.isRemoved ? second : first }
        )
        var history = Dictionary(
            ListStore(context: context).allHistory().map { (ListRules.matchKey($0.name), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for record in try await fetchRecords(SyncRules.itemRecordType, since: since, in: database) {
            apply(itemRecord: record, to: &items)
            newest = max(newest, record.modificationDate ?? newest)
        }
        for record in try await fetchRecords(SyncRules.historyRecordType, since: since, in: database) {
            apply(historyRecord: record, to: &history)
            newest = max(newest, record.modificationDate ?? newest)
        }

        try context.save()
        defaults.set(newest, forKey: lastDownloadKey)
    }

    private func fetchRecords(_ type: String, since: Date, in database: CKDatabase) async throws -> [CKRecord] {
        let predicate = NSPredicate(format: "modificationDate > %@", since as NSDate)
        let query = CKQuery(recordType: type, predicate: predicate)
        var records: [CKRecord] = []
        do {
            var (results, cursor) = try await database.records(matching: query)
            records += results.compactMap { try? $0.1.get() }
            while let next = cursor {
                (results, cursor) = try await database.records(continuingMatchFrom: next)
                records += results.compactMap { try? $0.1.get() }
            }
        } catch let error as CKError where error.code == .unknownItem {
            // The record type does not exist until the first upload creates it.
            return []
        }
        return records
    }

    private func apply(itemRecord record: CKRecord, to items: inout [String: ListItem]) {
        guard
            let name = record["name"] as? String,
            let addedAt = record["addedAt"] as? Date,
            let modifiedAt = record["modifiedAt"] as? Date
        else { return }
        let key = ListRules.matchKey(name)

        let item: ListItem
        if let local = items[key] {
            guard SyncRules.shouldApplyRemote(
                localNeedsUpload: local.needsUpload,
                localModifiedAt: local.modifiedAt,
                remoteModifiedAt: modifiedAt
            ) else { return }
            item = local
        } else {
            item = ListItem(name: name)
            context.insert(item)
            items[key] = item
        }
        item.name = name
        item.isChecked = record["isChecked"] as? Bool ?? false
        item.addedAt = addedAt
        item.checkedAt = record["checkedAt"] as? Date
        item.removedAt = record["removedAt"] as? Date
        item.modifiedAt = modifiedAt
        item.needsUpload = false
    }

    private func apply(historyRecord record: CKRecord, to history: inout [String: HistoryItem]) {
        guard
            let name = record["name"] as? String,
            let lastUsedAt = record["lastUsedAt"] as? Date,
            let modifiedAt = record["modifiedAt"] as? Date
        else { return }
        let key = ListRules.matchKey(name)

        let entry: HistoryItem
        if let local = history[key] {
            guard SyncRules.shouldApplyRemote(
                localNeedsUpload: local.needsUpload,
                localModifiedAt: local.modifiedAt,
                remoteModifiedAt: modifiedAt
            ) else { return }
            entry = local
        } else {
            entry = HistoryItem(name: name)
            context.insert(entry)
            history[key] = entry
        }
        entry.name = name
        entry.useCount = record["useCount"] as? Int ?? 1
        entry.lastUsedAt = lastUsedAt
        entry.modifiedAt = modifiedAt
        entry.needsUpload = false
    }

    // MARK: Upload

    private func upload(to database: CKDatabase) async throws {
        // Filtered in memory: `needsUpload` is computed (nil in storage means
        // true), so it cannot go in a fetch predicate. The list is small.
        let items = try context.fetch(FetchDescriptor<ListItem>()).filter(\.needsUpload)
        let history = try context.fetch(FetchDescriptor<HistoryItem>()).filter(\.needsUpload)
        guard !items.isEmpty || !history.isEmpty else { return }

        // What was sent, so a change made during the upload is not marked as sent.
        var sentItems: [String: (ListItem, Date)] = [:]
        var sentHistory: [String: (HistoryItem, Date)] = [:]
        var records: [CKRecord] = []

        for item in items {
            let record = itemRecord(for: item)
            sentItems[record.recordID.recordName] = (item, item.modifiedAt)
            records.append(record)
        }
        for entry in history {
            let record = historyRecord(for: entry)
            sentHistory[record.recordID.recordName] = (entry, entry.modifiedAt)
            records.append(record)
        }

        for start in stride(from: 0, to: records.count, by: 200) {
            let batch = Array(records[start..<min(start + 200, records.count)])
            // `.changedKeys` overwrites without a conflict check: the download
            // just before this already decided which side is newer.
            let (results, _) = try await database.modifyRecords(
                saving: batch,
                deleting: [],
                savePolicy: .changedKeys,
                atomically: false
            )
            for (recordID, result) in results {
                guard case .success = result else { continue }
                let name = recordID.recordName
                if let sent = sentItems[name], sent.0.modifiedAt == sent.1 {
                    sent.0.needsUpload = false
                }
                if let sent = sentHistory[name], sent.0.modifiedAt == sent.1 {
                    sent.0.needsUpload = false
                }
            }
        }
        try context.save()
    }

    private func itemRecord(for item: ListItem) -> CKRecord {
        let id = CKRecord.ID(recordName: SyncRules.recordName(type: SyncRules.itemRecordType, name: item.name))
        let record = CKRecord(recordType: SyncRules.itemRecordType, recordID: id)
        record.setObject(item.name as NSString, forKey: "name")
        record.setObject(NSNumber(value: item.isChecked), forKey: "isChecked")
        record.setObject(item.addedAt as NSDate, forKey: "addedAt")
        // Nil is sent explicitly so a cleared date is cleared in iCloud too.
        record.setObject(item.checkedAt as NSDate?, forKey: "checkedAt")
        record.setObject(item.removedAt as NSDate?, forKey: "removedAt")
        record.setObject(item.modifiedAt as NSDate, forKey: "modifiedAt")
        return record
    }

    private func historyRecord(for entry: HistoryItem) -> CKRecord {
        let id = CKRecord.ID(recordName: SyncRules.recordName(type: SyncRules.historyRecordType, name: entry.name))
        let record = CKRecord(recordType: SyncRules.historyRecordType, recordID: id)
        record.setObject(entry.name as NSString, forKey: "name")
        record.setObject(NSNumber(value: entry.useCount), forKey: "useCount")
        record.setObject(entry.lastUsedAt as NSDate, forKey: "lastUsedAt")
        record.setObject(entry.modifiedAt as NSDate, forKey: "modifiedAt")
        return record
    }

    // MARK: Push

    /// Asks iCloud for a silent push whenever another phone changes the list.
    private func subscribeIfNeeded(_ database: CKDatabase) async throws {
        guard !defaults.bool(forKey: subscribedKey) else { return }
        for type in [SyncRules.itemRecordType, SyncRules.historyRecordType] {
            let subscription = CKQuerySubscription(
                recordType: type,
                predicate: NSPredicate(value: true),
                subscriptionID: "\(type)-changes",
                options: [.firesOnRecordCreation, .firesOnRecordUpdate]
            )
            let info = CKSubscription.NotificationInfo()
            info.shouldSendContentAvailable = true
            subscription.notificationInfo = info
            _ = try await database.save(subscription)
        }
        defaults.set(true, forKey: subscribedKey)
    }
}
