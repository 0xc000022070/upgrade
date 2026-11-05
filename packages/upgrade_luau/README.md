# Upgrade Luau SDK

Luau plugins own their screen composition and event handling. Upgrade supplies native controls, keyed layout nodes, bounded drawing, private datasets, and declared asynchronous host APIs. There is no scheduler form template in Flutter. The bundled Agent tasks plugin ([`plugins/agent-schedules`](../../plugins/agent-schedules/main.luau), id `upgrade.agent-schedules`) uses this SDK. A copyable walkthrough is [docs/TOOL-TUTORIAL.md](../../docs/TOOL-TUTORIAL.md).

## Versions and entry point

A UI plugin keeps `upgrade.plugin.toml` at its repository root. Declare `manifest_version = 4` (or `5`, which adds `files` for up to 31 extra `.luau` modules loaded with `require`), a semantic plugin `version`, `upgrade_api = "^2.1.0"`, and `ui_api = 1` or `ui_api = 2`. Runtime kind is `luau`; entry is a relative `.luau` path. Add `page` to `permissions.ui` and declare one or more `contributes.pages` entries with unique `id` and `title`. Add `canvas` only when drawing is used.

`ui_api = 2` adds the house component constructors below and a `theme` table on the `mount` event; it is otherwise identical to `ui_api = 1`, and existing API 1 plugins keep working unmodified.

Manifest format, plugin release, Upgrade API range, UI API, host API, and dataset schema versions are independent. Format 2 record-action plugins and format 3 built-in native modules remain supported. Unsupported versions stay inert; catalogs and datasets are not reset.

The entry returns `ui.app {init, update, view, back, cards}`. `cards` maps a declared widget id to a function of state that draws its Home card. `init()` returns initial state. `update(state, event)` returns state and an optional list of effects. `view(state)` returns a node tree. Optional `back(state)` returns an event ID for internal navigation, or nil to leave the page. The host owns the trusted app bar and permission dialogs.

For lower-level use, return `{frame = function(input) ... end}` directly. Its input is `{state, event}`; output is `{state, view, effects, back}`. State must be a string-keyed table of transferable values. It stays on the page across worker eviction, but is not durable: write durable preferences through declared dataset APIs.

## Constructors and raw nodes

`ui.Row {key = "actions", gap = 8, children = {...}}` and `ui.node("row", {key = "actions", gap = 8}, {...})` have identical output. Constructors only build values. Authors can write their own constructors and composition functions without changing Upgrade.

Available constructors: `Screen`, `Column`, `Row`, `Stack`, `Box`, `Text`, `Button`, `Input`, `Select`, `Toggle`, `List`, `Canvas`, `Spacer`, `Divider`, `DateTime`, and, from `ui_api = 2`, `Panel`, `Section`, `ListRow`, `StatusTag`, `BracketLabel`, `Page`, `Footer`, `Disclosure`, `Choice`. Raw node kinds are their lowercase names (`list_row`, `status_tag`, `bracket_label` use underscores).

- `Page` is a scrolling native Upgrade screen with `title`, `breadcrumb`, and optional `gap`. Use it as the root. The host wires its back action to `back(state)`; do not add another app bar. Its children use intrinsic height, not `flex` or nested scrolling lists.
- `Footer`, directly inside `Page`, stays above the keyboard and system navigation. Put the primary action here.
- `Disclosure` accepts `title`, optional `subtitle`, and children. Expansion stays native. Collapsed fields remain mounted and are included in action events without extra Luau calls.
- `Choice` accepts the same options/value/onChange contract as `Select`. It displays wrapping native action blocks for a few frequent choices. `Select` opens the native picker sheet for longer lists.
- `Button` uses Upgrade's ActionBlock; `Input` uses FieldPanel and labeled native fields. `hint` is optional. Existing constructor/event contracts remain unchanged.

