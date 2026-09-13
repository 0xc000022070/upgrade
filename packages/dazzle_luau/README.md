# Dazzle Luau SDK

Luau plugins own their screen composition and event handling. Dazzle supplies native controls, keyed layout nodes, bounded drawing, private datasets, and declared asynchronous host APIs. There is no scheduler form template in Flutter. The shipped [Agent schedules plugin](../../plugins/agent-schedules/main.luau) uses this SDK.

## Versions and entry point

A UI plugin keeps `dazzle.plugin.toml` at its repository root. Declare `manifest_version = 4`, a semantic plugin `version`, `dazzle_api = "^2.1.0"`, and `ui_api = 1`. Runtime kind is `luau`; entry is a relative `.luau` path. Add `page` to `permissions.ui` and declare one or more `contributes.pages` entries with unique `id` and `title`. Add `canvas` only when drawing is used.

Manifest format, plugin release, Dazzle API range, UI API, host API, and dataset schema versions are independent. Format 2 record-action plugins and format 3 built-in native modules remain supported. Unsupported versions stay inert; catalogs and datasets are not reset.

The entry returns `ui.app {init, update, view, back}`. `init()` returns initial state. `update(state, event)` returns state and an optional list of effects. `view(state)` returns a node tree. Optional `back(state)` returns an event ID for internal navigation, or nil to leave the page. The host owns the trusted app bar and permission dialogs.

For lower-level use, return `{frame = function(input) ... end}` directly. Its input is `{state, event}`; output is `{state, view, effects, back}`. State must be a string-keyed table of transferable values. It stays on the page across worker eviction, but is not durable: write durable preferences through declared dataset APIs.

## Constructors and raw nodes

`ui.Row {key = "actions", gap = 8, children = {...}}` and `ui.node("row", {key = "actions", gap = 8}, {...})` have identical output. Constructors only build values. Authors can write their own constructors and composition functions without changing Dazzle.

Available constructors: `Screen`, `Column`, `Row`, `Stack`, `Box`, `Text`, `Button`, `Input`, `Select`, `Toggle`, `List`, `Canvas`, `Spacer`, `Divider`, `DateTime`. Raw node kinds are their lowercase names.

- Every node needs a stable, globally unique `key`. Keyed native elements retain editing state; do not generate new keys on every event.
- `Screen` is the page body, with safe-area handling and vertical layout. `Column` and `Row` accept `gap` and `align` (`start`, `center`, `end`, `stretch`). Child `flex` fills available bounded space. Give a page's scrolling `List` `flex = 1`.
- `Stack` positions children with `left`, `top`, `right`, and `bottom`; give the stack bounded dimensions. `Box` provides padding, background, border, and vertically arranged children.
- `width`, `height`, `padding`, `gap`, and `flex` are native layout properties. Use native layout instead of calculating screen pixels in Luau.
- `Text` accepts `text`, `fontSize`, `bold`, and optional heading `style`. Semantic colors are `text`, `muted`, `accent`, `background`, `surface`, `border`, `danger`; RGB hex colors also work.
- `Button` accepts `text`, `onPress`, optional value-only `args`, and `disabled` or `enabled`. No function crosses into Flutter.
- `Input` accepts `label`, string `value`, and `lines`. Typing remains native; optional `onChange` runs on submit, not every keystroke.
- `Select` accepts string `value`, `options = {{value, label}, ...}`, and optional `onChange`. `Toggle` uses a boolean `value`. `DateTime` uses `HH:mm` with `mode = "time"`, or `YYYY-MM-DDTHH:mm` for a date and time. The plugin chooses timezone semantics.
- `List` creates children lazily and retains field values while they scroll offscreen. It does not call Luau while scrolling.
- `Canvas` accepts `width`, `height`, and drawing `commands`. Operations are `rect` (`x`, `y`, `width`, `height`), `line` (`x`, `y`, `x2`, `y2`, `stroke`), `circle` (`x`, `y`, `radius`), and `text` (`x`, `y`, `text`, `size`), each with `color`. Drawing is clipped. Optional `onPress` receives local `position = {x, y}`. Unchanged commands do not repaint.

## Events and effects

