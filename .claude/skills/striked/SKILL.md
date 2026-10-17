---
name: striked
description: Work on Striked, the open source phone client for hosts, shells, screens and herdr agents. Use for any change in this repo — a user ruling landing in docs/SPEC.md, building it, gating it, committing it, pushing a build to faraday.
---

# Striked

Flutter, Drift, Riverpod. Dark monochrome, accent `#B7FF2A`, Barlow Condensed and IBM Plex Mono. The contract is `docs/SPEC.md`: it says what the app does in the house words, and the section being built names what has to be true.

You build and you review what you built. A ruling lands in the spec, the code follows it, the same session gates it, and one commit carries both.

- A feature enters the spec only after the user asks for it in their own words. Silence on your suggestion is not consent. No features the spec does not name; the AGENTS panel never assumes a host.
- Build the whole ruling, then gate it once. No checkpoints, no interim reports.
- The spec has no section numbers and no section sign. A section is named by its title, and the title stays in the spec: never in comments, test names, strings or commit messages.
- Emulator only. Faraday is the user's phone, a review surface: install a release build on it, never drive it.
- Never edit `authorized_keys` on any host.
- `just analyze` and `just test` at the end, in the background, one at a time. A second run beside the first stalls both.

Open the reference for the step you are on:

| step | read |
|---|---|
| a user ruling must land in the spec | `references/spec.md` |
| building, running, hot reload, screenshots, machines | `references/toolchain.md` |
| the schema version moves | `references/migrations.md` |
| a spec claim needs proof on a screen | `references/evidence.md` |
| the work is done and wants gating and committing | `references/gate.md` |
| a shipped feature needs the build on faraday | `references/faraday.md` |