```lua
ui.Page {key = "compose", title = "New task", children = {
    ui.Input {key = "instruction", label = "Instruction", value = "", lines = 4},
    ui.Disclosure {key = "options", title = "Options", children = {
        ui.Input {key = "model", label = "Model", hint = "Host default", value = ""},
    }},
    ui.Footer {key = "actions", children = {
        ui.Button {key = "start", text = "Start task", background = "accent", onPress = "start"},
    }},
}}
```

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
- `Panel` and `Section` group children under an optional `title`. `Panel` is the bordered, header-stripped house panel; `Section` is a lighter grouping with no border. `ListRow` renders a house list row: `title`, `subtitle`, `caption`, `value`, boolean `node`, and optional `onPress`. `StatusTag` renders a bordered pill from `label` and semantic or hex `color`. `BracketLabel` renders a `[ LABEL ]  value` mono readout from `label`, `value`, and optional `color`. These render with native house styling and take part in theming; they are not drawn with `Canvas`.

## Events and effects

The host sends `mount` with a page ID. Actions contain `type = "action"`, `id`, current native `fields`, optional node `args`, and optional changed `value` or canvas `position`. User events also carry a host-generated UUID `token` and local ISO `now`. Field values are included in button events even if their inputs are offscreen. Returning a changed field `value` updates that native control; unchanged defaults do not overwrite local edits.

From `ui_api = 2`, `mount` also carries a `theme` table: `brightness` (`"dark"` or `"light"`), and `background`, `surface`, `border`, `text`, `muted`, `accent`, `danger` as `#RRGGBB` strings — the device's active look, resolved fresh on every mount. A plugin that does not read it keeps the house colors it already draws with.

`ui.effect(alias, operation, args, id)` requests a declared host capability. Effects run outside the Luau VM and return `{type = "result", id, ok, value}` or `{type = "result", id, ok = false, error}`. Handle failures in `update`; keep drafts until a successful save. `error` is the message string quoted in the service sections below. Calls are bounded and sequential. Upgrade generates request IDs and rechecks activation around asynchronous boundaries.

Declare each alias under `host_capabilities.<alias>` with `api_version = 1`, a `service`, and explicit `operations` (1 to 16). A manifest declares at most 8 aliases. A call to an operation the manifest does not declare, the service does not offer, or the install did not grant fails with `Host operation is not declared, supported and granted`; non-table `args` fail with `Invalid host arguments`; a `host` argument that names no registered host fails with `Choose an existing host`. Declaring a dependency does not grant access to another plugin's data. Host keys and private SSH keys never enter Luau. Host connection and setup consent are native dialogs.

### Three kinds of host access

- **Native SSH access** is the app's own: shells, Mosh, files, the code view, desktop tunnels, herdr. It uses the host's key and the account's full authority. Luau never reaches it, and no host key or private key enters Luau.
- **Declared Luau host capabilities** are the four services below. Each is reached only through `ui.effect`, only for operations the manifest declares and the install review granted, and, where noted, only after a native consent sheet or a tap. Three of them call `upgraded`, the host engine, over SSH; `hosts.list` and `hosts.workspaces` do not.
- **Future APIs** (filesystem, git, general execution, network control, page and host-effect preview) are proposals in [PLUGIN-SPEC.md](../../docs/PLUGIN-SPEC.md) and [STRATEGY.md](../../docs/STRATEGY.md). A service an engine carries, such as `fs/1` or `git/1`, is not callable from Luau until it appears in this list.

### Engine calls

`scheduler` and `run` exec `upgraded` on the host over the host's SSH link: 10 s to open the channel, 45 s for the exchange, 512 KiB of stdout and 16 KiB of stderr. The engine is installed by the host's owner through the flake's `nixosModules.upgraded`, `darwinModules.upgraded` or `homeModules.upgraded` (`services.upgraded.enable`); Upgrade never installs it. The owner's `denyCapabilities` and `denyExec` lists win over anything the phone granted. Errors shared by `scheduler` and `run`:

| message | cause |
|---|---|
| `Verify the host key in MACHINES before connecting` | the host has no pinned host key |
| `Host private key is unavailable` | the host's key is missing from the keystore |
| `<host> unreachable`, `key rejected`, `host key changed`, ... | the SSH link failed; the same reason words the app shows elsewhere |
| `Host busy` | the SSH server refused another channel |
| `Host response exceeds its limit` | stdout over 512 KiB or stderr over 16 KiB |
| `This host has no upgraded installed` | the shell answered 127 or `not found` |
| `Host engine did not answer. <stderr>` | the engine wrote no JSON |
| `Invalid engine response`, `Invalid engine result` | malformed JSON reply |
| `This host's engine does not carry <service>. <message>` | the engine lacks the service (`schedule/1`, `run/1`) |
| `this host denies <service>`, `this host denies <service>.<op>` | the owner's `denyCapabilities` |
| `Plugin is no longer active` | the plugin was disabled or updated while the call was in flight |

