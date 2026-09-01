import Foundation

/// Parses the ISO 8601 durations the YouTube API returns in
/// `contentDetails.duration` (e.g. `PT4M13S`, `P1DT2H3M4S`, `PT0S`).
///
/// Written as a scanner rather than a regex so the failure modes are obvious:
/// anything malformed returns nil rather than silently yielding 0, which
/// matters because the Shorts heuristic treats 0 as "unknown, not a Short".
enum ISO8601Duration {
    static func seconds(from string: String) -> Int? {
        var chars = Array(string)
        guard !chars.isEmpty, chars.removeFirst() == "P" else { return nil }

        var total = 0
        var current = ""
        var inTimeSection = false
        var sawAnyComponent = false

        for ch in chars {
            if ch == "T" {
                inTimeSection = true
                current = ""
                continue
            }
            if ch.isNumber {
                current.append(ch)
                continue
            }
            guard let value = Int(current) else { return nil }
            current = ""
            sawAnyComponent = true

            switch (ch, inTimeSection) {
            case ("D", false): total += value * 86_400
            case ("W", false): total += value * 604_800
            case ("Y", false), ("M", false):
                // Calendar-relative units never appear in video durations.
                return nil
            case ("H", true): total += value * 3_600
            case ("M", true): total += value * 60
            case ("S", true): total += value
            default: return nil
            }
        }

        // Trailing digits with no unit designator, e.g. "PT4M13".
        guard current.isEmpty else { return nil }
        return sawAnyComponent ? total : nil
    }
}
