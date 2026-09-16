import SwiftUI
import SwiftData

enum SettingsKeys {
    static let showShorts = "settings.showShorts"
    /// Name of the category the feed is filtered to; empty = all.
    static let feedCategory = "settings.feedCategory"
    /// Name of the category the Your Shows grid is filtered to; empty = all.
    /// Remembered separately from the feed's chip so the two surfaces don't
    /// drag each other around.
    static let showsCategory = "settings.showsCategory"
    /// Name of the category Channels is filtered to; empty = all. Remembered
    /// separately from the feed's and Your Shows' chips, like those two are
    /// from each other.
    static let channelsCategory = "settings.channelsCategory"
    /// Max videos per channel per day before the rest fold into "+N more"; 0 = off.
    static let channelDailyCap = "settings.channelDailyCap"
    static let defaultChannelDailyCap = 2
    /// Whether Channels shows the grouped list or the avatar grid. See
    /// `ChannelsPresentation`.
    static let channelsPresentation = "settings.channelsPresentation"
}

struct SettingsView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.modelContext) private var modelContext
    @AppStorage(SettingsKeys.showShorts) private var showShorts = false
    @AppStorage(SettingsKeys.channelDailyCap) private var channelDailyCap = SettingsKeys.defaultChannelDailyCap
    @AppStorage(TitleCleaner.rewriteEnabledKey) private var rewriteTitles = true

    /// Counted on demand rather than held as a live query: three numbers
    /// aren't worth keeping every video in the store in a tab's memory, let
    /// alone re-reading them on every save from whichever tab is showing.
    /// See `StoreCounts` and issue #66.
    @State private var counts = LibraryCounts()

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
                    Stepper(value: $channelDailyCap, in: 0...10) {
                        LabeledContent(
                            "Per-channel daily cap",
                            value: channelDailyCap == 0 ? "Off" : "\(channelDailyCap)"
                        )
                    }
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

                    The daily cap folds a channel's extra uploads on a given day \
                    into a single "+N more" row so one prolific channel can't \
                    crowd out the rest.
                    """)
                }

                titlesSection

                Section("Library") {
                    LabeledContent("Subscriptions", value: "\(counts.subscriptions)")
                    LabeledContent("Videos", value: "\(counts.videos)")
                    LabeledContent("Filtered as Shorts", value: "\(counts.shorts)")
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
                    \(max(1, counts.subscriptions + 4)) units.
                    """)
                }
            }
            .navigationTitle("Settings")
            .recomputingFromStore(id: 0) {
                counts = (try? StoreCounts.library(in: modelContext)) ?? counts
            }
        }
    }

    /// Tier two of title cleaning. Stripping has no switch — it's
    /// deterministic and works everywhere — so this section is about the
    /// model rewrite alone, and says so when the device can't run it.
    private var titlesSection: some View {
        Section {
            Toggle("Rewrite show titles", isOn: $rewriteTitles)
                .disabled(!services.titles.canRewrite)
                .onChange(of: rewriteTitles) {
                    services.titles.applyRewriteSettingInBackground()
                }

            if !services.titles.canRewrite {
                Label(
                    TitleRewriterFactory.systemModelUnavailableReason()
                        ?? "The on-device model isn't available.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if case .running(let done, let total) = services.titles.rewriteStatus {
                ProgressView(value: Double(done), total: Double(max(1, total))) {
                    Text("Rewriting titles \(done)/\(total)").monospacedDigit()
                }
            }
            if services.titles.lastRewriteFailures > 0 {
                LabeledContent(
                    "Skipped by the model last run",
                    value: "\(services.titles.lastRewriteFailures)"
                )
                .foregroundStyle(.secondary)
            }
        } header: {
            Text("Titles")
        } footer: {
            Text("""
            Every title has the channel's repeated boilerplate stripped — the \
            show name after a pipe, "FULL EPISODE", episode numbers — and that \
            happens on every device with no model involved.

            On top of that, episodes of your shows are rewritten on-device by \
            Apple's language model into calm, factual titles, with nothing \
            added that the original didn't say. Nothing leaves the phone. Turn \
            this off to keep the stripping and lose the rewrite; turning it \
            back on rewrites them again. The original title is always under \
            the cleaned one in the player.
            """)
        }
    }
}