### Current services

- `hosts`: `list` returns `{items = {{id, name}, ...}}` for every registered host, with no consent sheet and no host contact. `workspaces({host})` returns `{items = {"~/Projects/example", ...}}`, at most 200, through the existing host workspace scanner, after native consent. Paths can be absolute or home-relative; the scheduler expands `~/` on the host, then canonicalizes the existing directory. No shell interpolation is used. Declare and grant workspace discovery separately from `list`. Errors: `Workspace access was not granted`, `Workspace scan did not finish`, or the scanner's reason.
- `scheduler`: `inspect`, `setup`, `list`, `get`, `save`, `pause`, `resume`, `run`, `history`, `output`, `cancel`, `usage`, `pause_scope`, `resume_scope`. Arguments include a registered `host` ID. The call reaches that host's `upgraded` over the `schedule/1` service; no code is ever shipped to the machine. `inspect.features` advertises `queue`, `cancel`, and `summary`; older engines omit this list.
- `run`: `submit`, `list`, `status`, `output`, `cancel`. Runs only commands the manifest declares, through the engine's `run/1`. Described below.
- `agents`: `list`, `answer`, `open`. Reads the app's agent feed and answers approvals. Described below.

### `run`

Requires an engine carrying `run/1`. A `run` alias must declare `commands`, and only a `run` alias may:

```toml
[host_capabilities.jobs]
api_version = 1
service = "run"
operations = ["submit", "status", "output", "cancel"]

[host_capabilities.jobs.commands.interfaces]
argv = ["ip", "-brief", "address"]
timeout_seconds = 10

[host_capabilities.jobs.commands.logs]
argv = ["journalctl", "--user", "-u", "{unit}", "-n", "50"]
timeout_seconds = 20
choices = { unit = ["syncthing", "wayvnc"] }
```

- 1 to 16 commands per alias; a command name is declared once across the manifest.
- `argv`: 1 to 32 printable ASCII words of at most 256 characters. No shell runs; the engine execs `argv[0]`, resolved on the non-interactive SSH `PATH`.
- A parameter is a whole word `{name}` (`[a-z][a-z0-9_]{0,31}`) and cannot be `argv[0]`. `choices` restricts a parameter to 1 to 32 listed words.
- Interpreters and launchers (`sh`, `bash`, `python`, `env`, `sudo`, `ssh`, `xargs`, `timeout`, `nix run`, `npm exec`, `docker run`, ...) refuse a free parameter: the manifest fails with `{name} could make <program> run anything; give it choices`.
- `cwd` is optional and literal; `timeout_seconds` is required, 1 to 3600.
- The install review and the consent sheet show each command as `ip -brief address for up to 10 s`, a parameter as `{name} (any word)` or `{name: a|b}`, and the permission line as `Run from a tap, as the host account: ...`.

Operations. Every call takes a registered `host`. Results are the engine's.

