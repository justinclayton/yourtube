import SwiftUI
import SwiftData

/// Browse the feed one subscribed channel at a time, grouped by category. A
/// channel with several categories is listed under each of them; Priority is
/// the first group.
struct ChannelsView: View {
    @AppStorage(SettingsKeys.showShorts) private var showShorts = false
    /// Local, name-only filter over cached subscriptions; see `LocalSearch`.
    @State private var searchQuery = ""

    var body: some View {
        NavigationStack {
            ChannelList(showShorts: showShorts, searchQuery: searchQuery)
                .navigationTitle("Channels")
                .searchable(text: $searchQuery, prompt: "Search channels")
        }
    }
}

/// Split out so the unwatched query can depend on the Shorts toggle, which
/// `@Query` needs fixed at init time.
private struct ChannelList: View {
    @Environment(AppServices.self) private var services
    let showShorts: Bool
    let searchQuery: String

    @Query(sort: \Subscription.title) private var allSubscriptions: [Subscription]
    /// Subscriptions narrowed by the search field; everything when it's empty.
    private var subscriptions: [Subscription] {
        LocalSearch.filter(allSubscriptions, query: searchQuery) { [$0.title] }
    }
    @Query(sort: [SortDescriptor(\VideoCollection.sortOrder), SortDescriptor(\VideoCollection.name)])
    private var categories: [VideoCollection]
    @Query private var rules: [ChannelRule]
    /// One query for every unwatched video, counted per channel here, rather
    /// than a live query per row — with several hundred subscriptions the
    /// per-row version makes the list unusable.
    @Query private var unwatched: [Video]

    @State private var collapsed: Set<String> = []
    @State private var filing: Subscription?
    @State private var priorityError: String?

    private var priorityChannelIds: Set<String> {
        Set(rules.filter(\.isPriority).map(\.channelId))
    }

    init(showShorts: Bool, searchQuery: String) {
        self.showShorts = showShorts
        self.searchQuery = searchQuery
        _unwatched = Query(filter: showShorts
            ? #Predicate<Video> { !$0.isWatched }
            : #Predicate<Video> { !$0.isWatched && !$0.isLikelyShort }
        )
    }

    private struct Group: Identifiable {
        let id: String
        let title: String
        let collection: VideoCollection?
        let channels: [Subscription]
        let unwatched: Int
    }

    private var groups: [Group] {
        let unwatchedByChannel = unwatched.reduce(into: [String: Int]()) {
            $0[$1.channelId, default: 0] += 1
        }
        let ruleByChannel = Dictionary(rules.map { ($0.channelId, $0) }, uniquingKeysWith: { first, _ in first })
        var byCollection: [PersistentIdentifier: [Subscription]] = [:]
        var uncategorized: [Subscription] = []
        for sub in subscriptions {
            let rule = ruleByChannel[sub.channelId]
            for c in rule?.collections ?? [] {
                byCollection[c.persistentModelID, default: []].append(sub)
            }
            // Priority says nothing about topic, so a priority-only channel
            // is still listed here for filing.
            if rule?.topicCollections.isEmpty ?? true {
                uncategorized.append(sub)
            }
        }
        func count(_ subs: [Subscription]) -> Int {
            subs.reduce(0) { $0 + (unwatchedByChannel[$1.channelId] ?? 0) }
        }

        var result: [Group] = categories.compactMap { c in
            guard let subs = byCollection[c.persistentModelID], !subs.isEmpty else { return nil }
            return Group(id: c.name, title: c.name, collection: c, channels: subs, unwatched: count(subs))
        }
        if !uncategorized.isEmpty {
            result.append(Group(
                id: CategoryManager.uncategorizedName,
                title: CategoryManager.uncategorizedName,
                collection: nil,
                channels: uncategorized,
                unwatched: count(uncategorized)
            ))
        }
        return result
    }

