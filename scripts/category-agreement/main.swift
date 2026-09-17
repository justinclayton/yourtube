import Foundation

// Compares YouTube's own per-video category against the on-device
// classifier's answer, over an `exportClassifierEvidence()` JSON. See
// `scripts/category-agreement.sh` and `docs/spikes/129-youtube-category-vs-classifier.md`.
//
// The mapping and the majority rule come from the app's own
// `YouTubeCategorySignal`, compiled in alongside this file, so a change to the
// signal changes these numbers rather than leaving the harness agreeing with a
// copy of itself.

/// One export record, as much of it as the comparison reads. Everything but
/// the identity is optional so an export written by an older build still
/// loads — a missing field is one fewer channel in a population, not a crash.
struct Record: Decodable {
    var channelId: String
    var channelTitle: String
    var modelCategory: String?
    var resolvedCategories: [String]?
    var youtubeCategory: String?
    var dominantYouTubeCategory: String?
    var isUserSet: Bool?
    var userCategories: [String]?
    var youtubeCategoryVotes: [String: Int]?
}

/// What the channel is finally filed under by a human, when one has said:
/// the labelled data the issue asks the agreement rate to be measured against.
/// Nil when nobody has corrected the automatic answer.
func userCategory(_ record: Record) -> String? {
    guard record.isUserSet == true else { return nil }
    return record.userCategories?.first
}

/// The category the channel actually ended up under — the user's if they
/// corrected it, otherwise the model's.
func finalCategory(_ record: Record) -> String? {
    userCategory(record) ?? record.modelCategory
}

/// YouTube's dominant category for a channel, from the live vote tally, with
/// the share of votes it took. Nil when no stored video carries a category.
func dominant(_ votes: [String: Int]) -> (id: String, count: Int, total: Int)? {
    guard !votes.isEmpty else { return nil }
    let ranked = votes.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
    guard let top = ranked.first else { return nil }
    return (top.key, top.value, votes.values.reduce(0, +))
}

/// YouTube category IDs an uploader picks when nothing else fits, which
/// `YouTubeCategorySignal` deliberately maps to nothing. Named here too so the
/// report can count them separately rather than lumping them in with silence.
let catchAllIds: Set<String> = ["22", "24", "27"]

func percent(_ n: Int, _ d: Int) -> String {
    d == 0 ? "  n/a" : String(format: "%4.0f%%", 100 * Double(n) / Double(d))
}

func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
}

/// One line of a counted-against-a-total table, so every section's numbers
/// land in the same columns.
func row(_ label: String, _ n: Int, of total: Int) {
    print("\(pad(label, 36))\(pad(String(n), 6))\(percent(n, total))")
}

func heading(_ title: String) {
    print("")
    print(title)
    print(String(repeating: "-", count: title.count))
}

// MARK: - Input

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: category-agreement.sh <export.json>\n".utf8))
    exit(2)
}
let url = URL(fileURLWithPath: arguments[1])
let records: [Record]
do {
    records = try JSONDecoder().decode([Record].self, from: try Data(contentsOf: url))
} catch {
    FileHandle.standardError.write(Data("could not read \(url.path): \(error)\n".utf8))
    exit(1)
}

/// The live taxonomy, read off the export rather than the source: the device
/// being measured has whatever category list its user has edited into it, and
/// `CategoryManager.defaultCategoryNames` is only the seed.
let taxonomy = Array(Set(records.flatMap {
    ($0.resolvedCategories ?? []) + ($0.userCategories ?? []) + [$0.modelCategory].compactMap { $0 }
})).sorted()

print("YouTube's category vs. the on-device classifier")
print("export: \(url.lastPathComponent)  ·  \(records.count) subscriptions  ·  taxonomy of \(taxonomy.count)")

// MARK: - Coverage

heading("1. Coverage — how many channels YouTube says anything about")

let classified = records.filter { $0.modelCategory != nil }
let corrected = records.filter { userCategory($0) != nil }
var noVotes = 0, noMajority = 0, catchAll = 0, usable = 0
for record in records {
    guard let top = dominant(record.youtubeCategoryVotes ?? [:]) else { noVotes += 1; continue }
    if Double(top.count) / Double(top.total) <= YouTubeCategorySignal.majorityShare { noMajority += 1; continue }
    if catchAllIds.contains(top.id) { catchAll += 1; continue }
    usable += 1
}
row("classified by the model", classified.count, of: records.count)
row("corrected by hand", corrected.count, of: records.count)
row("no video carries a categoryId", noVotes, of: records.count)
row("no majority category", noMajority, of: records.count)
row("majority is a YouTube catch-all", catchAll, of: records.count)
row("usable YouTube signal", usable, of: records.count)

