# YourTube

Personal iOS YouTube client (SwiftUI + SwiftData). See `README.md` for what
works, what can't, and why.

## Ethos

YourTube is a personal client for keeping up with the channels you chose, not
for watching more. The feed is an inbox to reach the end of, shows are followed
episode by episode, and titles are calmed rather than sold. Nothing moves you
to another video on its own: no autoplay, no next-episode button, no
recommendations, no infinite feed. When a change would make the app better at
keeping you watching, it is the wrong change, however small. The fuller
version is under "Ethos" in `README.md`.

## Agent skills

### Issue tracker

Issues are tracked in GitHub Issues on `justinclayton/yourtube`. See `docs/agents/issue-tracker.md`.
Entry points: `/take-issue` for one issue (Sonnet session), `/run-issues` for a batch
(Fable coordinator, Sonnet subagents).

### Domain docs

The domain vocabulary (Show, Episode, Segment, Up Next, Continue Watching, cleaned vs raw title) and the
decisions behind it are recorded in `README.md` and PRD #17. `docs/agents/domain.md`
describes how to use those files once they are created.
