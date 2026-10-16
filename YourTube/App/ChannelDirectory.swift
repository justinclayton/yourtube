import Foundation

/// A YouTube channel the app has signed in as, from `channels.list?mine=true`.
struct ChannelIdentity: Codable, Equatable, Sendable {
    let id: String
    let title: String
}

/// Where one channel's data lives: its SwiftData store, its `UserDefaults`
/// suite and its Keychain entry for the refresh token.
///
/// `.legacy` is where the app kept everything before it knew about channels:
/// the default store file, `.standard` defaults and the `refresh_token` key.
/// The first channel the app identifies claims it, so the data that was there
/// before stays exactly where it was, with no migration. Every channel after
/// that gets its own `.channel(id)` location.
enum LibraryLocation: Hashable, Sendable {
    case legacy
    case channel(String)

    static let legacyRefreshTokenKey = "refresh_token"

    var refreshTokenKey: String {
        switch self {
        case .legacy: Self.legacyRefreshTokenKey
        case .channel(let id): "refresh_token.\(id)"
        }
    }

    /// `nil` for `.legacy`, which uses `.standard`.
    var defaultsSuiteName: String? {
        switch self {
        case .legacy: nil
        case .channel(let id): "net.claytons.yourtube.channel.\(id)"
        }
    }

    /// `nil` for `.legacy`, which uses SwiftData's default store location.
    func storeURL(in root: URL) -> URL? {
        switch self {
        case .legacy: nil
        case .channel(let id):
            root.appending(path: id, directoryHint: .isDirectory)
                .appending(path: "YourTube.store")
        }
    }
}

/// Which channels the app has seen, which one is open, and which of them owns
/// the legacy location.
///
/// Kept in the standard defaults rather than any channel's suite, because it
/// is what decides which channel's suite to open. The quota count is the only
/// other thing stored there for every channel; see `QuotaTracker`.
@MainActor
final class ChannelDirectory {
    private let defaults: UserDefaults
    private let knownKey = "channels.known"
    private let activeKey = "channels.active"
    private let legacyOwnerKey = "channels.legacyOwner"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var known: [ChannelIdentity] {
        guard let data = defaults.data(forKey: knownKey) else { return [] }
        return (try? JSONDecoder().decode([ChannelIdentity].self, from: data)) ?? []
    }

    /// The channel whose data is open, or `nil` after sign-out.
    var activeChannelId: String? {
        get { defaults.string(forKey: activeKey) }
        set { defaults.set(newValue, forKey: activeKey) }
    }

    var activeChannel: ChannelIdentity? {
        activeChannelId.flatMap { id in known.first { $0.id == id } }
    }

    /// The channel that owns the legacy location, or `nil` if no channel has
    /// been identified yet.
    var legacyOwnerId: String? { defaults.string(forKey: legacyOwnerKey) }

    func location(of channelId: String) -> LibraryLocation {
        channelId == legacyOwnerId ? .legacy : .channel(channelId)
    }

    /// Records a channel the app has just identified, updating its title if
    /// it was already known. The first channel ever recorded claims the
    /// legacy location.
    func record(_ channel: ChannelIdentity) {
        var channels = known
        if let index = channels.firstIndex(where: { $0.id == channel.id }) {
            channels[index] = channel
        } else {
            channels.append(channel)
        }
        defaults.set(try? JSONEncoder().encode(channels), forKey: knownKey)
        if legacyOwnerId == nil {
            defaults.set(channel.id, forKey: legacyOwnerKey)
        }
    }
}
