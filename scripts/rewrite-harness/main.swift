import Foundation
import FoundationModels

/// Runs the app's tier-two rewrite — its exact instructions, constrained
/// answer, validation and casing — over a file of stripped titles, on the
/// Mac's on-device model, and prints what the viewer would see. Built and run
/// by `scripts/rewrite-harness.sh`; see the README's "Tuning the rewrite".
@main
struct RewriteHarness {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count > 1 else {
            print("usage: rewrite-harness <titles.txt> [show title] [instructions.txt]")
            return
        }
        let show = args.count > 2 ? args[2] : ""
        let titles = ((try? String(contentsOfFile: args[1], encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        // An alternative set of instructions, to try a wording without
        // editing the app.
        let instructions = args.count > 3
            ? ((try? String(contentsOfFile: args[3], encoding: .utf8)) ?? TitleRewritePrompt.instructions)
            : TitleRewritePrompt.instructions

        guard case .available = SystemLanguageModel.default.availability else {
            print("model unavailable: \(FoundationModelTitleRewriter.unavailableReason() ?? "?")")
            return
        }

        var refused = 0, rejected = 0, unchanged = 0
        for title in titles {
            let request = TitleRewriteRequest(strippedTitle: title, showTitle: show)
            let session = LanguageModelSession(instructions: instructions)
            do {
                let response = try await session.respond(
                    to: TitleRewritePrompt.prompt(for: request),
                    generating: FoundationModelTitleRewriter.Answer.self
                )
                let answer = response.content.title
                let shown = TitleRewritePrompt.resolve(answer, strippedTitle: title)
                if shown == title { unchanged += 1 }
                if !TitleRewritePrompt.keepsToTheSource(answer, source: title) { rejected += 1 }
                print("IN : \(title)\nRAW: \(answer)\nOUT: \(shown)\n")
            } catch {
                refused += 1
                print("IN : \(title)\nERR: \(error)\nOUT: \(TitleRewritePrompt.fallback(for: title))\n")
            }
        }
        print("total=\(titles.count) refused=\(refused) rejected=\(rejected) unchanged=\(unchanged)")
    }
}
