# Spec

- `design/SPEC.md` is the contract: §39.x, one subsection per feature, written by you from the user's words, quoting them with the date.
- A user ruling amends the spec first, then the code, and one commit carries both (user, 2026-09-06: "a single commit for spec and impl"). A spec edit with no code behind it — a struck idea, a correction — still commits alone.
- Record struck ideas in place with the date and why, so they do not come back.
- Each section ends with the regression tests it expects, so the gate has something to check the suite against.

## Section numbers stay in the spec

They are an index into one file, and they mean nothing anywhere else.

- No `§39.x` or `SPEC.md §…` in code: comments, doc comments, test names, strings, READMEs. A comment that only points at the spec is deleted; one that carries a rule keeps the rule in plain words.
- No section numbers in commit messages either (user, 2026-09-06). A commit says what the code now does.
- The gate runs `grep -rn '§' lib test` and rejects on any hit.
