import SwiftUI
import SwiftData

/// "Add playlist as show": pick one of a channel's playlists, or several, and
/// it becomes a show of its own.
///
/// One playlist is the common case — a podcast hosted on a network channel is
/// its own show, and the playlist is the show. Several playlists chosen at
/// once become one show with seasons, in the order they were picked, which is
/// how a series-based show with a playlist per series becomes one thing in
/// Your Shows with a picker on its page.
///
/// The sheet asks YouTube for the channel's playlists the moment it opens and
/// at no other time: this is the only routine way the app spends a unit on
/// `playlists.list`, and the feed's refresh never does. Signed out, the fetch
/// fails and the sheet says so rather than showing an empty list, which is
/// also what a fixture run sees.
struct PlaylistShowPicker: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss

    let subscription: Subscription

    @State private var playlists: [YT.Playlist] = []
    /// Playlist IDs in the order they were tapped: that order is the season
    /// order, so a series-based show browses forwards.
    @State private var chosen: [String] = []
    @State private var title = ""
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var saveError: String?
    @State private var isSaving = false
    /// Playlists already spoken for by a show, so the same one isn't added
    /// twice by accident.
    @State private var alreadyShows: Set<String> = []

    private var choices: [PlaylistChoice] {
        chosen.compactMap { id in
            playlists.first { $0.id == id }.map(PlaylistChoice.init)
        }
    }

    /// The name the show gets: whatever the user typed, else the first
    /// playlist's title.
    private var resolvedTitle: String {
        let typed = title.trimmingCharacters(in: .whitespaces)
        return typed.isEmpty ? (choices.first?.title ?? "") : typed
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Add playlist as show")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add") { add() }
                            .disabled(chosen.isEmpty || isSaving)
                    }
                }
                .task { await load() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView("Loading playlists")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError {
            ContentUnavailableView {
                Label("Couldn't list playlists", systemImage: "list.bullet.rectangle")
            } description: {
                Text(services.auth.needsReauth
                     ? "Sign in on the Feed tab to browse \(subscription.title)'s playlists. A playlist-backed show is the only thing in the app that has to ask YouTube for a list, and it can't ask signed out."
                     : loadError)
            }
        } else if playlists.isEmpty {
            ContentUnavailableView(
                "No playlists",
                systemImage: "list.bullet.rectangle",
                description: Text("\(subscription.title) publishes no playlists, so there's nothing here to make a show of.")
            )
        } else {
            form
        }
    }

    private var form: some View {
        List {
            Section {
                ForEach(playlists, id: \.id) { playlist in
                    row(playlist)
                }
            } header: {
                Text("\(subscription.title)'s playlists")
            } footer: {
                Text("Pick one playlist to make it a show. Pick several and they become one show with a season each, in the order you tap them.")
            }
            if !chosen.isEmpty {
                Section {
                    TextField("Show name", text: $title, prompt: Text(choices.first?.title ?? ""))
                    if chosen.count > 1 {
                        ForEach(Array(choices.enumerated()), id: \.offset) { index, choice in
                            LabeledContent("Season \(index + 1)", value: choice.title)
                        }
                    }
                } header: {
                    Text(chosen.count > 1 ? "The show and its seasons" : "The show")
                } footer: {
                    Text("It inherits \(subscription.title)'s categories and Priority tag, so there's nothing to file twice.")
                }
            }
            if let saveError {
                Text(saveError).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func row(_ playlist: YT.Playlist) -> some View {
        let index = chosen.firstIndex(of: playlist.id)
        let taken = alreadyShows.contains(playlist.id)
        return Button {
            toggle(playlist.id)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(playlist.title)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                    Text(taken
                         ? "\(playlist.itemCount) videos · already a show"
                         : "\(playlist.itemCount) videos")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let index {
                    // The number, not a tick: with several playlists picked
                    // the order is the season order and has to be visible.
                    Text(chosen.count > 1 ? "\(index + 1)" : "✓")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(.tint)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func toggle(_ id: String) {
        if let index = chosen.firstIndex(of: id) {
            chosen.remove(at: index)
        } else {
            chosen.append(id)
        }
    }

    private func load() async {
        guard isLoading else { return }
        defer { isLoading = false }
        alreadyShows = Set(
            ((try? services.shows.playlistShows(forChannelId: subscription.channelId)) ?? [])
                .flatMap(\.backingPlaylistIds)
        )
        do {
            playlists = try await services.api.playlists(channelId: subscription.channelId)
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func add() {
        isSaving = true
        saveError = nil
        do {
            let show = try services.shows.addPlaylistShow(
                choices,
                channelId: subscription.channelId,
                title: resolvedTitle
            )
            // The show exists with an empty membership until the playlist is
            // walked; do that now so it isn't an empty poster in the grid.
            Task {
                _ = try? await services.feed.refreshMembership(of: show, using: services.shows)
            }
            dismiss()
        } catch {
            saveError = error.localizedDescription
            isSaving = false
        }
    }
}
