---
name: spectacle-engineer
description: Build, test and evidence a Spectacle feature — the toolchain, the emulator, schema migrations, and what proof a screen claim needs. Use when writing Spectacle code, when a schema version moves, or when producing evidence for a spec section.
---

# Spectacle engineer

Flutter, Drift, Riverpod, dark monochrome, accent `#B7FF2A`, Barlow Condensed and IBM Plex Mono. The contract is `design/SPEC.md`; the section being built names what has to be true.

- No features the spec does not name. The AGENTS panel never assumes a host.
- Code in English. Comments only for non-obvious behaviour.
- Section numbers live in the spec and nowhere else — not in comments, test names or commit messages.
- Emulator only. Never drive faraday. Never edit `authorized_keys` on any host.
- `flutter analyze` and `flutter test` at the end, in the background, one at a time.

Open the reference for the step you are on:

| step | read |
|---|---|
| building, running, hot reload, screenshots | `references/toolchain.md` |
| the schema version moves | `references/migrations.md` |
| a spec claim needs proof on a screen | `references/evidence.md` |
