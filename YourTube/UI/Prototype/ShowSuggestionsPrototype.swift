#if DEBUG
import SwiftUI
import SwiftData

// PROTOTYPE — throwaway. Three variants of a "suggested shows" sheet, opened
// from a DEBUG-only sparkles button on the Shows tab. Flip variants from the
// floating bar at the bottom of the sheet; the ranking menu there changes
// what comes first. Accept/dismiss are in-memory stubs and never touch the
// store, so nothing here changes Your Shows.
//
// Question: when the detector stops flagging shows itself and only
// recommends, what should the recommendation surface look like, and does
// ranking by your own watching put the right channels first?
//
// VERDICT (2026-10-16): C "Pick" wins, driven against the real store on the
// YourTube 1 simulator (46 candidates). The Your Shows poster grid is the
// surface: art first, tap to tick, reasons behind a long-press, one button
// that adds the ticked and sets the rest aside. A was judged too wordy per
// row at this volume; B too long to finish at 46. Decided on this basis:
//
//   - The detector stops creating Show rows. It only produces candidates;
//     every Show is added by the user.
//   - Candidates are presented as the Pick grid: a finite set, nothing
//     pre-ticked, unticked = set aside permanently (the existing
//     forceNotShow override), nothing re-surfaces.
//   - Existing heuristic-origin shows become the first batch of candidates
//     on upgrade rather than being deleted.
//   - Ranking by own engagement (watched / earmarked / started) was not
//     testable on the simulator store, which holds almost no watch history;
//     verify on the phone before deciding the default order.
//   - Playlist-backed shows stay manual; detection is channel-level.
//
//   A  Inbox  — a finite list, one row per channel, reasons under the name,
//               accept/dismiss per row, "that's everyone" at the end
//   B  Deck   — one channel at a time, full-width art, reasons as a list,
//               two big buttons, a progress line to the end
//   C  Pick   — the Your Shows poster grid; tick what you follow, the rest
//               are set aside when you're done

let protoSuggestionVariants: [(key: String, name: String)] = [
    ("A", "Inbox"), ("B", "Deck"), ("C", "Pick"),
]

/// One channel the detector would recommend, plus what you've done with it.
struct ProtoSuggestion: Identifiable, Hashable {
    let channelId: String
    let title: String
    let avatarURL: String?
    /// The detector's own sentences, strongest first.
    let reasons: [String]
    let watched: Int
    let earmarked: Int
    let started: Int
    let total: Int
    /// Flagged by today's detector: what the upgrade would hand back as a
    /// suggestion rather than keep as a show.
    let currentlyAutoFlagged: Bool

    var id: String { channelId }
    var engagement: Int { watched + earmarked + started }

    var engagementLine: String {
        var parts: [String] = []
        if watched > 0 { parts.append("watched \(watched) of \(total)") }
        if started > 0 { parts.append("\(started) partway") }
        if earmarked > 0 { parts.append("\(earmarked) in Up Next") }
        if parts.isEmpty { return "Nothing watched yet, \(total) uploads stored" }
        return "You've " + parts.joined(separator: ", ")
    }
}

enum ProtoRanking: String, CaseIterable, Identifiable {
    case engagement = "What you watch"
    case signals = "Detector confidence"
    case name = "Name"
    var id: String { rawValue }
}

@Observable
@MainActor
final class ProtoSuggestionsStore {
    var all: [ProtoSuggestion] = []
    var accepted: Set<String> = []
    var dismissed: Set<String> = []
    /// The deck's "decide later": sent to the back, in the order skipped.
    var skippedOrder: [String] = []
    var ranking: ProtoRanking = .engagement
    var isLoaded = false
    var subscriptionCount = 0

