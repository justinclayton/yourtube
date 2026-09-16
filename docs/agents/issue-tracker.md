# Issue tracker: GitHub

Issues and specs for this repo live as GitHub issues. Use the `gh` CLI for all operations.

## Conventions

- **Create an issue**: `gh issue create --title "..." --body "..."`. Use a heredoc for multi-line bodies.
- **Read an issue**: `gh issue view <number> --comments`, filtering comments by `jq` and also fetching labels.
- **List issues**: `gh issue list --state open --json number,title,body,labels,comments --jq '[.[] | {number, title, body, labels: [.labels[].name], comments: [.comments[].body]}]'` with appropriate `--label` and `--state` filters.
- **Comment on an issue**: `gh issue comment <number> --body "..."`
- **Apply / remove labels**: `gh issue edit <number> --add-label "..."` / `--remove-label "..."`
- **Close**: `gh issue close <number> --comment "..."`

## Claiming an issue

Open issues an agent may pick up carry `ready-for-agent`. "Take the next issue" means the lowest-numbered open `ready-for-agent` issue with no open blocker. Claiming is the session's first write: swap the label so no other session picks the same one.

```
gh issue edit <n> --add-label in-progress --remove-label ready-for-agent
```

An issue that says "design first" or asks for `/grilling` carries `needs-human` instead of `ready-for-agent`: a person settles the design in a session, records the outcome on the issue, and swaps the label. Agents never claim `needs-human` issues.

Name the working branch `claude/issue-<n>` after the issue number. Open the PR with `Closes #<n>` in the body; the merge closes the issue and the `in-progress` label goes with it.

Infer the repo from `git remote -v`; `gh` does this automatically when run inside a clone.

## Running issues with subagents

A coordinator session can work a batch of `ready-for-agent` issues by launching one subagent per issue, each in its own worktree (`.claude/worktrees/issue-<n>`, branch `claude/issue-<n>`), in dependency order. `/run-issues` (in `.claude/skills`) is that process; `/take-issue` is the single-issue path for a Sonnet session in the main checkout. Defaults, from measuring the September 2026 runs:

