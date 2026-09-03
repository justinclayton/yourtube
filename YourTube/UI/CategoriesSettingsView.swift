import SwiftUI
import SwiftData

/// Manage the category list and drive the classifier.
struct CategoriesSettingsView: View {
    @Environment(AppServices.self) private var services

    @Query(sort: [SortDescriptor(\VideoCollection.sortOrder), SortDescriptor(\VideoCollection.name)])
    private var categories: [VideoCollection]
    @Query private var rules: [ChannelRule]
    @Query private var subscriptions: [Subscription]

    @State private var newName = ""
    @State private var isAdding = false
    @State private var renaming: VideoCollection?
    @State private var renameText = ""
    @State private var error: String?

    private var manager: CategoryManager { services.categories }

    private var channelCountByCategory: [PersistentIdentifier: Int] {
        rules.reduce(into: [:]) { counts, rule in
            for c in rule.collections { counts[c.persistentModelID, default: 0] += 1 }
        }
    }

    private var uncategorizedCount: Int {
        let filed = Set(rules.compactMap { $0.topicCollections.isEmpty ? nil : $0.channelId })
        return subscriptions.filter { !filed.contains($0.channelId) }.count
    }

    var body: some View {
        Form {
            classifierSection
            categoriesSection
        }
        .navigationTitle("Categories")
        .alert("New category", isPresented: $isAdding) {
            TextField("Name", text: $newName)
            Button("Add") { add() }
            Button("Cancel", role: .cancel) { newName = "" }
        }
        .alert("Rename category", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Rename") { rename() }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private var classifierSection: some View {
        Section {
            if manager.canClassify {
                Label("On-device model available", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Label(
                    ChannelCategorizerFactory.systemModelUnavailableReason()
                        ?? "Automatic categories aren't available.",
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.secondary)
            }

            switch manager.status {
            case .running(let done, let total):
                ProgressView(value: Double(done), total: Double(max(1, total))) {
                    Text("Sorting channels \(done)/\(total)").monospacedDigit()
                }
                Button("Stop", role: .destructive) { manager.cancel() }
            case .failed(let message):
                Text(message).font(.caption).foregroundStyle(.red)
            case .idle:
                EmptyView()
            }

            LabeledContent("Uncategorized channels", value: "\(uncategorizedCount)")
            if manager.lastRunFailures > 0 {
                LabeledContent("Skipped by the model last run", value: "\(manager.lastRunFailures)")
                    .foregroundStyle(.secondary)
            }

            Button("Sort uncategorized channels") {
                manager.start(scope: .unassignedAndUnsure)
            }
            .disabled(!manager.canClassify || manager.isRunning || uncategorizedCount == 0)

            Button("Re-sort all automatic assignments") {
                manager.start(scope: .allAutomatic)
            }
            .disabled(!manager.canClassify || manager.isRunning)
        } header: {
            Text("Automatic sorting")
        } footer: {
            Text("""
            Channels are sorted on-device by Apple's language model from the \
            channel name, description and recent video titles, into up to \
            three categories each. Nothing leaves the phone. Channels you \
            file by hand are never re-sorted.
            """)
        }
    }

    private var categoriesSection: some View {
        Section {
            ForEach(categories) { category in
                if category.isPriority {
                    // Built in: no rename, no delete. Shown so the count is
                    // visible and the list matches the chip row.
                    LabeledContent {
                        Text("\(channelCountByCategory[category.persistentModelID] ?? 0)")
                            .monospacedDigit()
                    } label: {
                        Label(category.name, systemImage: "star")
                        Text("Hand-picked. Never sorted automatically.")
                    }
                    .deleteDisabled(true)
                } else {
                    Button {
                        renaming = category
                        renameText = category.name
                    } label: {
                        LabeledContent(category.name) {
                            Text("\(channelCountByCategory[category.persistentModelID] ?? 0)")
                                .monospacedDigit()
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
            .onDelete(perform: delete)

            Button("Add category…", systemImage: "plus") { isAdding = true }

            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Categories")
        } footer: {
            Text("Tap to rename. A channel can be in several categories; deleting one drops it from those channels without touching their other categories. After adding a category, use \"Re-sort all\" to let the model consider it.")
        }
    }

    private func add() {
        do {
            try manager.addCategory(named: newName)
            newName = ""
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func rename() {
        guard let renaming else { return }
        do {
            try manager.rename(renaming, to: renameText)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        self.renaming = nil
    }

    private func delete(at offsets: IndexSet) {
        do {
            for index in offsets {
                try manager.delete(categories[index])
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