    var ranked: [ProtoSuggestion] {
        switch ranking {
        case .engagement:
            all.sorted {
                ($0.engagement, $0.reasons.count, $1.title) > ($1.engagement, $1.reasons.count, $0.title)
            }
        case .signals:
            all.sorted {
                ($0.reasons.count, $0.engagement, $1.title) > ($1.reasons.count, $1.engagement, $0.title)
            }
        case .name:
            all.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
    }

    /// Still waiting on an answer, in rank order.
    var pending: [ProtoSuggestion] {
        ranked.filter { !accepted.contains($0.id) && !dismissed.contains($0.id) }
    }

    /// The deck's order: pending minus skips, then the skips in the order
    /// they were put off.
    var deck: [ProtoSuggestion] {
        let pending = pending
        let skipped = Set(skippedOrder)
        let fresh = pending.filter { !skipped.contains($0.id) }
        let later = skippedOrder.compactMap { id in pending.first { $0.id == id } }
        return fresh + later
    }

    func accept(_ s: ProtoSuggestion) { accepted.insert(s.id); dismissed.remove(s.id) }
    func dismiss(_ s: ProtoSuggestion) { dismissed.insert(s.id); accepted.remove(s.id) }
    func undo(_ s: ProtoSuggestion) { accepted.remove(s.id); dismissed.remove(s.id) }
    func skip(_ s: ProtoSuggestion) {
        skippedOrder.removeAll { $0 == s.id }
        skippedOrder.append(s.id)
    }
    func reset() { accepted = []; dismissed = []; skippedOrder = [] }

    /// Runs the real detector over every subscription the user hasn't
    /// decided on, ignoring the runner's fingerprints, and joins the verdict
    /// with the stored watch state. Main context on purpose: a prototype.
    func load(context: ModelContext) {
        guard !isLoaded else { return }
        let subs = (try? context.fetch(FetchDescriptor<Subscription>())) ?? []
        let videos = (try? context.fetch(FetchDescriptor<Video>())) ?? []
        let byChannel = Dictionary(grouping: videos, by: \.channelId)
        let shows = ((try? context.fetch(FetchDescriptor<Show>())) ?? []).filter { !$0.isPlaylistBacked }
        let decided = Set(shows.filter { $0.override != .none || $0.flagOrigin == .user }.map(\.channelId))
        let autoFlagged = Set(shows.filter { $0.override == .none && $0.flagOrigin == .heuristic && $0.isActive }
            .map(\.channelId))

        var found: [ProtoSuggestion] = []
        for sub in subs where !decided.contains(sub.channelId) {
            let vids = byChannel[sub.channelId] ?? []
            let verdict = ShowDetector.verdict(for: ChannelEvidence(
                channelId: sub.channelId,
                channelTitle: sub.title,
                videos: vids.map(ShowDetectionRunner.signals(for:))
            ))
            guard verdict.isShow else { continue }
            found.append(ProtoSuggestion(
                channelId: sub.channelId,
                title: sub.title,
                avatarURL: sub.thumbnailURL,
                reasons: verdict.reasons,
                watched: vids.filter(\.isWatched).count,
                earmarked: vids.filter { $0.savedForLaterAt != nil }.count,
                started: vids.filter { $0.resumePositionSeconds != nil && !$0.isWatched }.count,
                total: vids.count,
                currentlyAutoFlagged: autoFlagged.contains(sub.channelId)
            ))
        }
        all = found
        subscriptionCount = subs.count
        isLoaded = true
    }
}

// MARK: - Sheet root

struct ShowSuggestionsPrototype: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @AppStorage("prototype.suggestionsVariant") private var variant = "A"
    @State private var store = ProtoSuggestionsStore()

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Group {
                    if !store.isLoaded {
                        ProgressView("Looking at your subscriptions…")
                    } else {
                        switch variant {
                        case "B": ProtoDeckVariant(store: store)
                        case "C": ProtoPickVariant(store: store)
                        default: ProtoInboxVariant(store: store)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                ProtoSwitcherBar(variant: $variant, store: store)
                    .padding(.bottom, 8)
            }
            .navigationTitle("Suggested Shows")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { store.load(context: modelContext) }
    }
}

/// The floating bar: previous / label / next, and a menu for the ranking and
/// a reset. Styled to look like no part of the app, so it can't be mistaken
/// for the design under review.
struct ProtoSwitcherBar: View {
    @Binding var variant: String
    @Bindable var store: ProtoSuggestionsStore

    private var index: Int { protoSuggestionVariants.firstIndex { $0.key == variant } ?? 0 }

