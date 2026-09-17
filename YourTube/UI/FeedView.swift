import SwiftUI
import SwiftData

/// The subscriptions feed: everything new from every subscribed channel,
/// newest first. Peer of the Shows tab; show episodes appear here too.
struct FeedView: View {
    @Environment(AppServices.self) private var services
    @AppStorage(SettingsKeys.showShorts) private var showShorts = false
    @AppStorage(SettingsKeys.feedCategory) private var feedCategory = ""
    @AppStorage(SettingsKeys.channelDailyCap) private var channelDailyCap = SettingsKeys.defaultChannelDailyCap

    @Query(sort: [SortDescriptor(\VideoCollection.sortOrder), SortDescriptor(\VideoCollection.name)])
    private var categories: [VideoCollection]
    @Query private var subscriptions: [Subscription]

    /// Local search over the cached store. Never hits the API; see `LocalSearch`.
    @State private var searchQuery = ""
    /// How many inbox rows the list is asking for. Lives here rather than in
    /// the list because `@Query` takes its descriptor at init, so the window
    /// has to arrive from outside for a change to reach the store. See
    /// `FeedWindow`.
    @State private var window = FeedWindow()

    private var chipNames: [String] {
        categories.map(\.name) + [CategoryManager.uncategorizedName]
    }

    /// The remembered chip, or "All" (empty) if that category has since been
    /// deleted. Falling back rather than showing an empty feed means a stale
    /// selection never greets the user with nothing on launch.
    private var selectedCategory: Binding<String> {
        Binding(
            get: { chipNames.contains(feedCategory) ? feedCategory : "" },
            set: { feedCategory = $0 }
        )
    }

    /// Channel IDs the feed should be limited to, or nil for everything.
    /// A channel appears under every category it carries, Priority included.
    /// Uncategorized means no topic category, so a priority-only channel is
    /// still there to be filed. Routed through `CategoryManager.channelIds(in:)`,
    /// the one derivation the Feed, Your Shows and Channels all share.
    private var channelFilter: [String]? {
        let feedCategory = selectedCategory.wrappedValue
        guard !feedCategory.isEmpty else { return nil }
        return try? services.categories.channelIds(in: feedCategory)
    }

    /// Subscribed channels whose name matches the query, within the current
    /// chip, alphabetical. Empty when not searching.
    private var matchingChannels: [Subscription] {
        let terms = LocalSearch.terms(in: searchQuery)
        guard !terms.isEmpty else { return [] }
        let allowed = channelFilter.map(Set.init)
        return subscriptions
            .filter { allowed?.contains($0.channelId) ?? true }
            .filter { LocalSearch.matches(terms: terms, fields: [$0.title]) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if services.auth.needsReauth {
                    ReauthBanner()
                }
                if !categories.isEmpty {
                    CategoryChips(names: chipNames, selected: selectedCategory)
                }
                SubscriptionFeedList(
                    showShorts: showShorts,
                    channelIds: channelFilter,
                    channelDailyCap: channelDailyCap,
                    searchQuery: searchQuery,
                    matchingChannels: matchingChannels,
                    window: window,
                    showOlder: { window.showOlder() }
                )
            }
            // A different chip is a different feed, so it starts at the top
            // of its own first page rather than inheriting how far the last
            // one had been opened up.
            .onChange(of: selectedCategory.wrappedValue) { window = FeedWindow() }
            .onChange(of: showShorts) { window = FeedWindow() }
            .navigationTitle("Feed")
            .searchable(text: $searchQuery, prompt: "Search titles and channels")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    RefreshButton()
                }
            }
        }
        .task {
            // Heuristic changes apply to already-stored videos without a refresh.
            try? await services.feed.reclassifyStaleVideos()
        }
    }
}

