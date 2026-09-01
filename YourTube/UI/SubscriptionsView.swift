import SwiftUI
import SwiftData

struct SubscriptionsView: View {
    @Environment(AppServices.self) private var services
    @AppStorage(SettingsKeys.showShorts) private var showShorts = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if services.auth.needsReauth {
                    ReauthBanner()
                }
                SubscriptionFeedList(showShorts: showShorts)
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

/// Split out so `@Query` can take a predicate that depends on the Shorts
/// toggle — the macro needs it fixed at init time.
private struct SubscriptionFeedList: View {
    @Environment(AppServices.self) private var services
    @Query private var videos: [Video]

    init(showShorts: Bool) {
        _videos = Query(
            filter: showShorts ? nil : #Predicate<Video> { !$0.isLikelyShort },
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
