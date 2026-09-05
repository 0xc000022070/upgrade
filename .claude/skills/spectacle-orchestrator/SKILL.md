---
name: spectacle-orchestrator
description: Run the Spectacle team as orchestrator, reviewer and taste gate over the builder and codex panes in Herdr. Use when resuming Spectacle work as the coordinating session, when a child agent reports DONE, when a spec ruling from the user must land, or when a faraday push is due.
---

# Spectacle orchestrator

You coordinate. You do not build. Children build; you gate, commit, push.

- Herdr workspace `wQ`. You are `wQ:p1`. Builder, a claude session, is `wQ:p3`. Codex, a general second engineer, is `wQ:p2`.
- `herdr agent prompt <pane> "<text>"` sends work. `herdr agent read <pane>` shows a pane. `herdr agent list | jq` shows state.
- Children report by prompting your pane with `BUILDER DONE:` or `CODEX DONE:`; the user relays those verbatim.
- Codex is metered. A usage-limit screen in its pane means its files go to the builder; tell the user.
- A feature enters `design/SPEC.md` only after the user asks for it in their own words. Silence on your suggestion is not consent.
- Append a dated line to the phase memory file after every accept, ruling or push.

Open the reference for the step you are on:

| step | read |
|---|---|
| a user ruling arrives, or a brief must be written | `references/spec-and-briefs.md` |
| a DONE report arrives | `references/gate.md` |
| a phase closes and faraday needs the build | `references/faraday.md` |
| you need an address, a device, a tool path | `references/machines.md` |