// MARK: - The shipped signal

heading("2. What `YouTubeCategorySignal` yields against this taxonomy")

var suggested = 0, suggestionMatchesFinal = 0
var secondCategoryGiven = 0
for record in records {
    let videos = (record.youtubeCategoryVotes ?? [:]).flatMap { id, count in
        (0..<count).map { _ in EpisodeSignals(durationSeconds: 0, publishedAt: .distantPast, categoryId: id) }
    }
    if let suggestion = YouTubeCategorySignal.suggestion(for: videos, taxonomy: taxonomy) {
        suggested += 1
        if suggestion.categoryName == finalCategory(record) { suggestionMatchesFinal += 1 }
    }
    if record.youtubeCategory != nil { secondCategoryGiven += 1 }
}
row("channels the signal fires on", suggested, of: records.count)
row("  ... naming the channel's filing", suggestionMatchesFinal, of: max(suggested, 1))
row("rules carrying a second category", secondCategoryGiven, of: records.count)
print("")
print("The signal only fires where `taxonomyByYouTubeCategoryId`'s target name")
print("is in this taxonomy. Names it wants but this device hasn't got:")
let wanted = Set(YouTubeCategorySignal.taxonomyByYouTubeCategoryId.values).subtracting(taxonomy).sorted()
print("  \(wanted.isEmpty ? "(none)" : wanted.joined(separator: ", "))")

// MARK: - Agreement

heading("3. Agreement, YouTube's dominant category vs. the channel's filing")

/// Channels with both halves: a clear YouTube majority and a category the
/// channel is actually filed under.
struct Pair { var youtubeId: String; var category: String }
var pairs: [Pair] = []
for record in records {
    guard let category = finalCategory(record),
          let top = dominant(record.youtubeCategoryVotes ?? [:]),
          Double(top.count) / Double(top.total) > YouTubeCategorySignal.majorityShare
    else { continue }
    pairs.append(Pair(youtubeId: top.id, category: category))
}
let literal = pairs.filter { YouTubeCategory.name(forId: $0.youtubeId) == $0.category }.count
row("comparable channels", pairs.count, of: records.count)
row("YouTube's name equals the filing", literal, of: max(pairs.count, 1))
print("")
print("Literal equality is the wrong measure when the two taxonomies don't")
print("share a vocabulary. The table below is the generous one: for each")
print("YouTube category, the best a perfect hand-written mapping could do.")

var byYouTube: [String: [String: Int]] = [:]
for pair in pairs { byYouTube[pair.youtubeId, default: [:]][pair.category, default: 0] += 1 }

print("")
print("\(pad("YouTube category", 24))\(pad("n", 6))  best  most common filings")
var oracle = 0, oracleUsable = 0, usablePairs = 0
for (youtubeId, filings) in byYouTube.sorted(by: { $0.value.values.reduce(0,+) > $1.value.values.reduce(0,+) }) {
    let n = filings.values.reduce(0, +)
    let best = filings.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
    let top = best[0].value
    oracle += top
    if !catchAllIds.contains(youtubeId) { usablePairs += n; oracleUsable += top }
    let shown = best.prefix(4).map { "\($0.key) \($0.value)" }.joined(separator: ", ")
    print("\(pad(YouTubeCategory.name(forId: youtubeId), 24))\(pad(String(n), 6))\(percent(top, n))  \(shown)")
}
print("")
print("Best case with YouTube's category alone: \(oracle)/\(pairs.count) = \(percent(oracle, max(pairs.count, 1))) of comparable")
print("channels, \(percent(oracle, records.count)) of all \(records.count) subscriptions. Dropping the catch-alls:")
print("\(oracleUsable)/\(usablePairs) = \(percent(oracleUsable, max(usablePairs, 1))), over \(percent(usablePairs, records.count)) of subscriptions.")
print("")
print("That best case is fitted on this very data — it picks each YouTube")
print("category's most common filing after seeing the answers — so it is an")
print("upper bound on what any mapping could achieve, not a forecast.")

// MARK: - Pre-filter

heading("4. What a pre-filter would save")

print("Model calls skipped if the LLM is only invoked where YouTube has no")
print("usable signal: \(usable) of \(records.count) = \(percent(usable, records.count)) of calls.")
print("Those \(usable) channels would be filed at about \(percent(oracleUsable, max(usablePairs, 1))) accuracy — the")
print("upper bound above — against a classifier pass costing ~1s per channel.")
