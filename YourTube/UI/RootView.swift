import SwiftUI

struct RootView: View {
    @Environment(AppServices.self) private var services

    /// The tabs, in bar order. Selection is tracked rather than left to
    /// `TabView` so a tab can tell whether it's the one showing; see
    /// `LazyTab`.
    private enum Tab: Hashable {
        case shows, feed, channels, settings
    }

    @State private var selection = Tab.shows

    var body: some View {
        TabView(selection: $selection) {
            LazyTab(isSelected: selection == .shows) { ShowsView() }
                .tabItem { Label("Shows", systemImage: "tv") }
                .tag(Tab.shows)

            LazyTab(isSelected: selection == .feed) { FeedView() }
                .tabItem { Label("Feed", systemImage: "play.square.stack") }
                .tag(Tab.feed)

            LazyTab(isSelected: selection == .channels) { ChannelsView() }
                .tabItem { Label("Channels", systemImage: "person.2") }
                .tag(Tab.channels)

            LazyTab(isSelected: selection == .settings) { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gear") }
                .tag(Tab.settings)
        }
        .task {
            services.categories.seedDefaultCategoriesIfNeeded()
            try? services.categories.migrateLegacyRules()
            _ = try? services.upNext.migrateLegacySaves()
            // Attempt a silent token refresh on launch so a still-valid session
            // goes straight to the feed without a sign-in prompt.
            _ = try? await services.auth.validAccessToken()
            services.categories.classifyUnassignedInBackground()
            // Catches videos stored before the cleaner existed, and re-cleans
            // everything after a version bump. See `TitleCleaner`.
            services.titles.cleanStaleInBackground()
            services.showDetector.detectInBackground()
        }
        .onChange(of: services.feed.lastRefreshedAt) {
            // New subscriptions arrive via refresh; file them as they appear.
            services.categories.classifyUnassignedInBackground()
            services.titles.cleanStaleInBackground()
            // New uploads can turn a channel into a show, or stop it being one.
            services.showDetector.detectInBackground()
        }
    }
}

/// Shown when `Config.plist` is missing or incomplete, which is the state a
/// fresh clone starts in.
struct SetupInstructionsView: View {
    let error: Error

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label("Setup needed", systemImage: "wrench.and.screwdriver")
                    .font(.title2.bold())

                Text(error.localizedDescription)
                    .foregroundStyle(.secondary)

                Divider()

                Text("""
                1. Create a Google Cloud project and enable the **YouTube Data API v3**.
                2. Create an **OAuth client ID** of type *iOS* with this app's bundle ID.
                3. Copy `Config.example.plist` to `Config.plist` and fill in the client ID \
                and reversed client ID.
                4. Put the same reversed client ID in `Info.plist` under `CFBundleURLSchemes`.
                5. Add your Google account as a **test user** on the OAuth consent screen.

                See `README.md` for the full walkthrough.
                """)
                .font(.callout)
            }
            .padding()
        }
    }
}