| op | arguments | result |
|---|---|---|
| `submit` | `command` (declared name), `params` (table, exactly the command's parameters), optional `id` (1 to 32 letters and digits) | `{id, state = "starting", submitted = true}`; the same `id` again returns that job's status with `submitted = false` |
| `list` | none | `{jobs = {status + created, ...}, truncated}`, newest 200 of this plugin's jobs on that host |
| `status` | `id` | `{id, state, pid, started, finished, code, signal, cancelled, timed_out, error}` |
| `output` | `id`, optional `stream` (`stdout` default, or `stderr`), `head` or `tail` (lines), `grep`, `ignore_case`, `invert`, `limit` (bytes) | `{id, state, stdout = {lines, matched, truncated}}` (or `stderr`) |
| `cancel` | `id` | `{id, state = "cancelling", cancelled = true}`, or `{state = "exited", cancelled = false}` when it already ended |

`state` is `starting`, `running`, `exited` or `lost`. `started` and `finished` are epoch milliseconds. A nonzero exit has `code` set; a cancelled or timed-out job has `cancelled` or `timed_out` true and, unless it handled SIGTERM and exited itself, `code = nil` and `signal = 15` (or 9). A program that cannot start exits with `code = -1` and `error` set. `lost` means the supervisor never started or stopped without recording an exit. Read `status` to learn the outcome: `exited` alone is not success.

Output clamps, applied on the phone before the call: `head` and `tail` are clamped to 1 to 500 lines, `grep` is at most 128 characters, `limit` is clamped to 1 to 65536 bytes and defaults to 32768. With neither `head` nor `tail` the engine returns the last 200 lines. Giving both fails on the engine with `head and tail cannot both be given`.

Errors: `Not a command this plugin declares`; `Pass exactly the parameters <a, b>`; `<key> is one word of letters, digits and _.,/- that does not start with -`; `<key> is one of <a, b>`; `A job id is 1 to 32 letters and digits`; `Commands run only from a tap`; `4 commands are already running on this host`; `Not a job this plugin started`; `this host denies running <program>` (the owner's `denyExec`); `head and tail are line counts`; `grep is a string of at most 128 characters`; `stream is stdout or stderr`; `Host access was not granted`.

Consent. The first `run` call of any operation for a plugin revision and host raises `ALLOW <NAME>?`: "Run on <user>@<host>?", every declared command, then "Only these commands, each from a tap. They run with this host account's permissions and may change files." ALLOW holds for that revision and host until the plugin is disabled, updated or removed; the grant is kept in memory, so a restarted app asks again. After a refusal every operation fails with `Host access was not granted` until a tapped `submit` asks again.

Gesture. `submit` needs a tap: each `action` event carries one, and the first operation that requires it spends it, so one tap starts at most one command. `mount`, `refresh` and `changed` events carry none. An effect chain started from the tap keeps it until spent.

Ownership. Every job is tagged `p` plus 16 hex digits derived from the plugin id and its source origin, and its id is `<tag>-<nonce>`. `list` sees only that tag; `status`, `output` and `cancel` refuse ids without it. At most 4 of a plugin's jobs may be `starting` or `running` on one host.

Lifetime. The engine runs each job under a detached supervisor, as the SSH account, so it survives the phone disconnecting or the app closing. At its timeout, or on `cancel`, the process group gets SIGTERM, then SIGKILL 5 s later. The phone records each host a plugin submitted to. Disabling or removing the plugin cancels that plugin's live jobs on every recorded host it can reach; a host it cannot reach stays recorded and is retried at the next disable, or at the next app start while the plugin is still disabled or removed; until then those jobs keep running or reach their timeout. RETRY HOST PAUSES does not retry this cleanup. Re-enabling replays nothing and asks for consent again. Online disable cancellation is device-verified; offline retry is not.

### `agents`

Reads the same feed as the app's own Agents panel. No consent sheet: the install review is the grant. Declaring the alias keeps the feed live while one of the plugin's pages or cards is on screen, and that surface receives `{type = "changed", capability = <alias>}` when the feed moves, at most once per second and only while the app is in the foreground.

| op | arguments | result |
|---|---|---|
| `list` | none | `{ready = false, hosts = {}, items = {}}` before the feed has loaded; otherwise `{ready = true, hosts = {{id, name, ok, read_at?, read_ago?, reason?}}, items = {...}}` |
| `answer` | `approval` (an item's `approval.id`), `allow` (boolean) | `{answer = "allowed"}` or `{answer = "denied"}`, through the host's engine |
| `open` | `id` (an item's `id`) | `{opened = true}`; the app opens that agent's shell |

Each item: `id` (`host/source/session/pane`), `host`, `host_name`, `agent`, `state` (`working`, `blocked`, `idle`, `done`), `title`, `workspace`, `directory`, `question`, `message`, `source` (`herdr` or `engine`), `seq`, and `approval = {id, tool, line}` when one is pending. `answer` and `open` need a tap and fail with `Agents are answered and opened only from a tap` otherwise. Other errors: `This approval is no longer pending`, `Answer with allow true or false`, `Already answered`, `The engine refused`, `This session is gone`. The bundled Kanban plugin (`plugins/kanban`) uses this service.

Host storage is scoped by plugin ID and source origin. No operation accepts another plugin's owner or arbitrary storage path. Each scope has its own versioned, locked JSON state and run output files. UI state, local dataset usage, and remote scheduler storage are separate measurements.

This API isolation is not an OS sandbox for agent processes. Granting agent execution delegates the host CLI's existing authority, potentially including access to other files and network services. Upgrade states this in the native permission dialog. Plugins without that capability cannot invoke it.

## Agent tasks

The bundled Luau plugin, shown as Agent tasks, is disabled until enabled in TOOLS > MANAGE PLUGINS. It does not depend on Drops or Projects. On a registered, verified Linux host, setup requires an installed `upgraded` carrying `schedule/1`, systemd user services, login linger, and an installed, authenticated Codex or Claude CLI. A host whose engine is absent, or whose engine does not carry that service, reports the missing capability instead of simulating a schedule. Upgrade never installs the engine; the machine's owner declares it.

Setup writes only the engine's own state for that scope and the systemd user service/timer it arms. It does not enable linger, alter SSH authorization, or replace existing host jobs. The timer checks once per minute. Each run uses a detached engine supervisor, survives phone disconnection, and uses the host agent's existing permissions and authentication. No permission-bypass flags are added.

Tasks support `repeat = "now"`, `"once"`, or `"daily"`, IANA timezone, repository directory, prompt, optional model, and a 60–14400 second timeout. Now submits one task immediately; when both slots or its workspace are occupied, it queues. Queued tasks retain a snapshot of their instruction and settings. Within each plugin scope, at most two agents run concurrently and only one runs per canonical workspace path. This does not lock out other plugins, terminals, or host users. Pending tasks resume on the host timer, with up to a minute between runs. They do not expire while waiting.

Editing uses optimistic revisions. Occurrences and manual request IDs are deduplicated. Daily occurrences first discovered over five minutes late are recorded as missed; one-shot work is retained. Nonexistent daily times during daylight-saving transitions are skipped; ambiguous times use the first occurrence. The launch handoff is recorded before spawning: an interrupted handoff is reported, not automatically replayed.

`cancel({host, id})` cancels a queued run or requests termination from its supervisor. `output` retains raw `text` and adds `summary`, `warnings`, `title`, `directory`, and `schedule`. Summary extraction recognizes Codex agent messages and Claude results; diagnostics remain available. A zero process exit code is not proof that every agent tool succeeded.

Disable revokes the local plugin and requests a host-scope pause. Re-enable does not resume that host scope automatically. Unreachable hosts remain visibly pending and can be retried with RETRY HOST PAUSES in TOOLS > MANAGE PLUGINS, including after removal of an external plugin. Queued tasks stay pending during scope pause; already-running agents are not killed. Schedules, preferences, and history are retained. Removing a host from Upgrade does not stop its independent timer: pause it before unregistering it.

## Performance and limits

Luau runs on a worker isolate, not the Flutter UI thread. Scroll, typing, native pickers, layout, and painting do not invoke it every frame. Frames transfer bounded value trees; this is not a wire-level patch protocol. Flutter reuses keyed elements and virtualizes lists. Idle workers are released; no Lua loop runs in the phone background.

Each call retains the existing 50 ms script budget and 8 MiB Lua heap limit. Input and output each allow 256 KiB, depth 32, and 4096 values per collection. UI trees allow 2048 nodes, depth 24, 256 choices per select, and 512 drawing commands total. Native input text is limited to 16000 characters. Runtime memory reports include allocated input/output buffer capacity; shared Flutter heap and compiler overhead are not per-plugin heap measurements.

The plugin detail sheet shows script/load time, response size, resident VM memory, dataset calls/bytes/storage, and host API payload bytes, failures, and awaited time for the current app session. Remote storage counts remain available through the optional `usage` API, not the task composer. Host limits: 200 task definitions, 1000 retained runs, two active runs per plugin scope, 64 KiB output tail per run, and a 60–14400 second timeout. Quotas refuse new work; they do not silently delete history. Outputs explicitly represent the retained tail, not an unlimited transcript.
