---
name: take-issue
description: Implement one ready-for-agent issue end to end in this checkout. Open in a Sonnet session.
disable-model-invocation: true
---

# Take issue

One issue, this checkout, one PR. Conventions (claiming, branch name, PR body, media) are in `docs/agents/issue-tracker.md`; the simulator rules are in `README.md` → "Parallel work: the simulator pool" and "What keeps the data, and what wipes it".

Arguments: `$ARGUMENTS` is an issue number. With none, take the lowest-numbered open `ready-for-agent` issue with no open blocker (`issue_dependencies_summary.blocked_by` is 0 and no `Blocked by:` line names an open issue).

## Steps

1. **Claim.** `git fetch origin && git switch -c claude/issue-<n> origin/main`, then swap the label as the doc says. This is the first write.
2. **Read.** `gh issue view <n> --comments`. The Done-when is the completion criterion for step 3; if the issue has none, write one from its body and post it as a comment before coding.
3. **Implement.** Run `xcodegen generate` after adding or removing source files. Tests and `-seedFixtures` drives run on a pool device:
   ```sh
   UDID=$(scripts/simpool.sh acquire issue-<n>)
   # build, install over the existing app, test, drive
   scripts/simpool.sh release issue-<n>
   ```
   "YourTube Dev" is for drives that need the real signed-in store only, installing over the existing app. Verify text, state, and control values with the simulator's `inspect` action; `screenshot` for layout and colour. Done when every Done-when line holds on the device.
4. **PR.** Push, open the PR with `Closes #<n>` and, for anything visible, media per the doc. Report the PR number, what was verified and how, and any Done-when line not met.
