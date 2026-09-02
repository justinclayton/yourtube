import SwiftUI
import SwiftData

/// Browse the feed one subscribed channel at a time.
struct ChannelsView: View {
    @AppStorage(SettingsKeys.showShorts) private var showShorts = false

    var body: some View {
        NavigationStack {
            ChannelList(showShorts: showShorts)
                .navigationTitle("Channels")
        }
    }
}

/// Split out so the unwatched query can depend on the Shorts toggle, which
/// `@Query` needs fixed at init time.
private struct ChannelList: View {
    let showShorts: Bool
    @Query(sort: \Subscription.title) private var subscriptions: [Subscription]
    /// One query for every unwatched video, counted per channel here, rather
    /// than a live query per row — with several hundred subscriptions the
    /// per-row version makes the list unusable.
    @Query private var unwatched: [Video]

    init(showShorts: Bool) {
        self.showShorts = showShorts
        _unwatched = Query(filter: showShorts
            ? #Predicate<Video> { !$0.isWatched }
            : #Predicate<Video> { !$0.isWatched && !$0.isLikelyShort }
        )
    }

    private var unwatchedByChannel: [String: Int] {
        unwatched.reduce(into: [:]) { counts, video in counts[video.channelId, default: 0] += 1 }
    }

    var body: some View {
        if subscriptions.isEmpty {
            ContentUnavailableView(
                "No channels yet",
                systemImage: "person.2",
                description: Text("Refresh the Subscriptions tab to pull in your channels.")
            )
        } else {
            let counts = unwatchedByChannel
            List(subscriptions) { subscription in
                NavigationLink {
                    ChannelView(subscription: subscription, showShorts: showShorts)
                } label: {
                    ChannelRow(
                        subscription: subscription,
                        unwatchedCount: counts[subscription.channelId] ?? 0
                    )
                }
            }
            .listStyle(.plain)
        }
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
