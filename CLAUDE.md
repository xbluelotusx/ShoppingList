# ShoppingList

Household iPhone shopping list (SwiftUI + SwiftData, iOS 17+), synced through the
app's public iCloud database. See README.md for layout, rules and the sharing design.

- Business rules live in `ShoppingList/ListStore.swift`; the view only calls into it.
- Sync lives in `ShoppingList/SyncEngine.swift`.
- Feature ideas live in `BACKLOG.md`. Add new ideas there, and move an item to Done
  with its PR link when it ships.
- Tests: `xcodebuild test -project ShoppingList.xcodeproj -scheme ShoppingList -destination 'platform=iOS Simulator,name=iPhone 16'`
  (macOS only).

## Shipping to TestFlight

When a change is done and tests pass, run `fastlane beta`.

- This only works on the owner's Mac: it needs Xcode and the environment variables
  `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_PATH`. In a cloud session, don't try;
  say the change is ready to ship from the Mac.
- Never read, print, copy or commit the App Store Connect key (`*.p8`, anything under
  `~/.appstoreconnect/`), and never hardcode the key ID or issuer ID. Fastlane reads
  them from the environment.
- The lane takes the build number from App Store Connect (latest + 1), so don't edit
  `CURRENT_PROJECT_VERSION` by hand.
