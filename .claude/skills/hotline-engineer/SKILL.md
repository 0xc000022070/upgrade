---
name: hotline-engineer
description: Build, test, run and evidence a Hotline checkpoint as the builder or codex engineer under the orchestrator. Use when given a Hotline brief, when producing evidence for a spec section, or when writing a DONE report.
---

# Hotline engineer

Flutter, Drift, Riverpod, dark monochrome, accent `#B7FF2A`, Barlow Condensed and IBM Plex Mono. The contract is `design/SPEC.md`; the brief names the section and your file scope.

- Touch only the files in your brief. A file you need but do not own is a deviation in the report, not an edit.
- `pubspec.yaml` and `pubspec.lock` have one named owner per phase.
- No features the spec does not name. The AGENTS panel never assumes a host.
- Code in English. Comments only for non-obvious behaviour. Reasoning goes in the report.
- Emulator only. Never touch faraday. Never edit `authorized_keys` on any host.
- One `flutter analyze` and one `flutter test` run at the end of the checkpoint.

Open the reference for the step you are on:

| step | read |
|---|---|
| building, running, hot reload, screenshots | `references/toolchain.md` |
| the brief moves the schema version | `references/migrations.md` |
| producing evidence or writing the DONE report | `references/evidence-and-report.md` |
