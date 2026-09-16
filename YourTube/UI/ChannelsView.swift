import SwiftUI
import SwiftData

/// Which of the two Channels presentations is showing. Persisted, so the
/// choice survives a relaunch the way the Shows grid's category chip does.
enum ChannelsPresentation: String {
    case list, grid
}

/// Browse the feed one subscribed channel at a time, grouped by category. A
/// channel with several categories is listed under each of them; Priority is
/// the first group. Inside every group the channels flagged as shows come
/// first, separated from the rest by a labelled rule, so the split the app
/// has made is visible without reading every row's glyph. A toolbar toggle
/// switches between this grouped list and an avatar grid
/// (`ChannelsGridView`); both read the same grouping and share the same
/// long-press menu (`ChannelRowMenu`), so they can't drift out of sync.
struct ChannelsView: View {
    @AppStorage(SettingsKeys.showShorts) private var showShorts = false
    @AppStorage(SettingsKeys.channelsPresentation) private var presentation = ChannelsPresentation.list
    /// Local, name-only filter over cached subscriptions; see `LocalSearch`.
    @State private var searchQuery = ""

    var body: some View {
        NavigationStack {
            ChannelList(showShorts: showShorts, searchQuery: searchQuery, presentation: presentation)
                .navigationTitle("Channels")
                .searchable(text: $searchQuery, prompt: "Search channels")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            presentation = presentation == .list ? .grid : .list
                        } label: {
                            Image(systemName: presentation == .list ? "square.grid.3x3" : "list.bullet")
                        }
                        .accessibilityLabel(presentation == .list ? "Show as grid" : "Show as list")
                    }
                }
        }
    }
}

/// Split out so the unwatched query can depend on the Shorts toggle, which
/// `@Query` needs fixed at init time.
private struct ChannelList: View {
    @Environment(AppServices.self) private var services
    @Environment(\.modelContext) private var modelContext
    let showShorts: Bool
    let searchQuery: String
    let presentation: ChannelsPresentation

    @Query(sort: \Subscription.title) private var allSubscriptions: [Subscription]
    /// Subscriptions narrowed by the search field; everything when it's empty.
    private var subscriptions: [Subscription] {
        LocalSearch.filter(allSubscriptions, query: searchQuery) { [$0.title] }
    }
    @Query(sort: [SortDescriptor(\VideoCollection.sortOrder), SortDescriptor(\VideoCollection.name)])
    private var categories: [VideoCollection]
    @Query private var rules: [ChannelRule]
    /// The show catalogue, so a row can say at a glance whether the channel
    /// is one. Tombstones for "not a show" are rows too; `isActive` sorts them.
    @Query private var showRecords: [Show]
    /// Unwatched videos per channel, read from the store when this list is on
    /// screen and after each save. Not a live query over every unwatched
    /// video: that one re-counted thousands of rows on every store change
    /// whichever tab was showing (issue #66), and not a `fetchCount` per row
    /// either, which is hundreds of round trips for one screen. See
    /// `StoreCounts.unwatchedByChannel(in:includingShorts:)`.
    @State private var unwatchedByChannel: [String: Int] = [:]

    @State private var collapsed: Set<String> = []
    @State private var filing: Subscription?
    /// The channel whose playlists are being browsed, if any.
    @State private var pickingPlaylist: Subscription?
    @State private var channelError: String?

    private var priorityChannelIds: Set<String> {
        Set(rules.filter(\.isPriority).map(\.channelId))
    }

    /// Channels that are themselves shows. A channel that merely hosts a
    /// playlist-backed show isn't one — Team Coco puts out clips and tour
    /// footage as well as the podcast — so the flag and the screen icon read
    /// channel-backed rows only.
    private var showChannelIds: Set<String> {
        Set(showRecords.filter { $0.isActive && !$0.isPlaylistBacked }.map(\.channelId))
    }

    init(showShorts: Bool, searchQuery: String, presentation: ChannelsPresentation) {
        self.showShorts = showShorts
        self.searchQuery = searchQuery
        self.presentation = presentation
    }