The host sends `mount` with a page ID. Actions contain `type = "action"`, `id`, current native `fields`, optional node `args`, and optional changed `value` or canvas `position`. User events also carry a host-generated UUID `token` and local ISO `now`. Field values are included in button events even if their inputs are offscreen. Returning a changed field `value` updates that native control; unchanged defaults do not overwrite local edits.

`ui.effect(alias, operation, args, id)` requests a declared host capability. Effects run outside the Luau VM and return `{type = "result", id, ok, value}` or `{type = "result", id, ok = false, error}`. Handle failures in `update`; keep drafts until a successful save. Calls are bounded and sequential. Dazzle generates request IDs and rechecks activation around asynchronous boundaries.

Declare each alias under `host_capabilities.<alias>` with `api_version = 1`, a `service`, and explicit `operations`. Declaring a dependency does not grant access to another plugin's data. Host keys and private SSH keys never enter Luau. Host connection and setup consent are native dialogs.

Current services:

- `hosts`: `list` returns registered host IDs and names.
- `scheduler`: `inspect`, `setup`, `list`, `get`, `save`, `pause`, `resume`, `run`, `history`, `output`, `usage`, `pause_scope`, `resume_scope`. Arguments include a registered `host` ID. Source installation is supplied by Dazzle, never accepted from script arguments.

Host storage is scoped by plugin ID and source origin. No operation accepts another plugin's owner or arbitrary storage path. Each scope has its own versioned SQLite database and run output files. UI state, local dataset usage, and remote scheduler storage are separate measurements.

This API isolation is not an OS sandbox for agent processes. Granting agent execution delegates the host CLI's existing authority, potentially including access to other files and network services. Dazzle states this in the native permission dialog. Plugins without that capability cannot invoke it.

## Agent schedules

The built-in Luau plugin is disabled until enabled in Settings. It does not depend on Drops or Projects. On a registered, verified Linux host, setup requires Python 3.9+, systemd user services, login linger, and an installed, authenticated Codex or Claude CLI. Unsupported hosts explain what is missing; macOS and Windows adapters are not implemented.

Setup writes only the owner's Dazzle runner, database, and systemd user service/timer. It does not enable linger, alter SSH authorization, or replace existing host jobs. The timer checks once per minute. Each run uses a separate transient user service, survives phone disconnection, and uses the host agent's existing permissions and authentication. No permission-bypass flags are added.

Schedules support once or daily execution, IANA timezone, repository directory, prompt, optional model, and timeout. Editing uses optimistic revisions. Occurrences and manual request IDs are deduplicated. Runs over five minutes late are recorded as missed instead of silently replayed. Nonexistent daily times during daylight-saving transitions are skipped; ambiguous times use the first occurrence.

Disable revokes the local plugin and requests a host-scope pause. Re-enable does not resume that host scope automatically. Unreachable hosts remain visibly pending and can be retried from Settings, including after removal of an external plugin. Queued workers cancel after scope pause; already-running agents are not killed. Schedules, preferences, and history are retained. Removing a host from Dazzle does not stop its independent timer: pause it before unregistering it.

## Performance and limits

Luau runs on a worker isolate, not the Flutter UI thread. Scroll, typing, native pickers, layout, and painting do not invoke it every frame. Frames transfer bounded value trees; this is not a wire-level patch protocol. Flutter reuses keyed elements and virtualizes lists. Idle workers are released; no Lua loop runs in the phone background.

Each call retains the existing 50 ms script budget and 8 MiB Lua heap limit. Input and output each allow 256 KiB, depth 32, and 4096 values per collection. UI trees allow 2048 nodes, depth 24, 256 choices per select, and 512 drawing commands total. Native input text is limited to 16000 characters. Runtime memory reports include allocated input/output buffer capacity; shared Flutter heap and compiler overhead are not per-plugin heap measurements.

Settings shows script/load time, response size, resident VM memory, dataset calls/bytes/storage, and host API payload bytes, failures, and awaited time for the current app session. Agent schedules reports remote database/log bytes and counts. Host limits: 200 schedules, 1000 retained runs, two active runs per plugin scope, 64 KiB output tail per run, and a 60–14400 second timeout. Quotas refuse new work; they do not silently delete history. Outputs explicitly represent the retained tail, not an unlimited transcript.
