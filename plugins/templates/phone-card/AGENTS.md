# Upgrade plugin workspace

This folder is a Upgrade plugin: Luau code that draws cards on a phone's Home
screen. The phone checks and renders it. Nothing here runs on this machine.

```
upgrade.plugin.toml   manifest: id, name, permissions, widgets and their sizes
main.luau             entry: state, events, and which function draws each card
lib/*.luau            modules; list each one under `files` in the manifest
fixtures/*.json       {widget, events, state?}: what the phone replays to check a card
upgrade-sdk.json      the pinned SDK: manifest fields, every ui.* node and its
                      properties, every diagnostic code; read it before writing UI
```

## Loop

The phone has this folder open in TOOLS > DEVELOP PLUGIN. It reads the files
every two seconds and, for each new revision or ask, checks the manifest, runs
every fixture and validates each card tree, then writes the result to
`.upgrade/preview/latest.json`.

After each edit run:

```
sh .upgrade/wait.sh
```

It prints that result once the phone has checked the current files. Exit 0
means no errors (warnings may remain), 1 means errors, 3 means the phone did
not answer within a minute (the preview is not open on this folder).

Each diagnostic has `code`, `message`, `source` (`path`, `line`), `expected`,
`actual` and `next_action`. Fix the first error, run the script again, repeat
until it exits 0, then read the warnings. `artifacts.renders` lists each card
drawn: fixture, widget, size, root key, node count and requested effects. An
empty list means no fixture reached a card.

## Rules

- Only `upgrade.plugin.toml`, `*.luau` and `fixtures/*.json` count. Other files
  are ignored by the phone.
- Use only nodes and properties listed in `upgrade-sdk.json`. An unknown
  property is an error, not a warning.
- Keep the plugin phone-only unless asked: no `host_capabilities`, no new
  permissions. Each permission is shown to the user at install.
- Keep `id` once the plugin is installed: the phone stores data under it.
- Add a fixture for each event a card handles, so the check exercises it.

When the check is clean, the user installs it from the same phone screen.
