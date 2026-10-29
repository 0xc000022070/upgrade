# Hello card

A phone-only Striked plugin: one Home card, drawn from Luau, with no host access.

```
striked.plugin.toml   manifest: id, ui_api 2, the widget and its sizes
main.luau             entry: state, events, and which function draws each card
lib/card.luau         the card tree
fixtures/*.json       {widget, events, state?}: what a preview replays
```

No checkout at hand? On the phone, TOOLS > DEVELOP PLUGIN > NEW WORKSPACE writes
this template to an empty folder on a host, with `AGENTS.md`, `striked-sdk.json`
and `.striked/wait.sh`, and starts the preview. A coding agent in that folder
edits, runs `sh .striked/wait.sh` and reads the phone's check.

## Commands

Run from a Striked checkout. `just plugin` is `dart run tool/striked_plugin.dart`.

| command | does | exit |
|---|---|---|
| `just plugin init <dir> --id <id> --name <name>` | copy this template | 0, 2 |
| `just plugin docs [--out sdk.json]` | the pinned SDK, UI schema and diagnostic codes, as JSON | 0 |
| `just plugin check <dir> [--json]` | manifest, Luau, every fixture and the card tree, off the phone | 0 ok, 1 diagnostics |
| `just plugin preview <dir> [--json] [--wait <s>]` | the phone's result for this exact revision | 0 ok, 1 diagnostics, 3 pending |

`--json` prints one envelope:

```json
{
  "schema_version": 1,
  "command": "check",
  "ok": false,
  "diagnostics": [{
    "code": "UI_UNKNOWN_PROPERTY",
    "severity": "error",
    "message": "ui.status_tag has no property \"colour\"",
    "source": {"path": "lib/card.luau", "line": 7},
    "node": "/panel:status/status_tag:mode",
    "expected": "label | color | key | ...",
    "actual": "colour",
    "next_action": "Remove \"colour\" or use one of the listed properties.",
    "api_version": "2.1.0",
    "ui_api": 2
  }],
  "artifacts": {"revision": "8e3b74784ac2", "renders": []},
  "context": {"striked_api": "2.1.0", "ui_api": 2, "manifest_version": 5}
}
```

`revision` hashes the manifest, every `.luau` file and the fixtures. The CLI and
the phone compute it the same way.

## Preview on the phone

The phone reads the workspace from a host over SSH, the same link its Files use,
and renders it with the real card renderer. Nothing is installed.

1. Put the workspace on a host the phone already knows. With the fixture VM:
   `just plugin-sync <dir>` copies it to `~/Projects/plugins/<name>`.
2. On the phone, open TOOLS > DEVELOP PLUGIN, pick the host, enter the path,
   and tap START PREVIEW.
3. Edit, then sync again. The phone polls every two seconds and checks each new
   revision. If a revision fails, the phone keeps the last good one on screen and
   lists the diagnostics.
4. The phone writes its envelope to `<dir>/.striked/preview/latest.json` on the
   host. `just plugin-sync <dir>` copies it back, waiting up to six seconds for
   the phone to answer the revision it just uploaded (the whole six when nothing
   changed, since the phone writes once per revision); then run
   `just plugin preview <dir>`. Exit 3 means the phone has not rendered this
   revision yet.

The checker runs `card` with a `mount` event and then each fixture's events. Any
effects a card returns are listed but never run.