- **Model: Sonnet by default.** Sonnet finished the same issues in the same number of turns as Opus, every PR merged, and it costs about 2.4× less per turn. Use Opus only for architecture or refactor issues that rewrite files other issues also touch (the SwiftData writer move in #64 is the shape). Keep Fable for the coordinator itself; it draws from a separate, tighter weekly budget.
- **Concurrency: 2–3 agents at once.** Waves of 4–5 hit the plan's 5-hour limit twice and killed five agents mid-task; a killed agent does not resume, and its replacement re-derives state. Check the plan usage (`get_usage`) before launching each wave.
- **Startup cost is not the lever.** An agent's first turn writes about 50K tokens of system prompt, tool schemas, and brief; the whole run re-reads that on every turn, and so does a single long session. Write briefs as long as they need to be.
- **Context growth is the lever.** Cost per agent scales with turns × context size. Have agents verify text and state with the simulator's `inspect` action and take a `screenshot` only for layout or colour: a screenshot adds ~1.3K tokens to every later turn, and screenshots were a quarter of context growth. Xcodebuild output was negligible.
- **Simulators.** Tests and `-seedFixtures` drives go to the pool via `scripts/simpool.sh`. "YourTube Dev" holds the only signed-in store and has no lock, so a wave carries at most one issue that drives it. Install and test upgrade in place; `xcrun simctl uninstall` or `erase` on YourTube Dev wipes the store, so agents never run them.
- **The brief** lives in `/run-issues`; edit it there rather than in an agent prompt, so every wave gets the same one.
- **Recovery.** On resuming a run after a limit or a sleep: `xcrun simctl list devices | grep YourTube`, boot what is down, `scripts/simpool.sh status` and release locks held by dead agents, then launch a fresh agent with an explicit "state you inherit" section (commits, PR, scratchpad artifacts, how `main` moved).

## Screenshots and video on pull requests

A PR for anything a person can see (a new screen, control, layout, or a visible bug fix) carries pictures of it, so the review can happen from the PR page rather than by building the branch. Screenshots for a static change; a short GIF for an interaction (a tap, a swipe, a transition). Skip it for pure model, refactor, or tooling changes.

Media lives on the orphan branch `pr-media`, one directory per issue, and is referenced from the PR body by raw URL. It never merges into `main`.

```
# from any checkout, without disturbing the working tree
git fetch origin pr-media
git worktree add --detach /tmp/pr-media-<n> origin/pr-media   # detached, so parallel sessions don't fight over the branch
mkdir -p /tmp/pr-media-<n>/issue-<n> && cp <screenshots> /tmp/pr-media-<n>/issue-<n>/
git -C /tmp/pr-media-<n> add -A && git -C /tmp/pr-media-<n> commit -m "Add media for issue #<n>"
git -C /tmp/pr-media-<n> push origin HEAD:pr-media   # rejected? pull --rebase origin pr-media, then push again
git worktree remove /tmp/pr-media-<n>
```

Reference each file as `![caption](https://raw.githubusercontent.com/justinclayton/yourtube/pr-media/issue-<n>/<file>)`, with a one-line caption saying what to look at. Keep files small: downscale screenshots to about 600px wide (`sips --resampleWidth 600 in.png --out out.png`), and keep GIFs under a few megabytes.

Recording a GIF from the simulator:

```
xcrun simctl io <udid> recordVideo --codec h264 -f drive.mp4 &   # then drive the app
kill -INT %1                                                        # stops the recording
ffmpeg -y -i drive.mp4 -vf "fps=10,scale=390:-1:flags=lanczos" -loop 0 drive.gif
```

Before-and-after pairs are the most useful shape for a fix; a single frame of the new thing is enough for a feature.

## Pull requests as a triage surface

**PRs as a request surface: no.** _(Set to `yes` if this repo treats external PRs as feature requests; `/triage` reads this flag.)_

When set to `yes`, PRs run through the same labels and states as issues, using the `gh pr` equivalents:

- **Read a PR**: `gh pr view <number> --comments` and `gh pr diff <number>` for the diff.
- **List external PRs for triage**: `gh pr list --state open --json number,title,body,labels,author,authorAssociation,comments` then keep only `authorAssociation` of `CONTRIBUTOR`, `FIRST_TIME_CONTRIBUTOR`, or `NONE` (drop `OWNER`/`MEMBER`/`COLLABORATOR`).
- **Comment / label / close**: `gh pr comment`, `gh pr edit --add-label`/`--remove-label`, `gh pr close`.

GitHub shares one number space across issues and PRs, so a bare `#42` may be either: resolve with `gh pr view 42` and fall back to `gh issue view 42`.

## When a skill says "publish to the issue tracker"

Create a GitHub issue.

## When a skill says "fetch the relevant ticket"

Run `gh issue view <number> --comments`.

## Wayfinding operations

Used by `/wayfinder`. The **map** is a single issue with **child** issues as tickets.

- **Map**: a single issue labelled `wayfinder:map`, holding the Notes / Decisions-so-far / Fog body. `gh issue create --label wayfinder:map`.
- **Child ticket**: an issue linked to the map as a GitHub sub-issue (`gh api` on the sub-issues endpoint). Where sub-issues aren't enabled, add the child to a task list in the map body and put `Part of #<map>` at the top of the child body. Labels: `wayfinder:<type>` (`research`/`prototype`/`grilling`/`task`). Once claimed, the ticket is assigned to the driving dev.
- **Blocking**: GitHub's **native issue dependencies**, the canonical, UI-visible representation. Add an edge with `gh api --method POST repos/<owner>/<repo>/issues/<child>/dependencies/blocked_by -F issue_id=<blocker-db-id>`, where `<blocker-db-id>` is the blocker's numeric **database id** (`gh api repos/<owner>/<repo>/issues/<n> --jq .id`, _not_ the `#number` or `node_id`). GitHub reports `issue_dependencies_summary.blocked_by` (open blockers only, the live gate). Where dependencies aren't available, fall back to a `Blocked by: #<n>, #<n>` line at the top of the child body. A ticket is unblocked when every blocker is closed.
- **Frontier query**: list the map's open children (`gh issue list --state open`, scoped to the map's sub-issues / task list), drop any with an open blocker (`issue_dependencies_summary.blocked_by > 0`, or an open issue in the `Blocked by` line) or an assignee; first in map order wins.
- **Claim**: `gh issue edit <n> --add-assignee @me`, the session's first write.
- **Resolve**: `gh issue comment <n> --body "<answer>"`, then `gh issue close <n>`, then append a context pointer (gist + link) to the map's Decisions-so-far.