    var body: some View {
        if allSubscriptions.isEmpty {
            ContentUnavailableView(
                "No channels yet",
                systemImage: "person.2",
                description: Text("Refresh the Subscriptions tab to pull in your channels.")
            )
        } else if subscriptions.isEmpty {
            ContentUnavailableView.search(text: searchQuery)
        } else {
            let unwatchedByChannel = unwatched.reduce(into: [String: Int]()) {
                $0[$1.channelId, default: 0] += 1
            }
            List {
                if case .running(let done, let total) = services.categories.status {
                    HStack {
                        ProgressView(value: Double(done), total: Double(max(1, total)))
                        Text("Sorting channels \(done)/\(total)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                ForEach(groups) { group in
                    Section {
                        if !collapsed.contains(group.id) {
                            // A channel can appear in several groups, so the
                            // row identity has to include the group.
                            ForEach(group.channels, id: \.channelId) { subscription in
                                NavigationLink {
                                    ChannelView(subscription: subscription, showShorts: showShorts)
                                } label: {
                                    ChannelRow(
                                        subscription: subscription,
                                        unwatchedCount: unwatchedByChannel[subscription.channelId] ?? 0
                                    )
                                }
                                .swipeActions(edge: .leading) {
                                    Button {
                                        filing = subscription
                                    } label: {
                                        Label("Categories", systemImage: "folder")
                                    }
                                    .tint(.indigo)
                                    priorityButton(for: subscription)
                                        .tint(.orange)
                                }
                                .contextMenu {
                                    Button("Categories…", systemImage: "folder") {
                                        filing = subscription
                                    }
                                    priorityButton(for: subscription)
                                }
                            }
                        }
                    } header: {
                        GroupHeader(
                            title: group.title,
                            channelCount: group.channels.count,
                            unwatched: group.unwatched,
                            isCollapsed: collapsed.contains(group.id)
                        ) {
                            withAnimation(.snappy) {
                                if collapsed.contains(group.id) {
                                    collapsed.remove(group.id)
                                } else {
                                    collapsed.insert(group.id)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .sheet(item: $filing) { subscription in
                CategoryPickerSheet(subscription: subscription, categories: categories)
            }
            .alert("Couldn't update priority", isPresented: Binding(
                get: { priorityError != nil },
                set: { if !$0 { priorityError = nil } }
            )) {
                Button("OK", role: .cancel) { priorityError = nil }
            } message: {
                Text(priorityError ?? "")
            }
        }
    }

    /// One tap in or out of Priority. Separate from the category picker
    /// because it's the action taken most, and it shouldn't lock the
    /// channel's topics against the classifier the way manual filing does.
    private func priorityButton(for subscription: Subscription) -> some View {
        let isPriority = priorityChannelIds.contains(subscription.channelId)
        return Button {
            do {
                try services.categories.setPriority(
                    !isPriority,
                    channelId: subscription.channelId,
                    channelTitle: subscription.title
                )
            } catch {
                priorityError = error.localizedDescription
            }
        } label: {
            Label(
                isPriority ? "Remove priority" : "Mark as priority",
                systemImage: isPriority ? "star.slash" : "star"
            )
        }
    }
}

private struct GroupHeader: View {
    let title: String
    let channelCount: Int
    let unwatched: Int
    let isCollapsed: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text("\(channelCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if unwatched > 0 {
                    Text("\(unwatched) new")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .textCase(nil)
    }
}

private struct ChannelRow: View {
    let subscription: Subscription
    let unwatchedCount: Int

    var body: some View {
        HStack(spacing: 12) {
            ChannelAvatar(url: subscription.thumbnailURL, size: 44)
            Text(subscription.title)
                .font(.body)
                .lineLimit(1)
            Spacer()
            if unwatchedCount > 0 {
                Text("\(unwatchedCount)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.tint.opacity(0.15), in: Capsule())
                    .foregroundStyle(.tint)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Manually file one channel under any number of categories. Each topic
/// toggle saves immediately and marks the rule user-set so the classifier
/// leaves it alone from then on. Priority has its own switch: flipping it
/// doesn't lock the topics.
private struct CategoryPickerSheet: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    let subscription: Subscription
    let categories: [VideoCollection]

    @State private var selected: Set<PersistentIdentifier> = []
    @State private var isPriority = false
    @State private var error: String?

    private var topicCategories: [VideoCollection] { categories.filter { !$0.isPriority } }

    var body: some View {
        NavigationStack {
            List {
                if categories.contains(where: \.isPriority) {
                    Section {
                        Toggle(isOn: priorityBinding) {
                            Label(CategoryManager.priorityName, systemImage: "star")
                        }
                    } footer: {
                        Text("For the few channels you never want to miss. Set by hand only; automatic sorting never changes it.")
                    }
                }
                Section {
                    Button {
                        save([])
                    } label: {
                        HStack {
                            Text(CategoryManager.uncategorizedName).foregroundStyle(.primary)
                            Spacer()
                            if selected.isEmpty {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                    }
                }
                Section {
                    ForEach(topicCategories) { category in
                        Toggle(isOn: binding(for: category)) {
                            Text(category.name)
                        }
                    }
                } header: {
                    Text("Categories")
                } footer: {
                    Text("Pick as many as fit. The channel shows up under each one.")
                }
                if let error {
                    Text(error).foregroundStyle(.red).font(.caption)
                }
            }
            .navigationTitle(subscription.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                let rule = try? services.categories.rule(forChannelId: subscription.channelId)
                selected = Set((rule?.topicCollections ?? []).map(\.persistentModelID))
                isPriority = rule?.isPriority ?? false
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var priorityBinding: Binding<Bool> {
        Binding(
            get: { isPriority },
            set: { isOn in
                do {
                    try services.categories.setPriority(isOn, channelId: subscription.channelId, channelTitle: subscription.title)
                    isPriority = isOn
                    error = nil
                } catch {
                    self.error = error.localizedDescription
                }
            }
        )
    }

    private func binding(for category: VideoCollection) -> Binding<Bool> {
        Binding(
            get: { selected.contains(category.persistentModelID) },
            set: { isOn in
                var next = selected
                if isOn { next.insert(category.persistentModelID) } else { next.remove(category.persistentModelID) }
                save(next)
            }
        )
    }

    private func save(_ ids: Set<PersistentIdentifier>) {
        do {
            try services.categories.assign(
                channelId: subscription.channelId,
                channelTitle: subscription.title,
                to: topicCategories.filter { ids.contains($0.persistentModelID) }
            )
            selected = ids
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct ChannelAvatar: View {
    let url: String?
    let size: CGFloat

    var body: some View {
        AsyncImage(url: url.flatMap(URL.init(string:))) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: .fill)
            default:
                Circle().fill(.quaternary)
                    .overlay(Image(systemName: "person.fill").foregroundStyle(.secondary))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

/// One channel's videos, newest first.
struct ChannelView: View {
    @Environment(AppServices.self) private var services
    let subscription: Subscription
    @Query private var videos: [Video]

    @State private var isLoadingMore = false
    @State private var loadMoreError: String?
    /// Set once a "load older" call returns nothing new, so we stop offering it.
    @State private var reachedEnd = false

    init(subscription: Subscription, showShorts: Bool) {
        self.subscription = subscription
        let channelId = subscription.channelId
        _videos = Query(
            filter: showShorts
                ? #Predicate<Video> { $0.channelId == channelId }
                : #Predicate<Video> { $0.channelId == channelId && !$0.isLikelyShort },
            sort: [SortDescriptor(\Video.publishedAt, order: .reverse)]
        )
    }

    var body: some View {
        List {
            if videos.isEmpty {
                ContentUnavailableView(
                    "No videos",
                    systemImage: "play.square",
                    description: Text("Nothing stored for this channel yet. Try loading older uploads.")
                )
                .listRowSeparator(.hidden)
            }

            ForEach(videos) { video in
                NavigationLink {
                    PlayerView(video: video)
                } label: {
                    VideoRow(video: video)
                }
            }

            if !reachedEnd {
                loadMoreRow
            }
        }
        .listStyle(.plain)
        .navigationTitle(subscription.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    ChannelAvatar(url: subscription.thumbnailURL, size: 28)
                    Text(subscription.title).font(.headline).lineLimit(1)
                }
            }
        }
    }

    private var loadMoreRow: some View {
        HStack {
            Spacer()
            if isLoadingMore {
                ProgressView()
            } else {
                VStack(spacing: 4) {
                    Button("Load older uploads") {
                        Task { await loadMore() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(services.auth.needsReauth)
                    if let loadMoreError {
                        Text(loadMoreError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            Spacer()
        }
        .listRowSeparator(.hidden)
        .padding(.vertical, 8)
    }

    private func loadMore() async {
        isLoadingMore = true
        loadMoreError = nil
        defer { isLoadingMore = false }
        do {
            let added = try await services.feed.loadOlderUploads(channelId: subscription.channelId)
            if added == 0 { reachedEnd = true }
        } catch {
            loadMoreError = error.localizedDescription
        }
    }
}
