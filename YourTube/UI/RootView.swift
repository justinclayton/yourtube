import SwiftUI

struct RootView: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        TabView {
            SubscriptionsView()
                .tabItem { Label("Subscriptions", systemImage: "play.square.stack") }

            ChannelsView()
                .tabItem { Label("Channels", systemImage: "person.2") }

            WatchLaterView()
                .tabItem { Label("Watch Later", systemImage: "clock") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
        }
        .task {
            services.categories.seedDefaultCategoriesIfNeeded()
            // Attempt a silent token refresh on launch so a still-valid session
            // goes straight to the feed without a sign-in prompt.
            _ = try? await services.auth.validAccessToken()
            services.categories.classifyUnassignedInBackground()
        }
        .onChange(of: services.feed.lastRefreshedAt) {
            // New subscriptions arrive via refresh; file them as they appear.
            services.categories.classifyUnassignedInBackground()
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
