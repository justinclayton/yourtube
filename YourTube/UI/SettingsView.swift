import SwiftUI
import SwiftData

enum SettingsKeys {
    static let showShorts = "settings.showShorts"
    /// Name of the category the Subscriptions feed is filtered to; empty = all.
    static let feedCategory = "settings.feedCategory"
}

struct SettingsView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.modelContext) private var modelContext
    @AppStorage(SettingsKeys.showShorts) private var showShorts = false

    @Query private var subscriptions: [Subscription]
    @Query private var videos: [Video]

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    switch services.auth.state {
                    case .signedIn:
                        Label("Signed in", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Button("Sign out", role: .destructive) {
                            Task { await services.auth.signOut() }
                        }
                    case .signedOut, .expired:
                        let title = services.auth.state == .expired
                            ? "Sign in again" : "Sign in with Google"
                        Button(title) {
                            Task { await services.auth.signIn() }
                        }
                        .disabled(services.auth.isWorking)
                    }

                    if let error = services.auth.lastError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Toggle("Show Shorts", isOn: $showShorts)
                    NavigationLink("Categories") {
                        CategoriesSettingsView()
                    }
                } header: {
                    Text("Feed")
                } footer: {
                    Text("""
                    Shorts are detected heuristically — YouTube's API has no \
                    flag for them. A video of 3 minutes or less is treated as one \
                    if it's tagged #shorts or its thumbnail shows vertical video. \
                    Turn this on if \
                    something you wanted got filtered out.
                    """)
                }

                Section("Library") {
                    LabeledContent("Subscriptions", value: "\(subscriptions.count)")
                    LabeledContent("Videos", value: "\(videos.count)")
                    LabeledContent("Filtered as Shorts", value: "\(shortsCount)")
                    if let last = services.feed.lastRefreshedAt {
                        LabeledContent("Last refresh") {
                            Text(last, format: .relative(presentation: .named))
                        }
                    }
                }

                Section {
                    LabeledContent("Used today") {
                        Text("\(services.quota.unitsUsedToday) / \(QuotaTracker.dailyLimit)")
                            .monospacedDigit()
                    }
                    ProgressView(
                        value: Double(services.quota.unitsUsedToday),
                        total: Double(QuotaTracker.dailyLimit)
                    )
                } header: {
                    Text("API Quota")
                } footer: {
                    Text("""
                    Resets at midnight US Pacific. A full refresh costs about \
                    \(max(1, subscriptions.count + 4)) units.
                    """)
                }
            }
            .navigationTitle("Settings")
        }
    }

    private var shortsCount: Int {
        videos.filter { $0.isLikelyShort }.count
    }
}