    var body: some View {
        HStack(spacing: 14) {
            Button { step(-1) } label: { Image(systemName: "chevron.left") }
            VStack(spacing: 1) {
                Text("\(protoSuggestionVariants[index].key) · \(protoSuggestionVariants[index].name)")
                    .font(.subheadline.weight(.semibold))
                Text("\(store.pending.count) left · \(store.accepted.count) added · \(store.dismissed.count) set aside")
                    .font(.caption2)
                    .opacity(0.7)
            }
            Button { step(1) } label: { Image(systemName: "chevron.right") }
            Menu {
                Picker("Rank by", selection: $store.ranking) {
                    ForEach(ProtoRanking.allCases) { Text($0.rawValue).tag($0) }
                }
                Button("Reset decisions", systemImage: "arrow.counterclockwise") { store.reset() }
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
        }
        .font(.body.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.black.opacity(0.88), in: Capsule())
        .shadow(radius: 8, y: 4)
    }

    private func step(_ by: Int) {
        let n = protoSuggestionVariants.count
        variant = protoSuggestionVariants[(index + by + n) % n].key
    }
}

// MARK: - Shared bits

private struct ProtoReasonList: View {
    let reasons: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(reasons, id: \.self) { reason in
                Label(reason, systemImage: "checkmark.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ProtoEndState: View {
    @Bindable var store: ProtoSuggestionsStore
    let headline: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(headline)
                .font(.title3.weight(.semibold))
            Text("Added \(store.accepted.count) · Set aside \(store.dismissed.count) · \(store.subscriptionCount) subscriptions looked at")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if !store.accepted.isEmpty {
                Text(store.ranked.filter { store.accepted.contains($0.id) }.map(\.title).joined(separator: ", "))
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }
}

private struct ProtoAutoFlagTag: View {
    var body: some View {
        Text("in Your Shows today")
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.orange.opacity(0.18), in: Capsule())
            .foregroundStyle(.orange)
    }
}

// MARK: - A: Inbox

/// A finite list you reach the end of. Each row carries the name, the
/// detector's reasons, what you've watched, and the two answers.
struct ProtoInboxVariant: View {
    @Bindable var store: ProtoSuggestionsStore

    var body: some View {
        List {
            if store.pending.isEmpty {
                ProtoEndState(store: store, headline: "That's everyone.")
                    .listRowSeparator(.hidden)
            } else {
                Section {
                    ForEach(store.pending) { s in
                        row(s)
                            .swipeActions(edge: .leading) {
                                Button { store.accept(s) } label: { Label("Add", systemImage: "tv") }
                                    .tint(.green)
                            }
                            .swipeActions(edge: .trailing) {
                                Button { store.dismiss(s) } label: { Label("Not a show", systemImage: "xmark") }
                            }
                    }
                } header: {
                    Text("\(store.pending.count) channels look like shows. Add the ones you follow; the rest stay channels.")
                        .textCase(nil)
                        .font(.footnote)
                }
            }
            decided("Added", ids: store.accepted, icon: "tv")
            decided("Not shows", ids: store.dismissed, icon: "xmark")
            Color.clear.frame(height: 60).listRowSeparator(.hidden)
        }
        .listStyle(.plain)
    }

