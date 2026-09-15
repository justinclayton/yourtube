import SwiftUI

/// The episode number the title cleaner pulled out of a title ("Ep. 142",
/// "S20 Ep. 4"), set as a small label beside the other metadata rather than
/// left in the title. Renders nothing when the video has no numbering, so
/// callers can drop it in unconditionally.
struct EpisodeBadge: View {
    let video: Video

    var body: some View {
        if let label = video.episodeLabel {
            Text(label)
                .font(.caption2.weight(.semibold).monospacedDigit())
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(.secondary)
        }
    }
}
