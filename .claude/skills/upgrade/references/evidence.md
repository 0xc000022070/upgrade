# Evidence

Directory `evidence/<feature>/` in your scratchpad, with a README capped at: what shipped, the checks that ran, the evidence index.

- Numbered PNGs, one per spec claim, in spec order. Cropped variants for header details, suffixed `b`.
- Glitch effects via `screenrecord`, cut into consecutive frames.
- Network error paths are proven inside the tailnet: `100.64.0.253` (unassigned CGNAT) for unreachable, nyx `100.118.60.77` user `luisnquin` with the key deliberately not installed for key rejected. Register hosts through the UI, never as defaults.
- Zero-network claims come with a capture or a log line, not a sentence.
- Park release apks at `rose:/tmp/upgrade-v<N>.apk` and state the md5. Emulator install in place; report `versionCode`, `firstInstallTime`, `lastUpdateTime`.
- Reset the emulator display with `wm size reset` when done.
