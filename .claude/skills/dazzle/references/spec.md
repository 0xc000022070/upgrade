# Spec

`design/SPEC.md` is the contract: what the app does and looks like, in the house words, so a session with no memory builds the next thing in the same voice.

- A user ruling amends the spec first, then the code, and one commit carries both (user, 2026-09-06: "a single commit for spec and impl"). A spec edit with no code behind it — a struck idea, a correction — still commits alone.
- A ruling is a named section, `### <what it is>`, under the screen or subsystem it changes, or a new `##` for a new subsystem. No numbers, no `§`, no `39.x`. Older sections keep their numbers; refer to them by title, never by number.
- The section states the current behavior only: the words on screen, where a thing sits, what it never does, and what was deliberately not built and why. No dates, no user quotes, no ownership lines, no version stamps, no regression-test lists. The commit body carries the user's words and the reasoning; `git log` and `git blame` carry the rest.
- When a ruling changes, edit the sentence. Do not strike it through and append the new one below.

## The spec is not cited from code

Sections are an index into one file and mean nothing anywhere else.

- No `SPEC.md`, section numbers or `§` in code: comments, doc comments, test names, strings, READMEs. A comment that only points at the spec is deleted; one that carries a rule keeps the rule in plain words.
- No section references in commit messages either (user, 2026-09-06). A commit says what the code now does.
- The gate runs `grep -rn '§' lib test` and rejects on any hit; a `SPEC.md` mention in code is read by eye, since a shell tab label may legitimately hold that path.
