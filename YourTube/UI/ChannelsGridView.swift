import SwiftUI
import SwiftData

/// Channels as a browsing surface rather than a management one: a grid of
/// square channel avatars with the full name wrapped beneath, grouped by
/// category exactly like `ChannelList`'s rows — same sections, same
/// collapse state, same Priority-first ordering — so switching the toolbar
/// toggle changes only the shape of the tiles, never what's in them.
///
/// Tapping a tile opens the same channel page as the list row; long-press
/// offers the same menu (`ChannelRowMenu`). See `ChannelTile` for how a
/// show is distinguished from a plain channel, mirroring `ChannelRow`.
struct ChannelsGridView: View {
    let groups: [ChannelGroup]
    let unwatchedByChannel: [String: Int]
    let showChannelIds: Set<String>
    let priorityChannelIds: Set<String>
    let showShorts: Bool
    @Binding var collapsed: Set<String>
    let onFile: (Subscription) -> Void
    let onError: (String) -> Void

    @Environment(AppServices.self) private var services

    private let columns = [GridItem(.adaptive(minimum: 84, maximum: 110), spacing: 16, alignment: .top)]

    // Deliberately a plain ScrollView/LazyVStack, not a List: a List row is
    // one hit-test target for the whole row, so a List Section holding a
    // multi-item LazyVGrid mis-routes taps between the NavigationLinks
    // packed into it. YourShowsSection's poster grid sidesteps the same
    // trap the same way.
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 12) {
                        GroupHeader(
                            title: group.title,
                            channelCount: group.channels.count,
                            unwatched: group.unwatched,
                            isCollapsed: collapsed.contains(group.id)
                        ) {
                            withAnimation(.snappy) {
                                if collapsed.contains(group.id) {
                                    collapsed.remove(group.id)
                                } else {
                                    collapsed.insert(group.id)
                                }
                            }
                        }
                        if !collapsed.contains(group.id) {
                            LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                                // A channel can appear in several groups, so
                                // the tile identity has to include the
                                // group, same as the list row.
                                ForEach(group.channels, id: \.channelId) { subscription in
                                    NavigationLink {
                                        ChannelView(subscription: subscription, showShorts: showShorts)
                                    } label: {
                                        ChannelTile(
                                            subscription: subscription,
                                            unwatchedCount: unwatchedByChannel[subscription.channelId] ?? 0,
                                            isShow: showChannelIds.contains(subscription.channelId)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        ChannelRowMenu(
                                            subscription: subscription,
                                            isPriority: priorityChannelIds.contains(subscription.channelId),
                                            isShow: showChannelIds.contains(subscription.channelId),
                                            services: services,
                                            onFile: { onFile(subscription) },
                                            onError: onError
                                        ).contextMenuContent
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .padding(.vertical, 12)
        }
    }
}

/// One tile in the Channels grid: the square avatar with monogram fallback
/// (`ChannelArt`, the same art `ShowPoster` uses), the channel's full name
/// wrapped beneath — never truncated — an unwatched badge, and a small "tv"
/// glyph over the art for shows. The glyph is the grid's version of
/// `ChannelRow`'s trailing icon: the same show/not-show split, just drawn to
/// fit a square tile instead of a row.
struct ChannelTile: View {
    let subscription: Subscription
    let unwatchedCount: Int
    let isShow: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ChannelArt(url: subscription.thumbnailURL, title: subscription.title, seed: subscription.channelId)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if isShow { showGlyph }
                }
                .overlay(alignment: .topTrailing) {
                    if unwatchedCount > 0 { badge }
                }
            Text(subscription.title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// No badge at all at zero: a caught-up channel should look calm, same
    /// rule as `ShowPoster`.
    private var badge: some View {
        Text("\(unwatchedCount)")
            .font(.caption2.weight(.bold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.tint, in: Capsule())
            .padding(5)
    }

    private var showGlyph: some View {
        Image(systemName: "tv.fill")
            .font(.caption2)
            .foregroundStyle(.white)
            .padding(5)
            .background(.black.opacity(0.35), in: Circle())
            .padding(5)
            .accessibilityLabel("Show")
    }
}
