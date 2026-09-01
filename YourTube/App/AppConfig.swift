import Foundation

/// User-specific Google OAuth settings, loaded from `Config.plist`.
///
/// Native OAuth clients use PKCE and have no client *secret*, so the client ID
/// isn't sensitive — but it's per-install, so it stays out of the repo.
/// Copy `Config.example.plist` to `Config.plist` and fill it in. See README.
enum AppConfig {
    struct Values {
        var clientId: String
        /// Reverse-DNS callback scheme, must also be listed in Info.plist.
        var redirectScheme: String

        var redirectURI: String { "\(redirectScheme):/oauth2redirect" }
    }

    enum ConfigError: LocalizedError {
        case missingFile
        case missingKey(String)

        var errorDescription: String? {
            switch self {
            case .missingFile:
                return "Config.plist not found. Copy Config.example.plist to "
                    + "YourTube/Resources/Config.plist and add your Google OAuth client ID."
            case .missingKey(let key):
                return "Config.plist is missing the '\(key)' key."
            }
        }
    }

    static func load(bundle: Bundle = .main) throws -> Values {
        guard let url = bundle.url(forResource: "Config", withExtension: "plist"),
              let data = try? Data(contentsOf: url) else {
            throw ConfigError.missingFile
        }
        let parsed = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        )
        guard let dict = parsed as? [String: Any] else {
            throw ConfigError.missingFile
        }

        guard let clientId = dict["GoogleClientID"] as? String,
              !clientId.isEmpty, !clientId.hasPrefix("REPLACE_")
        else { throw ConfigError.missingKey("GoogleClientID") }

        guard let scheme = dict["GoogleRedirectScheme"] as? String,
              !scheme.isEmpty, !scheme.hasPrefix("REPLACE_")
        else { throw ConfigError.missingKey("GoogleRedirectScheme") }

        return Values(clientId: clientId, redirectScheme: scheme)
    }
}