    private func row(_ s: ProtoSuggestion) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ChannelArt(url: s.avatarURL, title: s.title, seed: s.channelId)
                .frame(width: 60, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(s.title).font(.headline)
                    if s.currentlyAutoFlagged { ProtoAutoFlagTag() }
                }
                Text(s.reasons.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(s.engagementLine)
                    .font(.caption)
                    .foregroundStyle(s.engagement > 0 ? .primary : .secondary)
                HStack(spacing: 10) {
                    Button { store.accept(s) } label: {
                        Label("Add as show", systemImage: "tv")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    Button("Not a show") { store.dismiss(s) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func decided(_ title: String, ids: Set<String>, icon: String) -> some View {
        let items = store.ranked.filter { ids.contains($0.id) }
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { s in
                    HStack {
                        Image(systemName: icon).foregroundStyle(.secondary)
                        Text(s.title)
                        Spacer()
                        Button("Undo") { store.undo(s) }
                            .font(.subheadline)
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
    }
}

// MARK: - B: Deck

/// One channel at a time. Art first, then the case for it, then a decision.
struct ProtoDeckVariant: View {
    @Bindable var store: ProtoSuggestionsStore

    var body: some View {
        let deck = store.deck
        let total = store.all.count
        VStack(spacing: 0) {
            if let current = deck.first {
                VStack(spacing: 4) {
                    ProgressView(value: Double(total - deck.count), total: Double(max(total, 1)))
                    Text("\(total - deck.count + 1) of \(total)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .padding(.top, 8)

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ChannelArt(url: current.avatarURL, title: current.title, seed: current.channelId)
                            .aspectRatio(1, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                            .padding(.horizontal, 40)
                        HStack {
                            Text(current.title)
                                .font(.title2.weight(.bold))
                            if current.currentlyAutoFlagged { ProtoAutoFlagTag() }
                        }
                        Text(current.engagementLine)
                            .font(.subheadline)
                        Text("Why it looks like a show")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                        ProtoReasonList(reasons: current.reasons)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .id(current.id)

                VStack(spacing: 10) {
                    HStack(spacing: 12) {
                        Button {
                            withAnimation { store.dismiss(current) }
                        } label: {
                            Text("Not a show").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        Button {
                            withAnimation { store.accept(current) }
                        } label: {
                            Label("Add as show", systemImage: "tv").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                    Button("Decide later") { withAnimation { store.skip(current) } }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 72)
            } else {
                Spacer()
                ProtoEndState(store: store, headline: "No more to decide.")
                Spacer()
            }
        }
    }
}

// MARK: - C: Pick

/// The Your Shows grid, before it's yours: every candidate as a poster, tap
/// to tick. Reasons are behind the poster, not in front of it. Finishing
/// sets aside whatever you didn't tick.
struct ProtoPickVariant: View {
    @Bindable var store: ProtoSuggestionsStore
    @State private var inspecting: ProtoSuggestion?
    @State private var finished = false

    private var candidates: [ProtoSuggestion] {
        store.ranked.filter { !store.dismissed.contains($0.id) }
    }

    var body: some View {
        if finished || candidates.isEmpty {
            ProtoEndState(store: store, headline: "Your Shows is set.")
                .frame(maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("\(candidates.count) channels look like shows. Tap the ones you follow; the rest stay channels. Hold a poster to see why it's here.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3),
                            alignment: .leading,
                            spacing: 18
                        ) {
                            ForEach(candidates) { s in
                                tile(s)
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 12)
                    .padding(.bottom, 16)
                }
                Button {
                    for s in candidates where !store.accepted.contains(s.id) { store.dismiss(s) }
                    finished = true
                } label: {
                    Text(store.accepted.isEmpty ? "None of these" : "Add \(store.accepted.count) \(store.accepted.count == 1 ? "show" : "shows")")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, 20)
                .padding(.bottom, 72)
            }
            .sheet(item: $inspecting) { s in
                VStack(alignment: .leading, spacing: 14) {
                    Text(s.title).font(.title3.weight(.semibold))
                    Text(s.engagementLine).font(.subheadline)
                    ProtoReasonList(reasons: s.reasons)
                    Spacer()
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .presentationDetents([.medium])
            }
        }
    }

    private func tile(_ s: ProtoSuggestion) -> some View {
        let picked = store.accepted.contains(s.id)
        return VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                ChannelArt(url: s.avatarURL, title: s.title, seed: s.channelId)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(picked ? Color.accentColor : .clear, lineWidth: 3)
                    )
                    .opacity(picked ? 1 : 0.8)
                Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(picked ? Color.accentColor : .white)
                    .shadow(radius: 2)
                    .padding(6)
            }
            Text(s.title)
                .font(.caption.weight(picked ? .semibold : .regular))
                .fixedSize(horizontal: false, vertical: true)
            if s.engagement > 0 {
                Text(s.engagementLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.snappy) { picked ? store.undo(s) : store.accept(s) }
        }
        .onLongPressGesture { inspecting = s }
    }
}
#endif
