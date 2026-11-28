import CloudKit
import CryptoKit
import Foundation
import os
import SwiftData
import UIKit

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

/// Pure rules for the "items added" notification, so they can be unit tested.
///
/// A phone collects the names it adds and sends one notice for the whole batch,
/// so a partner adding 20 items causes one push, not 20.
enum AddedNoticeRules {
    static let recordType = "AddedNotice"
    /// A batch is sent once no item has been added for this long, or right away
    /// when the app leaves the screen.
    static let quietPeriod: TimeInterval = 120
    /// Names listed in the notice before the rest are counted.
    static let namesShown = 3

    /// Adds a name to the batch, once per name (case-insensitive).
    static func adding(_ name: String, to batch: [String]) -> [String] {
        batch.contains { ListRules.sameName($0, name) } ? batch : batch + [name]
    }

    /// Whether the batch should be sent now.
    static func isDue(lastAddedAt: Date?, now: Date, leavingApp: Bool) -> Bool {
        guard let lastAddedAt else { return false }
        return leavingApp || now.timeIntervalSince(lastAddedAt) >= quietPeriod
    }

    /// The notification text, for example "Added Milk, Eggs, Bread and 17 more".
    static func message(for names: [String]) -> String? {
        guard !names.isEmpty else { return nil }
        if names.count <= namesShown {
            return "Added " + ListFormatter.localizedString(byJoining: names)
        }
        let shown = names.prefix(namesShown).joined(separator: ", ")
        return "Added \(shown) and \(names.count - namesShown) more"
    }
}

/// One thing that went wrong while syncing, worded so the person can act on it
/// and detailed enough (step, CloudKit code, server text) to diagnose it.
struct SyncProblem: Equatable {
    enum Step: Equatable {
        case download
        case account
        case upload
        /// The change alerts that let other phones' edits arrive right away.
        case liveUpdates
        /// The "items added" notification for the rest of the household.
        case addedNotice
    }

    let step: Step
    /// The CloudKit error code, or nil when the error did not come from CloudKit.
    let code: Int?
    /// The error's own description, usually including the server's reason.
    let detail: String

    init(step: Step, error: Error) {
        self.step = step
        // A batch reports one error per record; the first one says what is wrong.
        var error = error
        if let ckError = error as? CKError,
           ckError.code == .partialFailure,
           let first = ckError.partialErrorsByItemID?.values.first {
            error = first
        }
        if let ckError = error as? CKError {
            code = ckError.code.rawValue
        } else {
            code = nil
        }
        detail = error.localizedDescription
    }

    /// What failed, why, and what to do, followed by the exact error.
    var message: String {
        var text = "\(summary) \(advice)"
        if let code {
            text += " (CloudKit error \(code): \(detail))"
        } else {
            text += " (\(detail))"
        }
        return text
    }

    private var summary: String {
        switch step {
        case .download: "Can't download the shared list."
        case .account: "Can't check your iCloud account."
        case .upload: "Can't upload your changes. They are saved on this phone."
        case .liveUpdates: "Live updates are off, so other phones' changes appear within 20 seconds instead of instantly."
        case .addedNotice: "Can't notify the household about the items you added. The items themselves are shared."
        }
    }

