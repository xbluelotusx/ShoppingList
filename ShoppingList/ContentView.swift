import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var items: [ListItem]
    @Query private var history: [HistoryItem]

    @State private var draft = ""
    @State private var renamingID: UUID?
    @State private var renameDraft = ""
    @State private var showClearConfirmation = false
    @State private var checkHapticTrigger = 0
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case add
        case rename(UUID)
    }

    private var store: ListStore { ListStore(context: modelContext) }
    private var activeItems: [ListItem] { ListRules.activeSorted(items) }
    private var checkedItems: [ListItem] { ListRules.checkedSorted(items) }
    private var suggestions: [HistoryItem] {
        ListRules.suggestions(for: draft, history: history, items: items)
    }

    var body: some View {
        VStack(spacing: 0) {
            inputField
            Divider()
            if items.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .safeAreaInset(edge: .bottom) {
            if focusedField == .add && !suggestions.isEmpty {
                suggestionBar
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: checkHapticTrigger)
        .confirmationDialog(
            "Clear \(checkedItems.count) checked items?",
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear checked", role: .destructive) {
                clearChecked()
            }
            Button("Cancel", role: .cancel) {}
        }
        .onAppear {
            if items.isEmpty {
                focusedField = .add
            }
        }
        .onChange(of: items.isEmpty) { _, isEmpty in
            if isEmpty && renamingID == nil {
                focusedField = .add
            }
        }
        .onChange(of: focusedField) { oldValue, newValue in
            // Leaving a rename field (tapping elsewhere) saves that rename.
            if case .some(.rename(let id)) = oldValue, newValue != oldValue {
                commitRename(for: id)
            }
        }
    }

    // MARK: Sections

    private var inputField: some View {
        HStack(spacing: 12) {
            Image(systemName: "plus")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            TextField("Add item", text: $draft)
                .focused($focusedField, equals: .add)
                .submitLabel(.return)
                .autocorrectionDisabled(false)
                .textInputAutocapitalization(.sentences)
                .onSubmit(submitDraft)
        }
        .font(.body)
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
    }

    private var list: some View {
        List {
            Section {
                ForEach(activeItems, id: \.id) { item in
                    row(for: item)
                }
            }

            if !checkedItems.isEmpty {
                Section {
                    ForEach(checkedItems, id: \.id) { item in
                        row(for: item)
                    }
                } header: {
                    HStack {
                        Button("Clear checked", action: clearCheckedTapped)
                            .font(.footnote)
                            .buttonStyle(.borderless)
                        Spacer()
                    }
                    .textCase(nil)
                }
            }
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.interactively)
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            Text("Nothing to buy")
                .font(.title3)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { focusedField = .add }
    }

    private var suggestionBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(suggestions, id: \.persistentModelID) { entry in
                    Button {
                        addSuggestion(entry.name)
                    } label: {
                        Text(entry.name)
                            .lineLimit(1)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .frame(minHeight: 44)
                            .background(
                                Capsule().fill(Color(uiColor: .secondarySystemBackground))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }

    // MARK: Rows

    @ViewBuilder
    private func row(for item: ListItem) -> some View {
        let isRenaming = renamingID == item.id
        Group {
            if isRenaming {
                HStack(spacing: 12) {
                    checkbox(for: item)
                    TextField("Item name", text: $renameDraft)
                        .focused($focusedField, equals: .rename(item.id))
                        .submitLabel(.done)
                        .onSubmit { commitRename(for: item.id) }
                }
            } else {
                HStack(spacing: 12) {
                    checkbox(for: item)
                    Text(item.name)
                        .strikethrough(item.isChecked)
                        .foregroundStyle(
                            item.isChecked ? HierarchicalShapeStyle.secondary : HierarchicalShapeStyle.primary
                        )
                    Spacer(minLength: 0)
                }
                .opacity(item.isChecked ? 0.6 : 1)
                .contentShape(Rectangle())
                .onTapGesture { toggle(item) }
                .onLongPressGesture { beginRename(item) }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityValue(Text(item.isChecked ? "Checked" : "Not checked"))
                .accessibilityAction(named: "Rename") { beginRename(item) }
            }
        }
        .frame(minHeight: 44)
        .swipeActions(edge: .trailing, allowsFullSwipe: !isRenaming) {
            if !isRenaming {
                Button(role: .destructive) {
                    delete(item)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    private func checkbox(for item: ListItem) -> some View {
        Image(systemName: item.isChecked ? "checkmark.circle.fill" : "circle")
            .font(.title2)
            .foregroundStyle(item.isChecked ? Color.secondary : Color.accentColor)
            .accessibilityHidden(true)
    }

    // MARK: Actions

    private func submitDraft() {
        let text = draft
        withAnimation {
            _ = store.add(text)
        }
        draft = ""
        // Keep the keyboard up for the next item (F1).
        focusedField = .add
        DispatchQueue.main.async {
            focusedField = .add
        }
    }

    private func addSuggestion(_ name: String) {
        withAnimation {
            _ = store.add(name)
        }
        draft = ""
        focusedField = .add
    }

    private func toggle(_ item: ListItem) {
        let willCheck = !item.isChecked
        withAnimation(.easeInOut(duration: 0.3)) {
            store.toggle(item)
        }
        if willCheck {
            checkHapticTrigger += 1
        }
    }

    private func delete(_ item: ListItem) {
        withAnimation {
            store.delete(item)
        }
    }

    private func clearCheckedTapped() {
        if ListRules.clearNeedsConfirmation(checkedCount: checkedItems.count) {
            showClearConfirmation = true
        } else {
            clearChecked()
        }
    }

    private func clearChecked() {
        withAnimation {
            _ = store.clearChecked()
        }
    }

    private func beginRename(_ item: ListItem) {
        if let pending = renamingID {
            commitRename(for: pending)
        }
        renameDraft = item.name
        renamingID = item.id
        DispatchQueue.main.async {
            focusedField = .rename(item.id)
        }
    }

    /// Saves the rename for `id` if it is still the one being edited.
    /// Empty text cancels (handled by the store).
    private func commitRename(for id: UUID) {
        guard renamingID == id else { return }
        renamingID = nil
        let newName = renameDraft
        renameDraft = ""
        if focusedField == .rename(id) {
            focusedField = nil
        }
        guard let item = items.first(where: { $0.id == id }) else { return }
        withAnimation {
            _ = store.rename(item, to: newName)
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [ListItem.self, HistoryItem.self], inMemory: true)
}
