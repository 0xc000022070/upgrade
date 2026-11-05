# Build a tool interface in Luau

This walkthrough builds `Network probe`: a Tools page that picks a registered
host, runs one declared command on it, and reads the structured result and the
bounded output. Then it adds a failing command and a long one to show how exit
codes, cancellation, manifest updates and disable behave. It ends with a
phone-only card that never contacts a host.

The package is a trimmed copy of the `Fixture network probe` used in the
2026-11-04 device review, where install, host selection, consent, submit,
status, output, failure, cancellation and online disable were exercised on a
physical phone (release build) against the development VM. Every file below
passes `just plugin check`; this exact package has not itself been run on a
phone. The SDK reference is
[packages/upgrade_luau/README.md](../packages/upgrade_luau/README.md).

## Where things run

| machine | what runs there |
|---|---|
| development computer | an Upgrade checkout; `just plugin check`, `just plugin preview`, `just plugin docs`; your editor |
| host | the workspace folder the phone previews; `upgrade.plugin.toml` commands, executed by `upgraded` |
| phone | the preview renderer, the install review, the consent sheets, the Luau VM that runs `update` and `view` |

The phone reads the workspace over SSH. Nothing is installed until you tap
INSTALL. `just plugin docs --out upgrade-sdk.json` writes the pinned SDK
inventory (services, operations, UI schema, diagnostic codes) as JSON; NEW
WORKSPACE also writes it into the folder.

## Prerequisites

- An Upgrade checkout with the dev shell (`nix develop`), for `just plugin`.
- A host registered in MACHINES with a pinned host key (see the README's first
  connection).
- On that host, `upgraded` with `run/1`, declared by the host's owner through
  the flake's `services.upgraded` module. The app never installs it. Without it
  every `run` call fails with `This host has no upgraded installed`.
- `ip` on the host's non-interactive SSH `PATH`.

## 1. Files

```
network-probe/
  upgrade.plugin.toml
  main.luau
  fixtures/mounted.json
  fixtures/failed.json
  fixtures/cancelled.json
  fixtures/refused.json
```

`upgrade.plugin.toml`:

```toml
manifest_version = 5
id = "dev.example.network-probe"
name = "Network probe"
purpose = "Read network interfaces on a chosen host."
version = "0.1.0"
upgrade_api = "^2.1.0"
ui_api = 2

[runtime]
kind = "luau"
entry = "main.luau"

[permissions]
ui = ["page", "widget"]

[[contributes.pages]]
id = "main"
title = "Network probe"

[[contributes.widgets]]
id = "status"
title = "Network probe"
locations = ["home.card"]
default_location = "home.card"
default_size = "compact"
sizes = [{ id = "compact", title = "Compact", width = 320 }]

[host_capabilities.hosts]
api_version = 1
service = "hosts"
operations = ["list"]

[host_capabilities.jobs]
api_version = 1
service = "run"
operations = ["submit", "status", "output", "cancel"]

[host_capabilities.jobs.commands.interfaces]
argv = ["ip", "-brief", "address"]
timeout_seconds = 10
```

What it declares:

- `hosts` with `list` only: the page can name registered hosts, not reach them.
- `jobs`, a `run` alias, with one command. `argv` is exec'd as written, no
  shell. `timeout_seconds` is required. A parameter would be a whole word such
  as `{unit}`, restricted with `choices`; a free parameter to an interpreter is
  refused (step 8).
- A `status` widget. `just plugin check` and the phone preview render Home
  cards only, never a page `view`; the card is what the checker and fixtures
  exercise.

`main.luau`:

