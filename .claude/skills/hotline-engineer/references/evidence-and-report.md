# Evidence and report

## Evidence

Directory `evidence/phaseN/` in your scratchpad. README capped at: what shipped, checks, evidence index, deviations.

- Numbered PNGs, one per spec claim, in spec order. Cropped variants for header details, suffixed `b`.
- Glitch effects via `screenrecord`, cut into consecutive frames.
- Network error paths are proven inside the tailnet: `100.64.0.253` (unassigned CGNAT) for unreachable, nyx `100.118.60.77` user `luisnquin` with the key deliberately not installed for key rejected. Register hosts through the UI, never as defaults.
- Zero-network claims come with a capture or a log line, not a sentence.
- Park release apks at `rose:/tmp/hotline-v<N>.apk` and state the md5. Emulator install in place; report `versionCode`, `firstInstallTime`, `lastUpdateTime`.
- Reset the emulator display with `wm size reset` when done.

## Report

`herdr agent prompt wQ:p1 "BUILDER DONE: ..."` or `"CODEX DONE: ..."`.

Include: files touched; tests added and total passing; failures in other agents' in-flight files by name and count, untouched; evidence path; the migration proof line; emulator install state; deviations with the reason. No evidence, no DONE.
