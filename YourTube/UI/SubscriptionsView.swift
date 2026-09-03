import SwiftUI
import SwiftData

struct SubscriptionsView: View {
    @Environment(AppServices.self) private var services
    @AppStorage(SettingsKeys.showShorts) private var showShorts = false
    @AppStorage(SettingsKeys.feedCategory) private var feedCategory = ""

    @Query(sort: [SortDescriptor(\VideoCollection.sortOrder), SortDescriptor(\VideoCollection.name)])
    private var categories: [VideoCollection]
    @Query private var rules: [ChannelRule]
    @Query private var subscriptions: [Subscription]

    /// Channel IDs the feed should be limited to, or nil for everything.
    /// A channel appears under every category it carries.
    private var channelFilter: [String]? {
        guard !feedCategory.isEmpty else { return nil }
        let filedIn = rules.reduce(into: [String: Set<String>]()) { map, rule in
            let names = Set(rule.collections.map(\.name))
            if !names.isEmpty { map[rule.channelId] = names }
        }
        if feedCategory == CategoryManager.uncategorizedName {
            return subscriptions.map(\.channelId).filter { filedIn[$0] == nil }
        }
        // A category that has since been deleted shows an empty feed rather
        // than silently falling back to everything; the chip row makes it
        // obvious and one tap fixes it.
        return filedIn.filter { $0.value.contains(feedCategory) }.map(\.key)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if services.auth.needsReauth {
                    ReauthBanner()
                }
                if !categories.isEmpty {
                    CategoryChips(
                        names: categories.map(\.name) + [CategoryManager.uncategorizedName],
                        selected: $feedCategory
                    )
                }
                SubscriptionFeedList(showShorts: showShorts, channelIds: channelFilter)
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

/// Horizontal row of category filters above the feed. "All" clears it.
private struct CategoryChips: View {
    let names: [String]
    @Binding var selected: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("All", isOn: selected.isEmpty) { selected = "" }
                ForEach(names, id: \.self) { name in
                    chip(name, isOn: selected == name) {
                        selected = selected == name ? "" : name
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
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

    init(showShorts: Bool, channelIds: [String]?) {
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
                            ForEach(group.videos) { video in
                                NavigationLink {
                                    PlayerView(video: video)
                                } label: {
                                    VideoRow(video: video)
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