/// Split out so `@Query` can take a predicate that depends on the Shorts
/// toggle and category filter — the macro needs them fixed at init time.
private struct SubscriptionFeedList: View {
    @Environment(AppServices.self) private var services
    @Environment(\.modelContext) private var modelContext
    /// The inbox, one window at a time: matches the Shorts/category filter,
    /// excludes watched and earmarked videos so triaging a row removes it
    /// automatically, and stops at `window.limit` rows. See `FeedWindow`.
    @Query private var videos: [Video]
    /// One row from the same Shorts/category filter without the triage
    /// exclusion — used only to tell "nothing new" apart from "everything's
    /// been triaged" for the empty state, which is a question about whether
    /// anything at all matches, not about how much.
    @Query private var allMatchingVideos: [Video]
    let channelDailyCap: Int
    let searchQuery: String
    let matchingChannels: [Subscription]
    let showShorts: Bool
    let window: FeedWindow
    let showOlder: () -> Void
    /// The inbox predicate, kept so search can ask the store the same
    /// question the window asks, without the window's limit.
    private let inboxPredicate: Predicate<Video>
    /// What the filters amount to, so search re-runs when they change and not
    /// otherwise.
    private let filterKey: String
    /// Folds the user has opened, keyed by `ChannelDailyCap.key`.
    @State private var expandedFolds: Set<String> = []
    /// Search results, fetched from the whole inbox rather than filtered out
    /// of the window: paging the list you scroll is one thing, but a search
    /// that quietly only looked at the newest few hundred videos would be
    /// wrong rather than merely short.
    @State private var searchMatches: [Video] = []
    /// `videos` grouped by day and run past the per-channel daily cap.
    /// `groupedByDay` and `rows(for:)` used to be computed properties, so
    /// SwiftUI re-ran the grouping and the cap pass — a dictionary build, a
    /// sort, and a full pass per day — on every `body` evaluation, not just
    /// when the inbox actually changed. This caches that pipeline's output
    /// and only reruns it from `onChange`, once per real change in the
    /// inputs it depends on. See issue #69.
    @State private var sections: [(day: Date, rows: [FeedRow<Video>])] = []

