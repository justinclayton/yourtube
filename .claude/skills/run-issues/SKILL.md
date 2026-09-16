---
name: run-issues
description: Coordinate a batch of ready-for-agent issues with one Sonnet subagent per issue, in dependency waves. Run from a Fable session.
disable-model-invocation: true
---

# Run issues

You are the coordinator. Subagents do the implementation; you decide order, launch, verify, and merge. The defaults this process rests on (model choice, wave size, simulator rules) are in `docs/agents/issue-tracker.md` → "Running issues with subagents"; read that section first and apply it as written.

Arguments: `$ARGUMENTS` may name issue numbers to run. With none, the batch is every open `ready-for-agent` issue.

## 1. Build the waves

List the batch with the issue-tracker doc's list query, then `gh issue view <n> --comments` for each. Order into waves:

- An issue whose GitHub `blocked_by` (or a `Blocked by:` line) names an open issue waits for the wave after its blocker.
- An issue that rewrites files several small issues also touch goes in a later wave than those small issues; register the `blocked_by` edge so the order is visible on GitHub.
- At most one issue per wave needs a drive against the real signed-in store on "YourTube Dev"; note which.

Model per issue: `sonnet`, or `opus` when the issue is an architecture or refactor change across files other issues touch. Record the choice beside each issue.

Done when every issue in the batch has a wave, a model, and (where needed) a registered blocker.

## 2. First message to the user

Post the wave plan as a table (issue, title, wave, model, real-store drive yes/no) and ask, in this message, for authorisation to `gh pr merge` PRs that pass their Done-when. Merging is refused unless the user grants it in this session.

## 3. Preflight

- `xcrun simctl list devices | grep YourTube`: YourTube Dev and the three "YourTube Test N" devices are Booted; boot any that are not (recreate the pool with the README recipe if missing).
- `scripts/simpool.sh status`: release locks held by agents that no longer exist.
- Check plan usage (`get_usage`). Hold the wave until the 5-hour window has room for it.

## 4. Launch a wave

Two or three agents at once. For each issue:

```sh
git worktree add .claude/worktrees/issue-<n> -b claude/issue-<n> origin/main
cp YourTube/Resources/Config.plist .claude/worktrees/issue-<n>/YourTube/Resources/
( cd .claude/worktrees/issue-<n> && xcodegen generate )
```

Launch with the Agent tool, `model` set per step 1, `run_in_background: true`, and the brief below filled in. Each agent gets the full brief; length is not a cost worth trimming.

### Brief

```
You are implementing GitHub issue #<n> for the YourTube iOS app, alone, in the
worktree <abs path> on branch claude/issue-<n>. Work only inside that worktree.

Start: `gh issue edit <n> --add-label in-progress --remove-label ready-for-agent`,
then `gh issue view <n> --comments`. The issue's Done-when is your completion
criterion; every line of it is satisfied before you open the PR.

Conventions: docs/agents/issue-tracker.md (branch, PR, media). CLAUDE.md and
README.md describe the domain and the build. After adding or removing source
files run `xcodegen generate`.

Simulators: tests and -seedFixtures drives run on a pool device:
  UDID=$(scripts/simpool.sh acquire issue-<n>)   ... scripts/simpool.sh release issue-<n>
Install over the existing app and launch with -seedFixtures for a clean
state. "YourTube Dev" holds the only signed-in store: <use it only if this
issue needs real data, installing over the existing app | do not touch it>.
Uninstalling or erasing a simulator destroys that store; never do it.

Verify with the simulator's `inspect` action for text, state, and control
values; `screenshot` only for layout or colour, and only what the PR needs.

Finish: tests pass on the pool device; open a PR whose body has `Closes #<n>`
and, for anything visible, screenshots or a GIF per the doc. Do not merge.
Release the pool device. Reply with: PR number, what you verified and how,
anything in Done-when you could not satisfy and why.

<state you inherit, when resuming: commits on the branch, open PR, scratchpad
artifacts, how main has moved since the branch was cut>
```

## 5. While agents run

Act on completion notifications. A notification that an agent is waiting on the pool is progress, not a prompt; leave it. An agent killed by a usage limit does not resume: when the window resets, launch a fresh agent with the same brief plus the "state you inherit" block.

## 6. Land a finished issue

- Read the PR diff and check each Done-when line against it. A gap goes back to a fresh agent with the gap named; a passing PR is merged (`gh pr merge <pr> --merge`) in dependency order.
- After each merge: `git fetch origin main` and merge `origin/main` into every still-open issue branch (conflicts cluster in `Video.swift`, `YourTubeApp.swift`, `ShowsView`/`ShowPageView`, `README.md`); a conflict an agent should resolve goes to a fresh Sonnet agent in that worktree.
- `git worktree remove .claude/worktrees/issue-<n>`; confirm the issue closed and `in-progress` is gone.

Done when every issue in the wave is merged or reported back to the user with its blocker.

## 7. Close out

Post a table: issue, PR, merged or not, follow-ups filed. Then end the session; a coordinator left idle re-warms its whole context on the next turn.
