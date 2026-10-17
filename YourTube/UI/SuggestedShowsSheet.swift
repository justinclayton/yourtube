import SwiftUI

/// The Pick grid: the Your Shows poster grid before it's yours. Every pending
/// suggestion is a poster, nothing is ticked, and one button adds the ticked
/// and sets the rest aside. See `ShowSuggestions`.
///
/// The reasons are behind a long-press rather than on the poster, so the grid
/// is judged the way the shelf will look: by the channel's art and name. Done
/// closes without deciding anything; only the button sets anything aside.
///
/// The suggestions are read once, when the sheet opens. A detector pass that
/// withdraws one while the sheet is up just means the button skips it.
struct SuggestedShowsSheet: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss

    @State private var suggestions: [PendingSuggestion]?
    @State private var ticked: Set<String> = []
    @State private var inspecting: PendingSuggestion?
    @State private var outcome: Outcome?
    @State private var error: String?

    /// What the button did, for the end state.
    struct Outcome {
        var added: [String]
        var setAside: Int
    }

    var body: some View {
        NavigationStack {
            Group {
                if let outcome {
                    EndState(outcome: outcome)
                } else if let suggestions {
                    if suggestions.isEmpty {
                        ContentUnavailableView(
                            "Nothing to pick",
                            systemImage: "tv",
                            description: Text("No channels look like shows right now.")
                        )
                    } else {
                        pick(suggestions)
                    }
                } else {
                    Color.clear
                }
            }
            .navigationTitle("Suggested Shows")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            suggestions = (try? services.suggestions.pending()) ?? []
        }
    }

    // MARK: - The grid

    private func pick(_ suggestions: [PendingSuggestion]) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(Self.intro)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3),
                        alignment: .leading,
                        spacing: 18
                    ) {
                        ForEach(suggestions) { suggestion in
                            SuggestionPoster(suggestion: suggestion, isTicked: ticked.contains(suggestion.id))
                                .frame(maxHeight: .infinity, alignment: .top)
                                .contentShape(Rectangle())
                                .onTapGesture { toggle(suggestion) }
                                .onLongPressGesture { inspecting = suggestion }
                                .accessibilityAddTraits(ticked.contains(suggestion.id) ? [.isButton, .isSelected] : .isButton)
                                .accessibilityAction(named: "Why it's here") { inspecting = suggestion }
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 16)
            }
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }
            Button {
                finish(suggestions)
            } label: {
                Text(Self.buttonTitle(ticked: ticked.count))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .sheet(item: $inspecting) { suggestion in
            SuggestionReasons(suggestion: suggestion)
        }
    }

    private func toggle(_ suggestion: PendingSuggestion) {
        if ticked.contains(suggestion.id) {
            ticked.remove(suggestion.id)
        } else {
            ticked.insert(suggestion.id)
        }
    }

    private func finish(_ suggestions: [PendingSuggestion]) {
        let accepted = suggestions.filter { ticked.contains($0.id) }
        let setAside = suggestions.filter { !ticked.contains($0.id) }
        do {
            try services.suggestions.resolve(
                accepting: accepted.map(\.channelId),
                settingAside: setAside.map(\.channelId)
            )
            outcome = Outcome(added: accepted.map(\.title), setAside: setAside.count)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Wording

    static let intro = "These channels might be good candidates to add to the Shows tab. Tap and hold on one of the channels below to understand how we make these recommendations"

    static func buttonTitle(ticked: Int) -> String {
        switch ticked {
        case 0: "None of these"
        case 1: "Add 1 show"
        default: "Add \(ticked) shows"
        }
    }
}

/// A Your Shows poster, tickable: the accent border and a filled check say
/// it's picked. The engagement line sits under the name only when there's
/// something to say.
private struct SuggestionPoster: View {
    let suggestion: PendingSuggestion
    let isTicked: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ChannelArt(url: suggestion.avatarURL, title: suggestion.title, seed: suggestion.channelId)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(isTicked ? Color.accentColor : .clear, lineWidth: 3)
                }
                .overlay(alignment: .topTrailing) {
                    Image(systemName: isTicked ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .symbolRenderingMode(isTicked ? .multicolor : .monochrome)
                        .foregroundStyle(isTicked ? Color.accentColor : .white)
                        .shadow(radius: 2)
                        .padding(6)
                }
            Text(suggestion.title)
                .font(.caption.weight(isTicked ? .semibold : .medium))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let line = suggestion.engagement.line {
                Text(line)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Why the detector put a channel in the grid, in its own sentences.
private struct SuggestionReasons: View {
    let suggestion: PendingSuggestion

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(suggestion.title)
                .font(.title3.weight(.semibold))
            if let line = suggestion.engagement.line {
                Text(line).font(.subheadline)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(suggestion.reasons, id: \.self) { reason in
                    Label(reason, systemImage: "checkmark.circle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .presentationDetents([.medium])
    }
}

/// After the button: what was added and how many were set aside.
private struct EndState: View {
    let outcome: SuggestedShowsSheet.Outcome

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(outcome.added.isEmpty ? "Nothing added" : "Your Shows is set")
                .font(.title3.weight(.semibold))
            if !outcome.added.isEmpty {
                Text("Added " + outcome.added.formatted(.list(type: .and)))
                    .font(.footnote)
                    .multilineTextAlignment(.center)
            }
            if outcome.setAside > 0 {
                Text(outcome.setAside == 1 ? "1 channel set aside" : "\(outcome.setAside) channels set aside")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
