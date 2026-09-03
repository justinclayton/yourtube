import SwiftUI
import SwiftData

struct SubscriptionsView: View {
    @Environment(AppServices.self) private var services
    @AppStorage(SettingsKeys.showShorts) private var showShorts = false
    @AppStorage(SettingsKeys.feedCategory) private var feedCategory = ""
    @AppStorage(SettingsKeys.channelDailyCap) private var channelDailyCap = SettingsKeys.defaultChannelDailyCap

    @Query(sort: [SortDescriptor(\VideoCollection.sortOrder), SortDescriptor(\VideoCollection.name)])
    private var categories: [VideoCollection]
    @Query private var rules: [ChannelRule]
    @Query private var subscriptions: [Subscription]

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
    /// A channel appears under every category it carries.
    private var channelFilter: [String]? {
        let feedCategory = selectedCategory.wrappedValue
        guard !feedCategory.isEmpty else { return nil }
        let filedIn = rules.reduce(into: [String: Set<String>]()) { map, rule in
            let names = Set(rule.collections.map(\.name))
            if !names.isEmpty { map[rule.channelId] = names }
        }
        if feedCategory == CategoryManager.uncategorizedName {
            return subscriptions.map(\.channelId).filter { filedIn[$0] == nil }
        }
        return filedIn.filter { $0.value.contains(feedCategory) }.map(\.key)
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
                    channelDailyCap: channelDailyCap
                )
            }
            .navigationTitle("Subscriptions")
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

/// Horizontal row of category filters above the feed. "All" (empty selection)
/// is one chip among the rest; the row scrolls the remembered chip into view
/// on launch so a restored selection is visible, not off to the right.
private struct CategoryChips: View {
    let names: [String]
    @Binding var selected: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip("All", isOn: selected.isEmpty) { selected = "" }
                        .id("")
                    ForEach(names, id: \.self) { name in
                        chip(name, isOn: selected == name) {
                            selected = selected == name ? "" : name
                        }
                        .id(name)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .onAppear { proxy.scrollTo(selected, anchor: .center) }
        }
    }

    private func chip(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(isOn ? .semibold : .regular))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.fill.tertiary), in: Capsule())
                .foregroundStyle(isOn ? .white : .primary)
        }
        .buttonStyle(.plain)
    }
}

/// Split out so `@Query` can take a predicate that depends on the Shorts
/// toggle and category filter — the macro needs them fixed at init time.
private struct SubscriptionFeedList: View {
    @Environment(AppServices.self) private var services
    @Query private var videos: [Video]
    let channelDailyCap: Int
    /// Folds the user has opened, keyed by `ChannelDailyCap.key`.
    @State private var expandedFolds: Set<String> = []

    init(showShorts: Bool, channelIds: [String]?, channelDailyCap: Int) {
        self.channelDailyCap = channelDailyCap
        let predicate: Predicate<Video>?
        switch (showShorts, channelIds) {
        case (true, nil):
            predicate = nil
        case (false, nil):
            predicate = #Predicate<Video> { !$0.isLikelyShort }
        case (true, let ids?):
            predicate = #Predicate<Video> { ids.contains($0.channelId) }
        case (false, let ids?):
            predicate = #Predicate<Video> { ids.contains($0.channelId) && !$0.isLikelyShort }
        }
        _videos = Query(
            filter: predicate,
            sort: [SortDescriptor(\Video.publishedAt, order: .reverse)]
        )
    }

    var body: some View {
        Group {
            if videos.isEmpty {
                EmptyFeedView()
            } else {
                List {
                    ForEach(groupedByDay, id: \.day) { group in
                        Section(group.day.formatted(.dateTime.weekday(.wide).month().day())) {
                            ForEach(rows(for: group)) { row in
                                switch row {
                                case .video(let video):
                                    NavigationLink {
                                        PlayerView(video: video)
                                    } label: {
                                        VideoRow(video: video)
                                    }
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
                }
                .listStyle(.plain)
            }
        }
        .refreshable { await services.feed.refresh() }
    }

    /// The Shorts filter is already in the `@Query` predicate, so hidden Shorts
    /// never count against the cap.
    private func rows(for group: (day: Date, videos: [Video])) -> [FeedRow<Video>] {
        ChannelDailyCap.apply(
            group.videos,
            cap: channelDailyCap,
            day: group.day,
            expanded: expandedFolds,
            channelId: \.channelId,
            channelTitle: \.channelTitle
        )
    }

    private var groupedByDay: [(day: Date, videos: [Video])] {
        let calendar = Calendar.current
        let buckets = Dictionary(grouping: videos) {
            calendar.startOfDay(for: $0.publishedAt)
        }
        return buckets
            .map { (day: $0.key, videos: $0.value) }
            .sorted { $0.day > $1.day }
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

private struct RefreshButton: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        Group {
            switch services.feed.status {
            case .refreshing(let completed, let total):
                if total > 0 {
                    ProgressView(value: Double(completed), total: Double(total))
                        .progressViewStyle(.circular)
                } else {
                    ProgressView()
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