    private var groups: [ChannelGroup] {
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

        let shows = showChannelIds
        var result: [ChannelGroup] = categories.compactMap { c in
            guard let subs = byCollection[c.persistentModelID], !subs.isEmpty else { return nil }
            return ChannelGroup(id: c.name, title: c.name, collection: c, channels: subs, shows: shows, unwatched: count(subs))
        }
        if !uncategorized.isEmpty {
            result.append(ChannelGroup(
                id: CategoryManager.uncategorizedName,
                title: CategoryManager.uncategorizedName,
                collection: nil,
                channels: uncategorized,
                shows: shows,
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
                description: Text("Refresh the Feed tab to pull in your channels.")
            )
        } else if subscriptions.isEmpty {
            ContentUnavailableView.search(text: searchQuery)
        } else {
            VStack(spacing: 0) {
                if case .running(let done, let total) = services.categories.status {
                    HStack {
                        ProgressView(value: Double(done), total: Double(max(1, total)))
                        Text("Sorting channels \(done)/\(total)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
                switch presentation {
                case .list:
                    listBody(unwatchedByChannel: unwatchedByChannel)
                case .grid:
                    ChannelsGridView(
                        groups: groups,
                        unwatchedByChannel: unwatchedByChannel,
                        showChannelIds: showChannelIds,
                        priorityChannelIds: priorityChannelIds,
                        showShorts: showShorts,
                        collapsed: $collapsed,
                        onFile: { filing = $0 },
                        onAddPlaylist: { pickingPlaylist = $0 },
                        onError: { channelError = $0 }
                    )
                }
            }
            .sheet(item: $filing) { subscription in
                CategoryPickerSheet(subscription: subscription, categories: categories)
            }
            .sheet(item: $pickingPlaylist) { subscription in
                PlaylistShowPicker(subscription: subscription)
            }
            .alert("Couldn't update channel", isPresented: Binding(
                get: { channelError != nil },
                set: { if !$0 { channelError = nil } }
            )) {
                Button("OK", role: .cancel) { channelError = nil }
            } message: {
                Text(channelError ?? "")
            }
            .recomputingFromStore(id: showShorts) {
                unwatchedByChannel = (try? StoreCounts.unwatchedByChannel(
                    in: modelContext,
                    includingShorts: showShorts
                )) ?? [:]
            }
        }
    }

    private func listBody(unwatchedByChannel: [String: Int]) -> some View {
        List {
            ForEach(groups) { group in
                Section {
                    if !collapsed.contains(group.id) {
                        // A channel can appear in several groups, so the
                        // row identity has to include the group.
                        ForEach(group.shows, id: \.channelId) { subscription in
                            row(for: subscription, unwatchedByChannel: unwatchedByChannel)
                        }
                        if group.isSplit {
                            ChannelSplitRule()
                                .listRowSeparator(.hidden)
                                .padding(.top, 6)
                        }
                        ForEach(group.others, id: \.channelId) { subscription in
                            row(for: subscription, unwatchedByChannel: unwatchedByChannel)
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
    }

    /// One channel's row, used on both sides of the split.
    private func row(for subscription: Subscription, unwatchedByChannel: [String: Int]) -> some View {
        let menu = ChannelRowMenu(
            subscription: subscription,
            isPriority: priorityChannelIds.contains(subscription.channelId),
            isShow: showChannelIds.contains(subscription.channelId),
            services: services,
            onFile: { filing = subscription },
            onAddPlaylist: { pickingPlaylist = subscription },
            onError: { channelError = $0 }
        )
        return NavigationLink {
            ChannelView(subscription: subscription, showShorts: showShorts)
        } label: {
            ChannelRow(
                subscription: subscription,
                unwatchedCount: unwatchedByChannel[subscription.channelId] ?? 0,
                isShow: showChannelIds.contains(subscription.channelId)
            )
        }
        .swipeActions(edge: .leading) {
            menu.categoriesButton.tint(.indigo)
            menu.priorityButton.tint(.orange)
            menu.showButton.tint(.purple)
        }
        .contextMenu {
            menu.contextMenuContent
        }
    }
}

/// One category section from `ChannelList.groups`: shared file-scope so
/// `ChannelsGridView` groups its tiles exactly the way the list groups its
/// rows.
///
/// Within a group the channels are split once, here, so both presentations
/// draw the same boundary: the ones flagged as shows first, then the rest,
/// each half keeping the title order the query gave it.
struct ChannelGroup: Identifiable {
    let id: String
    let title: String
    let collection: VideoCollection?
    /// The group's channels that are shows, listed first.
    let shows: [Subscription]
    /// Everything else in the group, in the same order it arrived.
    let others: [Subscription]
    let unwatched: Int

    init(id: String, title: String, collection: VideoCollection?, channels: [Subscription], shows showIds: Set<String>, unwatched: Int) {
        self.id = id
        self.title = title
        self.collection = collection
        self.shows = channels.filter { showIds.contains($0.channelId) }
        self.others = channels.filter { !showIds.contains($0.channelId) }
        self.unwatched = unwatched
    }

    /// Every channel in the group, shows first.
    var channels: [Subscription] { shows + others }
    /// Whether there is a boundary to draw. A group that is all shows or no
    /// shows has nothing to split, and stays as quiet as it was before.
    var isSplit: Bool { !shows.isEmpty && !others.isEmpty }
}

/// The line between a group's shows and its other channels. Labelled rather
/// than a bare rule, because an unlabelled divider only says "something
/// changed here" — naming the half below it makes the half above it read as
/// the shows without a second caption under every category header.
struct ChannelSplitRule: View {
    var body: some View {
        HStack(spacing: 8) {
            Text("Other channels")
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            VStack { Divider() }
        }
        .accessibilityElement()
        .accessibilityLabel("Other channels")
    }
}

/// The categories sheet, Priority toggle, and show flag toggle for one
/// channel — the actions the list row's swipe/long-press menu and the grid
/// tile's long-press menu both offer. Not a `View`: swipe actions need a
/// distinct tint per button applied by the caller, while the context menu
/// just lists the three together, so each button is exposed separately
/// rather than baked into one fixed layout.
struct ChannelRowMenu {
    let subscription: Subscription
    let isPriority: Bool
    let isShow: Bool
    let services: AppServices
    let onFile: () -> Void
    /// Opens the playlist picker for this channel. Menu-only: it needs a list
    /// from YouTube rather than one tap, so it has no swipe action.
    let onAddPlaylist: () -> Void
    let onError: (String) -> Void

    var categoriesButton: some View {
        Button {
            onFile()
        } label: {
            Label("Categories", systemImage: "folder")
        }
    }

    /// One tap in or out of Priority. Separate from the category picker
    /// because it's the action taken most, and it shouldn't lock the
    /// channel's topics against the classifier the way manual filing does.
    var priorityButton: some View {
        Button {
            do {
                try services.categories.setPriority(
                    !isPriority,
                    channelId: subscription.channelId,
                    channelTitle: subscription.title
                )
            } catch {
                onError(error.localizedDescription)
            }
        } label: {
            Label(
                isPriority ? "Remove priority" : "Mark as priority",
                systemImage: isPriority ? "star.slash" : "star"
            )
        }
    }

    /// The manual show flag, beside Priority because filing a channel should
    /// be one stop. Both directions are recorded, not just "yes": marking a
    /// channel "Not a show" is a standing decision the automatic detector,
    /// when it lands, isn't allowed to overrule.
    var showButton: some View {
        Button {
            do {
                try services.shows.setIsShow(
                    !isShow,
                    channelId: subscription.channelId,
                    channelTitle: subscription.title
                )
            } catch {
                onError(error.localizedDescription)
            }
        } label: {
            Label(
                isShow ? "Not a show" : "Mark as show",
                systemImage: isShow ? "tv.slash" : "tv"
            )
        }
    }

    /// A playlist within a channel can be a show of its own: a podcast hosted
    /// on a network channel, or a series-based show with a playlist per
    /// series.
    var addPlaylistButton: some View {
        Button {
            onAddPlaylist()
        } label: {
            Label("Add playlist as show…", systemImage: "list.bullet.rectangle")
        }
    }

    @ViewBuilder var contextMenuContent: some View {
        categoriesButton
        priorityButton
        showButton
        addPlaylistButton
    }
}

struct GroupHeader: View {
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
    /// Channels flagged as shows carry a small screen so the split the app
    /// has made is visible without opening anything.
    let isShow: Bool

    var body: some View {
        HStack(spacing: 12) {
            ChannelAvatar(url: subscription.thumbnailURL, size: 44)
            Text(subscription.title)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            if isShow {
                Image(systemName: "tv")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Show")
            }
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

/// Manually file one channel under any number of categories, and set the two
/// hand-only flags. Each topic toggle saves immediately and marks the rule
/// user-set so the classifier leaves it alone from then on. Priority and the
/// show flag have their own switches: flipping either doesn't lock the topics.
private struct CategoryPickerSheet: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    let subscription: Subscription
    let categories: [VideoCollection]

    @State private var selected: Set<PersistentIdentifier> = []
    @State private var isPriority = false
    @State private var isShow = false
    /// The detector's reasons, when it was the detector that flagged this
    /// channel. Empty for a hand-made flag.
    @State private var showReasons: [String] = []
    /// The category classifier's evidence for this channel's rule, when it
    /// was the classifier that filed it. Nil for a hand-filed channel, or one
    /// never classified at all.
    @State private var classifierEvidence: ChannelRule?
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
                    Toggle(isOn: showBinding) {
                        Label("Show", systemImage: "tv")
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        // A guess has to say why, here as much as on the show
                        // page: this is where it gets corrected.
                        if !showReasons.isEmpty {
                            Text("Flagged automatically: " + showReasons.joined(separator: "; ") + ".")
                        }
                        Text("Shows get a poster in Your Shows on the Shows tab, with a count of what you haven't watched. Turning it off records \u{201C}not a show\u{201D}, which automatic sorting can never undo.")
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
                if let classifierEvidence {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            if let raw = classifierEvidence.classifierRawAnswer {
                                Text("Model answered: " + (raw.isEmpty ? "nothing usable" : raw.joined(separator: ", ")))
                                if let dominant = classifierEvidence.classifierDominantCategoryId {
                                    Text("YouTube files it under \(YouTubeCategory.name(forId: dominant))")
                                }
                            } else {
                                Text("Not recorded")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } header: {
                        Text("Why")
                    }
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
                isShow = (try? services.shows.isShow(channelId: subscription.channelId)) ?? false
                let record = try? services.shows.record(forChannelId: subscription.channelId)
                showReasons = record?.flagOrigin == .heuristic ? (record?.detectorReasons ?? []) : []
                // A user-set rule shows no reasons: it's the user's call now,
                // not the classifier's guess.
                classifierEvidence = (rule?.isUserSet == false && rule?.classifiedAt != nil) ? rule : nil
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

    private var showBinding: Binding<Bool> {
        Binding(
            get: { isShow },
            set: { isOn in
                do {
                    try services.shows.setIsShow(isOn, channelId: subscription.channelId, channelTitle: subscription.title)
                    isShow = isOn
                    // The flag is the user's now, so the guess's reasons go.
                    showReasons = []
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
            // The filing is the user's now; the classifier's evidence stays
            // on the rule for the export, but "Why" is for a guess.
            classifierEvidence = nil
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
        CachedAsyncImage(
            url: url.flatMap(URL.init(string:)),
            size: CGSize(width: size, height: size)
        ) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            Circle().fill(.quaternary)
                .overlay(Image(systemName: "person.fill").foregroundStyle(.secondary))
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
    @State private var isPickingPlaylist = false

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
                    Text(subscription.title)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // The other half of "Add playlist as show": on the channel page
            // itself, for when you got here by browsing rather than by
            // long-pressing a row.
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isPickingPlaylist = true
                } label: {
                    Label("Add playlist as show", systemImage: "list.bullet.rectangle.portrait")
                }
            }
        }
        .sheet(isPresented: $isPickingPlaylist) {
            PlaylistShowPicker(subscription: subscription)
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
