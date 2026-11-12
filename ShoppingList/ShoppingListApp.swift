import SwiftData
import SwiftUI

@main
struct ShoppingListApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [ListItem.self, HistoryItem.self])
    }
}