```lua
local commands = {probe = "interfaces"}

local function describe(status)
    return tostring(status.state) .. " code=" .. tostring(status.code)
        .. " signal=" .. tostring(status.signal)
        .. " cancelled=" .. tostring(status.cancelled)
        .. " timed_out=" .. tostring(status.timed_out)
end

local function update(state, event)
    if event.type == "mount" then
        return state, {ui.effect("hosts", "list", {}, "hosts")}
    end
    if event.type == "action" then
        if event.id == "choose" then
            state.host = event.value
        elseif commands[event.id] then
            state.message = "Submitting " .. commands[event.id]
            state.output = ""
            return state, {ui.effect("jobs", "submit", {host = state.host, command = commands[event.id]}, "submitted")}
        elseif event.id == "output" then
            return state, {ui.effect("jobs", "output", {host = state.host, id = state.job}, "output")}
        elseif event.id == "status" or event.id == "cancel" then
            return state, {ui.effect("jobs", event.id, {host = state.host, id = state.job}, event.id)}
        end
    elseif event.type == "result" then
        if not event.ok then
            state.message = tostring(event.error)
        elseif event.id == "hosts" then
            state.hosts = event.value.items
        elseif event.id == "submitted" then
            state.job = event.value.id
            state.message = "Submitted. Check status or read output."
        elseif event.id == "status" then
            state.message = describe(event.value)
        elseif event.id == "cancel" then
            state.message = "Cancellation requested. Check status."
        elseif event.id == "output" then
            state.message = event.value.state
            state.output = table.concat(event.value.stdout.lines, "\n")
        end
    end
    return state
end

local function card(state)
    return ui.Panel {key = "card", title = "Network probe", children = {
        ui.Text {key = "card-message", text = state.message},
    }}
end

return ui.app {
    init = function()
        return {hosts = {}, host = "", job = "", output = "", message = "Choose a host, then read its interfaces."}
    end,
    update = update,
    cards = {status = card},
    view = function(state)
        local options = {}
        for _, host in ipairs(state.hosts) do
            table.insert(options, {value = host.id, label = host.name})
        end
        return ui.Page {key = "page", title = "Network probe", breadcrumb = "/ TOOLS", children = {
            ui.Select {key = "host", label = "Target host", value = state.host, options = options, onChange = "choose"},
            ui.Text {key = "message", text = state.message},
            ui.Text {key = "job", text = state.job},
            ui.Text {key = "output", text = state.output},
            ui.Footer {key = "actions", children = {
                ui.Button {key = "probe", text = "Read interfaces", onPress = "probe", disabled = state.host == ""},
                ui.Button {key = "status", text = "Check status", onPress = "status", disabled = state.job == ""},
                ui.Button {key = "read-output", text = "Read output", onPress = "output", disabled = state.job == ""},
                ui.Button {key = "cancel", text = "Cancel run", onPress = "cancel", disabled = state.job == ""},
            }},
        }}
    end,
}
```

The flow is: `mount` asks for `hosts.list`; the `Select` stores the chosen host
id; each button returns one effect; each `result` event updates state.
`event.ok == false` carries the error message, so refusals and engine failures
show up on the page instead of being lost.

Fixtures replay events into the card. Each is `{widget, events, state?}`:

`fixtures/mounted.json`

```json
{"widget": "status", "events": []}
```

`fixtures/failed.json`

```json
{"widget": "status", "events": [
  {"type": "result", "id": "status", "ok": true,
   "value": {"state": "exited", "code": 1, "signal": null, "cancelled": false, "timed_out": false}}
]}
```

`fixtures/cancelled.json`

```json
{"widget": "status", "events": [
  {"type": "result", "id": "status", "ok": true,
   "value": {"state": "exited", "code": null, "signal": 15, "cancelled": true, "timed_out": false}}
]}
```

`fixtures/refused.json`

```json
{"widget": "status", "events": [
  {"type": "result", "id": "submitted", "ok": false, "error": "Host access was not granted"}
]}
```

## 2. Check it on the development computer

From the Upgrade checkout:

```sh
just plugin check ../network-probe
```

```
rendered cancelled · status · compact · 2 nodes
rendered failed · status · compact · 2 nodes
rendered mounted · status · compact · 2 nodes
rendered refused · status · compact · 2 nodes
check ok · revision dc986739c0ba
```

`--json` prints one envelope (`ok`, `diagnostics`, `artifacts.renders`). Each
render lists `requested_effects`, here `hosts.list` from `mount`; the checker
never runs an effect. Exit codes: 0 ok, 1 diagnostics, 2 usage.

What `check` covers: the manifest (including every declared command), Luau
compilation, each fixture, and the card tree against the UI schema. What it does
not cover: the page `view`, host effects, consent, and the engine.

## 3. Put the workspace on the host and preview it

With the development VM (see [AGENTS.md](../AGENTS.md)):

```sh
just plugin-sync ../network-probe
```

It copies the folder to `~/Projects/plugins/network-probe` on the guest, then
waits up to six seconds to copy the phone's answer back. On any other host,
copy the folder yourself, for example
`rsync -a --exclude .upgrade network-probe/ host:Projects/plugins/network-probe/`.

On the phone: TOOLS > DEVELOP PLUGIN, pick the host, enter
`~/Projects/plugins/network-probe`, START PREVIEW. The phone polls the folder
every two seconds and renders each new revision with the real card renderer.
PREVIEW READY shows the card; CHECK FAILED lists diagnostics and keeps the last
good revision on screen. The phone writes its envelope to
`.upgrade/preview/latest.json` in the workspace on the host.

```sh
just plugin preview ../network-probe --json
```