    private var advice: String {
        guard let code, let ckCode = CKError.Code(rawValue: code) else {
            return "It will retry automatically."
        }
        switch ckCode {
        case .networkUnavailable, .networkFailure:
            return "No internet connection. It will retry when you're back online."
        case .notAuthenticated:
            return "Sign in to iCloud in Settings, at the top under your name."
        case .permissionFailure:
            return "iCloud refused permission. In CloudKit Console (Production), the _icloud security role needs Create, Read and Write on ListItem, HistoryItem and AddedNotice."
        case .quotaExceeded:
            return "The app's shared iCloud storage is full. This is the app's storage, not yours."
        case .requestRateLimited, .serviceUnavailable, .zoneBusy:
            return "iCloud is busy. It will retry automatically."
        case .unknownItem:
            return "A record type is missing. Check Record Types in CloudKit Console (Production)."
        case .invalidArguments, .serverRejectedRequest:
            return "iCloud rejected the request, usually because a record type, field or index is missing in CloudKit Console (Production)."
        case .badContainer, .missingEntitlement:
            return "This build isn't set up for the app's iCloud container."
        case .incompatibleVersion:
            return "Update the app from TestFlight."
        default:
            return "It will retry automatically."
        }
    }
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
        /// The list is not syncing; the problem says which step failed and why.
        case failed(SyncProblem)
    }

    /// Set by the app so the push notification handler can reach it.
    static weak var shared: SyncEngine?

    private(set) var status: Status = .idle
    /// Change alerts could not be set up. The list still syncs by polling, so
    /// this is reported apart from `status`.
    private(set) var liveUpdatesProblem: SyncProblem?

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private var container: CKContainer?
    @ObservationIgnored private var isSyncing = false
    @ObservationIgnored private var needsAnotherPass = false
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let log = Logger(subsystem: "ShoppingList", category: "Sync")

    /// Set when the app leaves the screen, so the next pass sends the batch now.
    @ObservationIgnored private var leavingApp = false
    @ObservationIgnored private var noticeTimer: Task<Void, Never>?
    /// The "items added" notice could not be sent. Kept apart from the change
    /// alerts so fixing one does not hide the other.
    private(set) var addedNoticeProblem: SyncProblem?

    private let lastDownloadKey = "sync.lastDownload"
    private let subscribedKey = "sync.subscribed.v1"
    private let noticeSubscribedKey = "sync.addedNoticeSubscribed.v1"
    private let pendingNamesKey = "notice.pendingNames"
    private let lastAddedKey = "notice.lastAddedAt"
    private let installIDKey = "notice.installID"

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

    /// Remembers an item this phone put on the list, for the next notice. Kept on
    /// disk so a batch survives the app being closed before it is sent.
    func noteAdded(_ name: String) {
        let names = defaults.stringArray(forKey: pendingNamesKey) ?? []
        defaults.set(AddedNoticeRules.adding(name, to: names), forKey: pendingNamesKey)
        defaults.set(Date(), forKey: lastAddedKey)

        // Restart the quiet period; when it ends with no new item, send.
        noticeTimer?.cancel()
        noticeTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(AddedNoticeRules.quietPeriod))
            guard !Task.isCancelled else { return }
            self?.sync()
        }
    }

    /// Sends what is pending, including the notice, before iOS suspends the app.
    func leaveApp() {
        guard container != nil else { return }
        leavingApp = true
        let task = UIApplication.shared.beginBackgroundTask(withName: "Sync")
        Task {
            await syncNow()
            UIApplication.shared.endBackgroundTask(task)
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
        var step = SyncProblem.Step.download
        do {
            try await download(from: database)
            step = .account
            let account = try await container.accountStatus()
            guard account == .available else {
                status = .noAccount
                return
            }
            step = .upload
            try await upload(to: database)
            status = .idle
        } catch {
            leavingApp = false
            let problem = SyncProblem(step: step, error: error)
            log.error("Sync failed: \(problem.message, privacy: .public)")
            status = .failed(problem)
            return
        }

        // Sent after the upload, so the items are in iCloud before anyone
        // opens the notification.
        do {
            try await sendAddedNoticeIfDue(database)
            try await subscribeToAddedNoticesIfNeeded(database)
            addedNoticeProblem = nil
        } catch {
            let problem = SyncProblem(step: .addedNotice, error: error)
            log.error("Added notice failed: \(problem.message, privacy: .public)")
            addedNoticeProblem = problem
        }

        // Kept apart: without change alerts the list still syncs by polling.
        do {
            try await subscribeIfNeeded(database)
            liveUpdatesProblem = nil
        } catch {
            let problem = SyncProblem(step: .liveUpdates, error: error)
            log.error("Live updates failed: \(problem.message, privacy: .public)")
            liveUpdatesProblem = problem
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

        // A record iCloud refuses stays marked for upload and is retried; the
        // first such error is reported so the refusal is not silent.
        var firstRecordError: Error?
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
                if case .failure(let error) = result {
                    firstRecordError = firstRecordError ?? error
                    continue
                }
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
        if let firstRecordError {
            throw firstRecordError
        }
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

    // MARK: Added notice

    /// Identifies this install, so a phone is not notified about its own items.
    private var installID: String {
        if let id = defaults.string(forKey: installIDKey) { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: installIDKey)
        return id
    }

    /// Saves one `AddedNotice` record for the batch, which iCloud turns into a
    /// push on the other phones. Names that are no longer active (deleted or
    /// checked off before the batch went out) are left out.
    private func sendAddedNoticeIfDue(_ database: CKDatabase) async throws {
        let leaving = leavingApp
        leavingApp = false
        let lastAddedAt = defaults.object(forKey: lastAddedKey) as? Date
        guard AddedNoticeRules.isDue(lastAddedAt: lastAddedAt, now: Date(), leavingApp: leaving) else { return }

        let pending = defaults.stringArray(forKey: pendingNamesKey) ?? []
        let store = ListStore(context: context)
        let names = pending.filter { store.item(named: $0)?.isChecked == false }

        if let message = AddedNoticeRules.message(for: names) {
            let record = CKRecord(recordType: AddedNoticeRules.recordType)
            record.setObject(message as NSString, forKey: "message")
            record.setObject(installID as NSString, forKey: "sender")
            _ = try await database.save(record)
            log.info("Sent added notice for \(names.count) items")
        }

        // Only clear what was sent; items added during the save stay pending.
        let now = defaults.stringArray(forKey: pendingNamesKey) ?? []
        let rest = Array(now.dropFirst(pending.count))
        defaults.set(rest, forKey: pendingNamesKey)
        if rest.isEmpty {
            defaults.removeObject(forKey: lastAddedKey)
        }
    }

    /// Asks iCloud for a visible notification when another phone sends a notice.
    private func subscribeToAddedNoticesIfNeeded(_ database: CKDatabase) async throws {
        guard !defaults.bool(forKey: noticeSubscribedKey) else { return }
        let subscription = CKQuerySubscription(
            recordType: AddedNoticeRules.recordType,
            predicate: NSPredicate(format: "sender != %@", installID),
            subscriptionID: "\(AddedNoticeRules.recordType)-\(installID)",
            options: [.firesOnRecordCreation]
        )
        let info = CKSubscription.NotificationInfo()
        info.title = "Shopping list"
        // The text comes from the record's `message` field (see Localizable.strings).
        info.alertLocalizationKey = "ADDED_NOTICE"
        info.alertLocalizationArgs = ["message"]
        info.soundName = "default"
        subscription.notificationInfo = info
        _ = try await database.save(subscription)
        defaults.set(true, forKey: noticeSubscribedKey)
    }
}