    init(
        showShorts: Bool,
        channelIds: [String]?,
        channelDailyCap: Int,
        searchQuery: String,
        matchingChannels: [Subscription],
        window: FeedWindow,
        showOlder: @escaping () -> Void
    ) {
        self.channelDailyCap = channelDailyCap
        self.searchQuery = searchQuery
        self.matchingChannels = matchingChannels
        self.showShorts = showShorts
        self.window = window
        self.showOlder = showOlder
        self.filterKey = "\(showShorts)|\(channelIds?.joined(separator: ",") ?? "*")"
        let basePredicate: Predicate<Video>?
        let inboxPredicate: Predicate<Video>
        switch (showShorts, channelIds) {
        case (true, nil):
            basePredicate = nil
            inboxPredicate = #Predicate<Video> { $0.savedForLaterAt == nil && !$0.isWatched }
        case (false, nil):
            basePredicate = #Predicate<Video> { !$0.isLikelyShort }
            inboxPredicate = #Predicate<Video> {
                !$0.isLikelyShort && $0.savedForLaterAt == nil && !$0.isWatched
            }
        case (true, let ids?):
            basePredicate = #Predicate<Video> { ids.contains($0.channelId) }
            inboxPredicate = #Predicate<Video> {
                ids.contains($0.channelId) && $0.savedForLaterAt == nil && !$0.isWatched
            }
        case (false, let ids?):
            basePredicate = #Predicate<Video> { ids.contains($0.channelId) && !$0.isLikelyShort }
            inboxPredicate = #Predicate<Video> {
                ids.contains($0.channelId) && !$0.isLikelyShort
                    && $0.savedForLaterAt == nil && !$0.isWatched
            }
        }
        self.inboxPredicate = inboxPredicate
        let newestFirst = [SortDescriptor(\Video.publishedAt, order: .reverse)]
        var inbox = FetchDescriptor<Video>(predicate: inboxPredicate, sortBy: newestFirst)
        inbox.fetchLimit = window.limit
        _videos = Query(inbox)
        // One row is all the empty state needs to know; fetching every
        // matching video to ask whether there is one is the whole bug.
        var anyMatching = FetchDescriptor<Video>(predicate: basePredicate, sortBy: newestFirst)
        anyMatching.fetchLimit = 1
        _allMatchingVideos = Query(anyMatching)
    }

    private var isSearching: Bool { !LocalSearch.terms(in: searchQuery).isEmpty }

    /// Re-reads the search results: the whole inbox under the current chip
    /// and Shorts setting, narrowed by `LocalSearch`. Runs on every store
    /// save while the field has something in it, so marking a result watched
    /// still takes it off the list.
    private func refreshSearchMatches() {
        guard isSearching else {
            if !searchMatches.isEmpty { searchMatches = [] }
            return
        }
        let descriptor = FetchDescriptor<Video>(
            predicate: inboxPredicate,
            sortBy: [SortDescriptor(\Video.publishedAt, order: .reverse)]
        )
        let all = (try? modelContext.fetch(descriptor)) ?? []
        // The Shorts toggle and category chip are already in the predicate,
        // so search only ever narrows what the chip would show.
        searchMatches = LocalSearch.filter(all, query: searchQuery) {
            [$0.title, $0.displayTitle, $0.channelTitle]
        }
    }

    var body: some View {
        Group {
            if isSearching {
                searchResults
            } else if videos.isEmpty && allMatchingVideos.isEmpty {
                EmptyFeedView()
            } else if videos.isEmpty {
                CaughtUpView()
            } else {
                List {
                    ForEach(sections, id: \.day) { section in
                        Section(section.day.formatted(.dateTime.weekday(.wide).month().day())) {
                            ForEach(section.rows) { row in
                                switch row {
                                case .video(let video):
                                    FeedVideoRow(video: video)
                                case .more(let key, let channelTitle, let hidden):
                                    MoreFromChannelRow(
                                        channelTitle: channelTitle,
                                        count: hidden.count,
                                        isExpanded: expandedFolds.contains(key)
                                    ) {
                                        withAnimation {
                                            if expandedFolds.remove(key) == nil {
                                                expandedFolds.insert(key)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if window.hasOlder(loaded: videos.count) {
                        ShowOlderRow(action: showOlder)
                    }
                }
                .listStyle(.plain)
            }
        }
        .recomputingFromStore(id: filterKey + "\u{1F}" + searchQuery) {
            refreshSearchMatches()
        }
        .onChange(of: videos, initial: true) { recomputeSections() }
        .onChange(of: channelDailyCap) { recomputeSections() }
        .onChange(of: expandedFolds) { recomputeSections() }
        .refreshable { await services.feed.refresh() }
    }

    /// Channel matches sit above video matches so a channel name finds the
    /// channel itself, not just its videos. Videos stay newest first; the
    /// daily cap doesn't apply because a search is already a narrow slice.
    @ViewBuilder
    private var searchResults: some View {
        let matches = searchMatches
        if matches.isEmpty && matchingChannels.isEmpty {
            ContentUnavailableView.search(text: searchQuery)
        } else {
            List {
                if !matchingChannels.isEmpty {
                    Section("Channels") {
                        ForEach(matchingChannels, id: \.channelId) { subscription in
                            NavigationLink {
                                ChannelView(subscription: subscription, showShorts: showShorts)
                            } label: {
                                HStack(spacing: 12) {
                                    ChannelAvatar(url: subscription.thumbnailURL, size: 36)
                                    Text(subscription.title)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
                if !matches.isEmpty {
                    Section("Videos") {
                        ForEach(matches) { video in
                            FeedVideoRow(video: video)
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    /// Groups `videos` by day and runs each day past the per-channel cap,
    /// storing the result in `sections`. Called from `onChange` rather than
    /// a computed property so the dictionary build, sort, and cap pass run
    /// once per real change to the inbox, the cap setting, or which folds
    /// are open — not once per `body` evaluation. See issue #69.
    ///
    /// The Shorts filter is already in the `@Query` predicate, so hidden
    /// Shorts never count against the cap.
    private func recomputeSections() {
        let calendar = Calendar.current
        let buckets = Dictionary(grouping: videos) {
            calendar.startOfDay(for: $0.publishedAt)
        }
        sections = buckets
            .map { day, videos in
                (day: day, rows: ChannelDailyCap.apply(
                    videos,
                    cap: channelDailyCap,
                    day: day,
                    expanded: expandedFolds,
                    channelId: \.channelId,
                    channelTitle: \.channelTitle
                ))
            }
            .sorted { $0.day > $1.day }
    }
}

/// A tappable feed row with swipe-to-triage actions. Both actions rely on
/// the inbox `@Query` predicate excluding watched/earmarked videos, so
/// acting on a row removes it from the list with no manual mutation.
private struct FeedVideoRow: View {
    @Environment(AppServices.self) private var services
    let video: Video
    /// The title this row drew when it first appeared. See `TitleLatch`.
    /// `@State` storage is tied to this row's identity (the video's id, via
    /// `FeedRow`'s `Identifiable` conformance), so it survives `sections`
    /// being recomputed as long as the lazy list keeps this row instance
    /// alive, and resets — showing the new title — only once the list
    /// actually recreates the row, e.g. after it scrolls far enough off
    /// screen to be discarded. See issue #68.
    @State private var titleLatch = TitleLatch()

    var body: some View {
        NavigationLink {
            PlayerView(video: video)
        } label: {
            VideoRow(video: video, displayTitleOverride: titleLatch.displayTitle(current: video.displayTitle))
        }
        .onAppear {
            titleLatch.capture(video.displayTitle)
        }
        .swipeActions(edge: .leading) {
            Button {
                try? services.watchState.earmark(video)
            } label: {
                Label("Earmark", systemImage: "bookmark.fill")
            }
            .tint(.indigo)
        }
        .swipeActions(edge: .trailing) {
            Button {
                try? services.watchState.markWatched(video)
            } label: {
                Label("Watched", systemImage: "checkmark.circle.fill")
            }
            .tint(.green)
        }
    }
}

/// The foot of the feed: another page of older videos, on request.
///
/// The inbox is windowed (see `FeedWindow`), and this is the window's edge
/// made visible — deliberately a row you tap rather than an infinite scroll,
/// so reaching the bottom of the feed still means something.
private struct ShowOlderRow: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Spacer()
                Text("Show older")
                    .font(.subheadline)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .listRowSeparator(.hidden)
    }
}

/// The "+N more from Channel" fold. Tapping toggles the hidden videos inline.
private struct MoreFromChannelRow: View {
    let channelTitle: String
    let count: Int
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack {
                Text(isExpanded
                     ? "Hide \(count) more from \(channelTitle)"
                     : "+\(count) more from \(channelTitle)")
                    .font(.subheadline)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            .foregroundStyle(.secondary)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }
}

private struct EmptyFeedView: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        ContentUnavailableView {
            Label("No videos yet", systemImage: "play.square.stack")
        } description: {
            Text(services.auth.needsReauth
                 ? "Sign in with Google to pull in your subscriptions."
                 : "Pull down to refresh your subscription feed.")
        } actions: {
            if !services.auth.needsReauth {
                Button("Refresh") {
                    Task { await services.feed.refresh() }
                }
            }
        }
    }
}

/// Shown when the current filter matches videos, but every one of them has
/// already been watched or earmarked — distinct from `EmptyFeedView`'s "we
/// have nothing at all yet" so the copy doesn't send a caught-up user
/// looking for a sign-in or a refresh they don't need.
private struct CaughtUpView: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        ContentUnavailableView {
            Label("All caught up", systemImage: "checkmark.circle")
        } description: {
            Text("Everything new has been watched or earmarked to Up Next.")
        } actions: {
            Button("Refresh") {
                Task { await services.feed.refresh() }
            }
        }
    }
}

private struct RefreshButton: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        Group {
            switch services.feed.status {
            case .refreshing(let phase):
                HStack(spacing: 4) {
                    if let progress = phase.progress, progress.total > 0 {
                        ProgressView(value: Double(progress.completed), total: Double(progress.total))
                            .progressViewStyle(.circular)
                    } else {
                        ProgressView()
                    }
                    Text(phase.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            default:
                Button {
                    Task { await services.feed.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(services.auth.needsReauth)
            }
        }
    }
}

/// The weekly re-auth prompt. Deliberately a dismissible-feeling banner rather
/// than a blocking modal — the cached feed is still worth reading while signed
/// out, and this state recurs every 7 days by design.
private struct ReauthBanner: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Session expired")
                    .font(.subheadline.weight(.semibold))
                Text("Google sessions last 7 days for test apps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Sign in") {
                Task { await services.auth.signIn() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(services.auth.isWorking)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.orange.opacity(0.12))
    }
}
