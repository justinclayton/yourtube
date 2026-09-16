import SwiftUI

struct VideoRow: View {
    let video: Video
    /// Overrides the title text shown for this row without touching
    /// `video.displayTitle` itself. Feed rows pass their latched title here
    /// (see `FeedVideoRow`); every other caller leaves this nil and gets
    /// `video.displayTitle` live, as before. See issue #68.
    var displayTitleOverride: String? = nil

    private var title: String { displayTitleOverride ?? video.displayTitle }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 4) {
                // Cleaned, with the channel's boilerplate stripped; the raw
                // title is a tap away in the player. See `TitleCleaner`.
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(video.isWatched ? .secondary : .primary)
                Text(video.channelTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    EpisodeBadge(video: video)
                    Text(video.publishedAt, format: .relative(presentation: .named))
                    if video.isInUpNext {
                        Image(systemName: "bookmark.fill")
                    }
                    if video.isWatched {
                        Image(systemName: "checkmark.circle.fill")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private var thumbnail: some View {
        ZStack(alignment: .bottomTrailing) {
            CachedAsyncImage(
                url: video.thumbnailURL.flatMap(URL.init(string:)),
                size: CGSize(width: 120, height: 68)
            ) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle().fill(.quaternary)
            }
            .frame(width: 120, height: 68)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Text(video.formattedDuration)
                .font(.caption2.monospacedDigit())
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 3))
                .foregroundStyle(.white)
                .padding(4)
        }
    }
}
