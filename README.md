# Shopping List

A household iPhone shopping list built with SwiftUI and SwiftData. iOS 17.0+, iPhone only, portrait only. Everyone who installs the app (through TestFlight) sees the same list, synced through the app's public iCloud database. No login, no dependencies, no analytics.

## Project layout

```
ShoppingList.xcodeproj           Xcode 16 project (synchronized folders, shared scheme)
ShoppingList/
  ShoppingListApp.swift          @main app, sets up the SwiftData container
  Models.swift                   ListItem and HistoryItem (@Model)
  ListStore.swift                All business rules (ListRules + ListStore)
  SyncEngine.swift               Household sync with the public iCloud database
  ContentView.swift              The single list screen
  Assets.xcassets                AppIcon (empty slot) and AccentColor
ShoppingListTests/
  ShoppingListTests.swift        Swift Testing unit tests (in-memory store)
```

The project uses Xcode 16 synchronized folders: any file you add to `ShoppingList/` or `ShoppingListTests/` in Finder is picked up automatically.

## Open and set signing

1. Unzip and double-click `ShoppingList.xcodeproj` (Xcode 16 or later).
2. Select the **ShoppingList** project in the navigator, then the **ShoppingList** target, then **Signing & Capabilities**.
3. Pick your **Team**. Leave "Automatically manage signing" on.
4. If Xcode says the bundle id `com.roman.shoppinglist` is unavailable, change it to something unique (for example `com.yourname.shoppinglist`).
5. Repeat step 3 for the **ShoppingListTests** target if you plan to run tests on a physical iPhone. Simulator tests do not need a team.

## Run on the simulator

1. In the toolbar, choose the **ShoppingList** scheme and an iPhone simulator (for example iPhone 15 or iPhone 16).
2. Press **Cmd+R**.

## Run on your iPhone

1. Connect the iPhone by cable (or same Wi-Fi after the first pairing) and unlock it.
2. On the iPhone, enable **Settings > Privacy & Security > Developer Mode** if asked, then restart.
3. Choose your iPhone as the run destination and press **Cmd+R**.
4. With a free Apple ID, the first launch may be blocked: open **Settings > General > VPN & Device Management**, trust your developer certificate, then launch again. Free provisioning expires after 7 days; just run it from Xcode again.

## Run the tests

Press **Cmd+U** (or Product > Test). Tests use Swift Testing (`import Testing`) with an in-memory SwiftData store, so they never touch the app's real data. Results appear in the Test navigator (Cmd+6).

From the command line:

```
xcodebuild test -project ShoppingList.xcodeproj -scheme ShoppingList \
  -destination 'platform=iOS Simulator,name=iPhone 15'
```

## Set up household sharing (once)

Sharing needs a paid Apple Developer Program membership, which TestFlight needs anyway.

1. In Xcode, select the **ShoppingList** target, then **Signing & Capabilities**.
2. Click **+ Capability**, add **iCloud**, tick **CloudKit**, and add a container (for example `iCloud.com.roman.shoppinglist`). The app uses the first container listed.
3. Click **+ Capability** again, add **Background Modes**, and tick **Remote notifications**. This lets a change on one phone wake the others.
4. Run the app once on a device signed in to iCloud and add an item. That creates the `ListItem` and `HistoryItem` record types in iCloud.
5. Open the [CloudKit Console](https://icloud.developer.apple.com), pick the container, and in the **Development** environment:
   - **Indexes:** for both `ListItem` and `HistoryItem`, add a **QUERYABLE** index on `modificationDate`. Without it, phones can't download changes.
   - **Security Roles:** edit `_icloud` (signed-in users) and give it **Create**, **Read** and **Write** on both record types. By default only the person who added an item can change it.
6. Before the first TestFlight build, use **Deploy Schema Changes** to copy the schema to **Production**, then repeat the security role change there if it was not copied.

Every phone needs to be signed in to iCloud to send changes. Without it, the app still shows the shared list and says so at the top.

### How sync works

- Each item name (ignoring case) is one record in iCloud. Two phones adding "Milk" while offline end up with one "Milk".
- The app downloads changes when it opens, every 20 seconds while it is on screen, on pull to refresh, and when iCloud sends a push. Local changes are uploaded right after they happen and retried until they succeed.
- If two phones change the same item, the most recent change wins.
- Deleting or clearing an item marks it removed instead of erasing it, so every phone hides it. Adding the name again brings it back.
- History (suggestions) is shared too.
- When a phone first runs this version, its existing list and history are uploaded and merged into the shared list.
- Everyone with the app shares one list. That is right for a TestFlight household, but the app needs a different design before any App Store release.

## How it works

- Type an item and press Return. The keyboard stays up for the next one.
- Tap an item to check it off (light haptic, greyed out, strikethrough, moves to the bottom). Tap again to bring it back to the end of the active list.
- Pull down to check for changes from the rest of the household.
- Swipe left to delete. Long press to rename inline; press Return (or move focus to the add field) to save, or clear the text to cancel.
- While typing, suggestion chips from your history appear above the keyboard. One tap adds the item.
- "Clear checked" sits at the top of the checked section and asks for confirmation when more than 5 items are checked.

All logic lives in `ListStore.swift` (`ListRules` for pure rules such as sorting and suggestions, `ListStore` for changes to the SwiftData context). The view only calls into it.

## Assumptions where the PRD was silent

1. **Case-insensitive matching** uses Swift `lowercased()` on the trimmed name. Diacritics are not folded ("Cafe" and "Café" are different items).
2. **Suggestions** are computed from the trimmed input, so leading spaces are ignored and whitespace-only input shows nothing. Checked items can be suggested (only active items are excluded); tapping one reactivates it.
3. **Suggestion chips** are shown in a bar pinned to the bottom safe area, which sits directly above the keyboard while typing. They only appear while the add field is focused.
4. **Rename history rule** ("useCount +1 if new"): if the new name is not in history yet, a history entry is created with useCount 1. If it already exists, it is left unchanged. The old name's entry always stays.
5. **Rename merge**: the item that already had the target name survives and keeps its stored casing. If either item was active, the result is active. If the survivor was already active, it keeps its position. If only the renamed item was active, the survivor takes the renamed item's position (its addedAt). If both were checked, the survivor keeps its checkedAt.
6. **Rename to the same text** (exact match) is treated as a cancel. A case-only change ("milk" to "Milk") updates the casing on the list item but does not touch history.
7. **Rename is saved** on Return or whenever the rename field loses keyboard focus (for example tapping the add field, scrolling the keyboard away, or long pressing another row).
8. **Empty state**: when the list is empty the add field is focused on launch, and again whenever the list becomes empty.
9. **Ties** in ordering (same timestamp) are not specially handled in the list; for suggestions, ties on useCount and lastUsedAt fall back to alphabetical order.
10. **Checked item style**: 60% opacity, secondary text color, strikethrough, filled checkmark icon.
11. **App icon**: the asset catalog has an empty 1024 pt slot. Drop a 1024x1024 PNG into AppIcon in Xcode to give the app an icon.

## Notes

- Data is stored locally by SwiftData in the app's container and survives app close and phone restart. Nothing leaves the device.
- Deleting the app from the iPhone deletes the list and history.