reads the copied-back envelope. Exit 3 (`PREVIEW_PENDING`, "The phone has not
rendered revision <rev>") means the phone has not answered this exact revision
yet: sync again, or check that DEVELOP PLUGIN is still open on the right path.

The preview screen says MODE FIXTURES. A passing fixture preview proves the
manifest parses, the Luau compiles and the card draws. It is not proof of host
execution, of a live data subscription, or that the page renders. Those are
checked in steps 5 to 7, on the installed plugin.

## 4. Install and review the declared command

Tap INSTALL on the preview. The native review lists the requested capabilities,
including the command as the phone will run it:

```
Run from a tap, as the host account: ip -brief address for up to 10 s
```

The review is the only place a capability is granted. A plugin cannot call an
operation it did not declare (`Host operation is not declared, supported and
granted`) or a command it did not declare (`Not a command this plugin
declares`).

Install, then OPEN the page. It is also listed under TOOLS.

## 5. Choose a target and run

1. Under Target host, choose the host. The list came from `hosts.list`, which
   returns `{items = {{id, name}, ...}}` and contacts no host.
2. Tap READ INTERFACES. The first `run` call for this revision and host raises a
   native sheet, `ALLOW NETWORK PROBE?`:

   ```
   Run on <user>@<host>?

   ip -brief address for up to 10 s

   Only these commands, each from a tap. They run with this host account's
   permissions and may change files.
   ```

   CANCEL leaves the page showing `Host access was not granted`; only another tap
   on a submit asks again.
3. After ALLOW, `run.submit` returns `{id, state = "starting", submitted = true}`.
   The page stores the id. Submitting means the engine accepted the job; it says
   nothing about the outcome.

`submit` only runs from a tap. The tap that fired the `action` event is spent by
the first operation that needs one; a `submit` returned from `mount`, `refresh`
or a timer-like loop fails with `Commands run only from a tap`. A plugin may
have at most 4 jobs starting or running per host (`4 commands are already
running on this host`).

## 6. Status beside output

CHECK STATUS calls `run.status`:

```
{id, state, pid, started, finished, code, signal, cancelled, timed_out, error}
```

READ OUTPUT calls `run.output`:

```
{id, state, stdout = {lines, matched, truncated}}
```

Read them together. `state` is `starting`, `running`, `exited` or `lost`.
`exited` with `code = 0` is success; `exited` alone is not. In the review, READ
OUTPUT showed `exited` and the VM's `lo` and `eth0` rows, matching `ip -brief
address` run in the guest.

`output` defaults to the last 200 lines of stdout. It accepts `stream`
(`stdout` or `stderr`), `head` or `tail` (1 to 500 lines), `grep` (at most 128
characters) with `ignore_case` and `invert`, and `limit` in bytes (1 to 65536,
default 32768). `truncated = true` means lines were cut by those bounds.

## 7. Failure, cancellation and a manifest update

Add two commands and bump the version:

```toml
version = "0.1.1"
```

```toml
[host_capabilities.jobs.commands.failure]
argv = ["false"]
timeout_seconds = 10

[host_capabilities.jobs.commands.waiting]
argv = ["sleep", "45"]
timeout_seconds = 60
```

and two buttons in `main.luau`:

```diff
-local commands = {probe = "interfaces"}
+local commands = {probe = "interfaces", fail = "failure", wait = "waiting"}
```

```diff
                 ui.Button {key = "probe", text = "Read interfaces", onPress = "probe", disabled = state.host == ""},
+                ui.Button {key = "fail", text = "Fail probe", onPress = "fail", disabled = state.host == ""},
+                ui.Button {key = "wait", text = "Start wait", onPress = "wait", disabled = state.host == ""},
                 ui.Button {key = "status", text = "Check status", onPress = "status", disabled = state.job == ""},
```

Check, sync, and the preview offers INSTALL THIS REVISION. What the update asks
to re-approve:

- The review marks each added command NEW. Nothing new is granted until you
  install.
- Host consent is per revision: the first run call on the new revision raises
  `ALLOW NETWORK PROBE?` again, now listing all three commands.

Results observed in the review, on the phone and in the engine's job list:

| button sequence | page shows | engine records |
|---|---|---|
| FAIL PROBE, CHECK STATUS | `exited code=1 cancelled=false` | code 1 |
| START WAIT, CANCEL RUN, CHECK STATUS | `exited code=nil cancelled=true` | signal 15, `cancelled: true`, `timed_out: false`, about 5 s |

(This tutorial's `describe` also prints `signal` and `timed_out`.) `cancel`
returns `{state = "cancelling", cancelled = true}` immediately; the engine sends
SIGTERM to the process group and SIGKILL 5 s later if it is still alive. A job
that hits `timeout_seconds` ends the same way with `timed_out = true`.

## 8. Parameters and what the manifest refuses

A command may take parameters, each a whole argv word. Values must be one word
of at most 128 letters, digits and `_.,/-`, starting with a letter, digit, `_`
or `.`; `choices` restricts a parameter to a list:

```toml
[host_capabilities.jobs.commands.logs]
argv = ["journalctl", "--user", "-u", "{unit}", "-n", "50"]
timeout_seconds = 20
choices = { unit = ["syncthing", "wayvnc"] }
```

The page then submits `{host = ..., command = "logs", params = {unit = "wayvnc"}}`.
A free parameter to an interpreter or launcher is refused at check time:

```toml
argv = ["sh", "-c", "{cmd}"]
```

```
error MANIFEST_INVALID upgrade.plugin.toml: {cmd} could make sh run anything; give it choices
  during: manifest
  next: Compare upgrade.plugin.toml with the manifest in `docs`.
```

## 9. Disable and lifetime

Jobs run under a detached engine supervisor as the SSH account. They keep
running if the phone loses its connection or the app closes, until they exit,
time out or are cancelled.

Disable (the detail sheet under TOOLS > MANAGE PLUGINS, or INSTALLED · OPEN in
DEVELOP PLUGIN) withdraws the page from Tools and cancels the plugin's live
jobs on every host it submitted to, but only hosts the phone can reach at that
moment. In the review, disabling during `sleep 45` ended the job with signal 15
and `cancelled: true` after 23 s. A host that cannot be reached stays recorded
and is retried at the next disable, or at the next app start while the plugin
is still disabled; re-enabling first skips that retry. Until then its jobs run
to completion or timeout. This offline path has not been device-verified.

Re-enabling replays no command and asks for host consent again on the next
run call.

## 10. A phone-only card

A plugin need not touch a host. This one counts how often Home refreshed it.
The full template, with a `lib/` module, an agent guide and `wait.sh`, is
[plugins/templates/phone-card](../plugins/templates/phone-card/README.md);
`just plugin init <dir> --id <id> --name <name>` copies it, and DEVELOP PLUGIN
> NEW WORKSPACE writes it into an empty folder on a host.

`upgrade.plugin.toml`:

```toml
manifest_version = 5
id = "dev.example.refresh-counter"
name = "Refresh counter"
purpose = "Count how often Home refreshed this card."
version = "0.1.0"
upgrade_api = "^2.1.0"
ui_api = 2

[runtime]
kind = "luau"
entry = "main.luau"

[permissions]
ui = ["widget"]

[[contributes.widgets]]
id = "status"
title = "Refreshes"
locations = ["home.card"]
default_location = "home.card"
default_size = "compact"
refresh_minutes = 15
sizes = [{ id = "compact", title = "Compact", width = 320 }]
```

`main.luau`:

```lua
return ui.app {
    init = function()
        return {refreshes = 0}
    end,
    update = function(state, event)
        if event.type == "refresh" then
            state.refreshes = state.refreshes + 1
        end
        return state
    end,
    cards = {
        status = function(state)
            return ui.Panel {key = "status", title = "Refreshes", children = {
                ui.BracketLabel {key = "count", label = "Refreshes", value = tostring(state.refreshes)},
                ui.StatusTag {key = "mode", label = "Phone only", color = "accent"},
            }}
        end,
    },
}
```

`fixtures/refreshed.json`:

```json
{"widget": "status", "events": [{"type": "refresh", "widget": "status"}]}
```

```
$ just plugin check ../refresh-counter
rendered refreshed · status · compact · 3 nodes
check ok · revision 2431e0f20ce0
```

Break it on purpose: change `color = "accent"` to `colour = "accent"`.

```
$ just plugin check ../refresh-counter
error UI_UNKNOWN_PROPERTY main.luau:15: ui.status_tag has no property "colour"
  node: /panel:status/status_tag:mode
  during: card
  expected: label | color | key | width | height | flex | left | top | right | bottom | args
  actual: colour
  next: Remove "colour" or use one of the listed properties.
check failed · revision 6ee760f58f6d
```

The exit code is 1. With DEVELOP PLUGIN open on the same folder, the phone shows
CHECK FAILED with the same code and line and keeps the last good revision on
screen. Restore `color` and both return to ok with the original revision.

## Troubleshooting

| symptom | check |
|---|---|
| `PREVIEW_TARGET_MISSING` warning | the manifest has no `home.card` widget; check and preview have nothing to render |
| `just plugin preview` exits 3 | the phone has not rendered this revision: is DEVELOP PLUGIN open on that host and path? Did the copy land? |
| CHECK FAILED on the phone | the same diagnostics `just plugin check` prints; fix and copy again |
| `This host has no upgraded installed` | run `command -v upgraded` over a non-interactive SSH session on the host |
| `This host's engine does not carry run/1. ...` | the host's engine predates `run/1`; the owner updates the flake input |
| `this host denies running <program>` | the host owner's `services.upgraded.denyExec` |
| `Verify the host key in MACHINES before connecting` | open MACHINES > HOSTS, VERIFY the host and TRUST its key |
| `Commands run only from a tap` | `submit` was returned from something other than a tap's `action` chain, or the tap was already spent |
| `Not a job this plugin started` | the id is not one this plugin's `submit` returned |
