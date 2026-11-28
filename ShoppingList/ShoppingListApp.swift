import SwiftData
import SwiftUI
import UIKit
import UserNotifications

@main
struct ShoppingListApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    private let container: ModelContainer
    private let sync: SyncEngine

    init() {
        do {
            // Household sharing goes through SyncEngine and the public iCloud
            // database. With the iCloud capability on, SwiftData would otherwise
            // also try to mirror the store to the private database by default,
            // which these models don't support, and the store would not open.
            let configuration = ModelConfiguration(cloudKitDatabase: .none)
            container = try ModelContainer(
                for: ListItem.self, HistoryItem.self,
                configurations: configuration
            )
        } catch {
            fatalError("Could not open the shopping list store: \(error)")
        }
        sync = SyncEngine(context: container.mainContext)
        SyncEngine.shared = sync
        // Unit tests run inside the app; keep them away from iCloud.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            sync.start()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(sync)
        }
        .modelContainer(container)
        .onChange(of: scenePhase) { _, phase in
            sync.setActive(phase == .active)
            if phase == .background {
                sync.leaveApp()
            }
        }
    }
}

/// Receives the silent pushes iCloud sends when another phone changes the list,
/// and shows the "items added" notification while the app is open.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        application.registerForRemoteNotifications()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // Unit tests run inside the app; keep the permission prompt out of them.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        return true
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    // Nonisolated so the push payload (not Sendable) never crosses onto the
    // main actor; only the sync call itself hops there.
    nonisolated func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        guard let sync = await SyncEngine.shared else { return .noData }
        await sync.syncNow()
        return .newData
    }
}
