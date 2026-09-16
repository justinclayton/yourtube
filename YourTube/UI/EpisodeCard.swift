import SwiftUI
import SwiftData

/// The one card shape for episodes: art on top, the channel (or show) name
/// as a caption, the full title free to wrap, then duration and date.
/// Continue Watching and Up Next both use it, so the Shows tab reads as a
/// single calm column. Show posters never use this shape, so a show and a
/// single video can't be confused.
///
/// Sizing is adaptive at the section level: a section with one item shows a
/// `.large` card at full width, two or more become a two-column grid of
/// `.medium` cards. Nothing scrolls sideways and no title is truncated.
struct EpisodeCard: View {
    enum Size { case large, medium }

    let video: Video
    /// The channel's avatar, which is the art ("channel fill"): YouTube's
    /// thumbnails are the loud part of its presentation, and the avatar is
    /// what makes a show recognisable at a glance.
    let avatarURL: String?
    let size: Size
    /// How far through the video is, 0...1, when it's one you're partway
    /// into. Nil (the usual case) leaves the card exactly as it was: no bar
    /// over the art, and duration rather than time left. See `PlaybackProgress`.
    var progress: Double?

    /// The show `video` belongs to, or nil when it's in no show. Both the
    /// caption and the art preference below come from this instead of the
    /// channel, so a playlist-backed show (a guest's video included) reads
    /// as itself rather than as its host channel.
    ///
    /// The card takes this in rather than resolving it itself: Continue
    /// Watching and Up Next render a grid of these, and re-deriving show
    /// membership (or a fresh `@Query`) on every card's every body
    /// evaluation doesn't scale the way one lookup per video, done once by
    /// the section, does. See `ShowManager.show(containing:in:)`.
    let show: Show?

    /// A show whose art preference is thumbnails shows the video's own
    /// thumbnail, for the channels whose avatar carries no information.
    /// Everything else — every video that belongs to no show — keeps the
    /// channel art.
    private var prefersThumbnails: Bool {
        show?.artPreference == .thumbnails
    }

    /// The caption under the art: the show's title, or the channel's when
    /// the video belongs to no show.
    private var caption: String {
        show?.title ?? video.channelTitle
    }

    /// The art, and what the monogram falls back to when there's no image:
    /// the video rather than the channel when thumbnails are asked for, so
    /// the preference is visible even before an image loads.
    private var art: (url: String?, title: String, seed: String) {
        prefersThumbnails
            ? (video.thumbnailURL, video.title, video.videoId)
            : (avatarURL, video.channelTitle, video.channelId)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: size == .large ? 8 : 6) {
            ZStack(alignment: .bottom) {
                ChannelArt(url: art.url, title: art.title, seed: art.seed)
                    .aspectRatio(size == .large ? 4 / 3 : 1, contentMode: .fit)
                if let progress {
                    ProgressView(value: progress)
                        .tint(.white)
                        .padding(.horizontal, size == .large ? 8 : 6)
                        .padding(.bottom, size == .large ? 6 : 4)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: size == .large ? 10 : 8))
            Text(caption)
                .font((size == .large ? Font.caption : .caption2).weight(.semibold))
                .foregroundStyle(.secondary)
            Text(video.displayTitle)
                .font(size == .large ? .headline : .subheadline.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                EpisodeBadge(video: video)
                if progress == nil {
                    Text(video.formattedDuration)
                } else {
                    Text(video.formattedTimeLeft)
                        .foregroundStyle(.primary)
                }
                Text(video.publishedAt, format: .relative(presentation: .named))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

/// A channel's avatar filling whatever frame it's given, with a monogram on
/// a colour derived from the channel ID when there's no image (fixtures,
/// or a channel whose avatar hasn't loaded). Small art never carries a
/// squeezed name; the name is set beneath the art by the caller.
struct ChannelArt: View {
    let url: String?
    let title: String
    /// Stable input for the fallback colour, so a channel keeps its hue
    /// across launches. Usually the channel ID.
    let seed: String

    var body: some View {
        GeometryReader { proxy in
            CachedAsyncImage(
                url: url.flatMap(URL.init(string:)),
                size: proxy.size
            ) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                monogram
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .clipped()
    }

    private var monogram: some View {
        ZStack {
            Color(hue: Self.hue(for: seed), saturation: 0.35, brightness: 0.55)
            Text(Self.initials(of: title))
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                .foregroundStyle(.white.opacity(0.9))
        }
    }

    static func initials(of title: String) -> String {
        let words = title.split(whereSeparator: { $0.isWhitespace || $0 == "-" })
        let letters = words.prefix(2).compactMap { $0.first(where: \.isLetter) }
        return letters.isEmpty ? "•" : String(letters).uppercased()
    }

    /// A hue in 0..<1 derived from the seed without `hashValue`, which is
    /// randomly salted per process and would change the colour every launch.
    static func hue(for seed: String) -> Double {
        let hash = seed.unicodeScalars.reduce(UInt32(2166136261)) { ($0 ^ $1.value) &* 16777619 }
        return Double(hash % 360) / 360
    }
}
