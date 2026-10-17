import Foundation
import SwiftData

/// A channel the detector believes is a show and the user hasn't decided on.
///
/// A suggestion exists only while it is pending. Accepting it or setting it
/// aside deletes it and writes the decision as a `Show` row, the same row the
/// Channels tab writes, so nothing that reads the catalogue has to know
/// suggestions exist. See `ShowSuggestions`.
@Model
final class ShowSuggestion {
    @Attribute(.unique) var channelId: String
    var title: String
    /// The detector's own sentences, as `ShowVerdict.reasons` gave them.
    var reasons: [String] = []
    var suggestedAt: Date

    init(channelId: String, title: String, reasons: [String], suggestedAt: Date = .now) {
        self.channelId = channelId
        self.title = title
        self.reasons = reasons
        self.suggestedAt = suggestedAt
    }
}
