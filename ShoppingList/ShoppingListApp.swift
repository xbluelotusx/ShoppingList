import SwiftData
import SwiftUI
import UIKit

@main
struct ShoppingListApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    private let container: ModelContainer
    private let sync: SyncEngine

    init() {
        do {
            container = try ModelContainer(for: ListItem.self, HistoryItem.self)
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
                sync.sync()
            }
        }
    }
}

/// Receives the silent pushes iCloud sends when another phone changes the list.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        guard let sync = SyncEngine.shared else { return .noData }
        await sync.syncNow()
        return .newData
    }
}
