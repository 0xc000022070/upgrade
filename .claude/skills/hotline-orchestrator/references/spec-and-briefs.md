# Spec and briefs

## Spec is the contract

- `design/SPEC.md`, §39.x, one subsection per feature, written by you from the user's words, quoting them with the date.
- A user ruling amends the spec first, then the briefs. Commit spec edits alone: `docs(spec): §39.N <what changed>`.
- Record struck ideas in place with the date and why, so they do not come back.

## Briefs

- One brief per checkpoint, with a hard file scope per agent. Two agents never own the same file at once.
- Name the owner of `pubspec.yaml` and `pubspec.lock` explicitly.
- Schema bumps belong to the builder. Codex gets schema-free halves behind repository interfaces in new files, and the builder implements the interfaces afterwards.
- Every brief lists the evidence you will look at, and says emulator only. Faraday is yours.
- Say what must not happen: no faraday, no `authorized_keys` edits, no files outside scope, one analyze+test run at the end.
- When an agent goes idle without a DONE, read its pane before assuming it finished.
