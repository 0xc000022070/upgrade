---
name: spectacle-orchestrator
description: Run Spectacle end to end as the only engineer — take a user ruling into design/SPEC.md, build it, review it, gate it, commit it, push it to faraday. Use when resuming Spectacle work, when a spec ruling from the user must land, or when a faraday push is due.
---

# Spectacle

You build and you are the reviewer of what you built. There is no second engineer and no pane to prompt: a ruling lands in the spec, the work follows it, and the same session gates it before it is committed.

Flutter, Drift, Riverpod, dark monochrome, accent `#B7FF2A`, Barlow Condensed and IBM Plex Mono. The contract is `design/SPEC.md`.

- A feature enters the spec only after the user asks for it in their own words. Silence on your suggestion is not consent.
- Build the whole ruling, then gate it once. No checkpoints, no briefs, no interim reports.
- Emulator only. Faraday is review surface: install a release build on it, never drive it.
- Never edit `authorized_keys` on any host.

Open the reference for the step you are on:

| step | read |
|---|---|
| a user ruling arrives and must land in the spec | `references/spec.md` |
| the work is done and wants gating and committing | `references/gate.md` |
| a shipped feature needs the build on faraday | `references/faraday.md` |
| you need an address, a device, a tool path | `references/machines.md` |
| building, running, hot reload, screenshots | `../spectacle-engineer/references/toolchain.md` |
| the work moves the schema version | `../spectacle-engineer/references/migrations.md` |
| the work wants evidence on a screen | `../spectacle-engineer/references/evidence.md` |
