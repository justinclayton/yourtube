import SwiftUI

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

    var body: some View {
        VStack(alignment: .leading, spacing: size == .large ? 8 : 6) {
            ZStack(alignment: .bottom) {
                ChannelArt(url: avatarURL, title: video.channelTitle, seed: video.channelId)
                    .aspectRatio(size == .large ? 4 / 3 : 1, contentMode: .fit)
                if let progress {
                    ProgressView(value: progress)
                        .tint(.white)
                        .padding(.horizontal, size == .large ? 8 : 6)
                        .padding(.bottom, size == .large ? 6 : 4)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: size == .large ? 10 : 8))
            Text(video.channelTitle)
                .font((size == .large ? Font.caption : .caption2).weight(.semibold))
                .foregroundStyle(.secondary)
            Text(video.title)
                .font(size == .large ? .headline : .subheadline.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
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
        Color.clear
            .overlay {
                AsyncImage(url: url.flatMap(URL.init(string:))) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        monogram
                    }
                }
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
