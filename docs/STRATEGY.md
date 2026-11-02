# Upgrade: a programmable home across your computers

Strategy revision 2 · 23 October 2026 · baseline `e2f2a2e`.

This document replaces the direction of the [first interface study](design/everywhere/proposal.md). It is a product strategy and implementation map, not a claim that proposed capabilities already ship. [SPEC.md](SPEC.md) remains the current behavior contract. [PLUGIN-SPEC.md](PLUGIN-SPEC.md) owns the proposed plugin contracts. [ROADMAP.md](ROADMAP.md) owns delivery sequencing. This strategy connects those investments rather than introducing a competing roadmap or runtime.

## The decision

Make Upgrade a programmable Android home and an application for operating the phone's environments and remote computers. Users compose what they need from Android applications, native phone controls, shells, desktops, browser destinations, agents and Luau contributions. The same underlying resource can be reached from Home, a workspace, a widget or the normal app.

The competitive proposition is specific: **put a control or view of any supported computer beside the Android apps you use, then enter the original session without losing where you were.** An ordinary SSH host, a phone Linux installation and an Engine-equipped host have different abilities. They all remain useful.

A project is optional context. A workspace is a user-arranged place containing tools and views. A Home workspace for music, messages and a home server does not need a repository, a coding agent or a project record. A software workspace can bind those same mechanisms to a project.

The full target includes daily Android Home use, native app management, multiple Linux environments, remote operations, GUI access, browser access, agent control, authoring and distribution. Sequencing the dependencies below does not reduce that target.

## What the first study got wrong

- It substituted a decorated application dashboard for Android Home. The Android app drawer, application identity and ordinary app actions were barely represented.
- It used a large clock and repeated product names while hiding controls and active work. Neither is a required component of the new default.
- It treated projects and agent code review as the organizing principle for almost everything. This excluded useful personal, server, media and systems workspaces.
- It replaced the actual SSH sheet with a generic terminal panel. The sheet and parked shell bar are already distinctive interaction work.
- It treated Arch as the phone's Linux option, omitting the existing Ubuntu/Arch/Alpine and Nix work.
- It accepted the icon family without testing whether a person recognizes its meanings.
- It underused existing layout and Luau work, then called simple mock placement controls customization.

The earlier competitor investigation and device observations remain useful evidence. Its visual proposal is not the design baseline for this strategy.

## Existing work to build on

The statuses below distinguish repository/contract evidence from a fresh runtime test. No device test was run for this document. The earlier Faraday visit observed Home and recent Drops, not every capability below.

| Investment | Evidence already present | Strategic use | Remaining work |
|---|---|---|---|
| Numbered Home workspaces | `14e30cf`; SPEC “Home is split into numbered workspaces” | Use these as the starting layout system for both app and Android Home | Launcher integration, optional workspace names, additional contribution types |
| Tiling columns, drag placement and seam resizing | `4353c36`; `lib/features/home/home_screen.dart`; SPEC “Unfolded, the columns scroll and the page does not” | Users arrange operational tools in real available space | Extend to the target content types and preserve placement across Home modes |
| Per-card width ranges, docked or tiled input bars | `afa6aae`; SPEC “The capture bar is a panel, pinned above the nav” | Keep user-controlled sizing and composition instead of one mandatory dashboard | Clear context and supported sizing for each new contribution |
| Native plugins and Luau pages/cards | `155fce3` makes the agents card a built-in plugin; PLUGIN-SPEC inventory | Native features and authored integrations participate in the same composition model | Generic native capability adapters and attachment-aware contributions |
| Author tool and phone preview | `d6fc4dd`; `tool/upgrade_plugin.dart`; SPEC “A plugin workspace previews on the phone before it installs” | Extend the existing check/preview path | Current preview is fixture cards, not proof of live page, terminal or publish support |
| Android widgets | `5592258` improves size-dependent usage/send layouts; SPEC launcher widget section | Reach people who retain their existing launcher | General plugin-backed widget projection; different constraints from in-app rendering |
| SSH sheet and parked bar | SPEC shell-sheet, parked-bar and host-grouped tab sections | Primary command path across Home, machine management and workspace views | Consistent entry from the new contribution types; no duplicate terminal controller |
| Engine-independent terminal state | SPEC “A tab says what its program is doing, with no herdr and no engine” | Keep ordinary SSH useful; offer additional integration where available | Capability presentation must not conflate terminal state with structured agent control |
| VNC over SSH | SPEC “The host's screen rides inside its own ssh connection” | Remote desktop resource reachable from a host and a placed Home contribution | General placement and identity; a full VNC screen is not a Linux application window |
| Multiple phone Linux systems and Nix | SPEC “The phone is a host too, running Linux of its own”; `assets/linux/catalog.json` | First-class environments with independent lifecycle and tools | Better management UX, richer resource views and actual local GUI implementation |
| Engine and plugin service contracts | SPEC engine section; PLUGIN-SPEC execution, files, events and attachment contracts | Structured operations where supported | Existing services do not automatically become public plugin APIs or durable jobs |
| Existing code and diff sheets | SPEC workspace-sheet and diff-viewer sections | Inspect real files and results without replacing the current navigation model | Link resources and operations to their evidence |
| Native identity and icon grammar | `docs/icons.md`; SPEC appearance sections | Retain recognizable Upgrade character | Audit comprehension; revise confusing symbols rather than preserving them for consistency alone |

Recent commits are evidence that this is accumulated implementation work, not a blank canvas. Their inclusion is not a claim that every associated runtime scenario has passed on the current build.

## Product model

### Places, resources and views

| Object | What it represents | Example |
|---|---|---|
| Workspace | Arrangement and working context | Daily, Servers, Studio; current numbered spaces remain valid |
| Project | Optional body of work and related material | Upgrade repository and its references |
| Target | A registered remote host or phone Linux installation | Remote NixOS machine; phone Alpine installation |
| Resource | Something existing or explicitly created on a target | SSH shell, desktop session, process, service, browser destination, agent session |
| Contribution | A native or Luau-provided view/action | Media control, Git status, service list, shell entry |
| Instance | A placed and configured contribution | The same service widget on two hosts, with separate bindings |
| Operation | An action and its observed outcome | Start environment, run command, restart service, request cancellation |

These are conceptual distinctions. Reuse existing host, session, placement, installation and attachment identities. Do not create a new parallel registry merely to match this table. A resource reference must identify its actual host/session/provider; titles and positions cannot identify a running process.

A workspace can contain several targets. Opening a shell on one target does not silently retarget the other widgets. Opening a resource resumes the existing object where supported. Starting a new process is a separate action.

### Optional Engine is a capability gradient

| Target situation, overlapping | Useful product behavior | What the interface must not imply |
|---|---|---|
| Phone only | Android apps, native phone controls, capture, local plugin data | That every native capability is already exposed to Luau |
| Ordinary SSH | Existing shell, terminal input, supported file/code operations, configured SSH-carried services | That Engine installation is a prerequisite to connecting or using a terminal |
| SSH plus configured integrations | tmux/herdr operations; VNC when its server and SSH forwarding are available; other verified integration actions | That an executable name proves an Engine service, an accessible VNC server or a structured agent adapter exists |
| Engine installed | Advertised structured files, execution, agents and other available services | That every Engine revision supports jobs, subscriptions, deduplication or host Luau |
| Phone Linux | The same host interactions plus app-owned installation/start/stop/tool management; existing bundled Engine path | That PRoot supplies the kernel, service manager or isolation of a full Linux VM, or keeps jobs alive after the environment stops or Android kills its hosting process |

These rows overlap; they are not levels. Record target kind, advertised/configured integrations and operation lifetime separately. A remote job survives the phone disconnecting only when its execution contract provides that lifetime. Phone-hosted processes remain subject to their environment and Android process lifecycle even when Engine is present.

Show available actions on the host. Put missing capability explanations on the particular action that needs them. A host with no Engine should look like a useful SSH machine, not a broken installation.

The current generic plugin execution target in PLUGIN-SPEC uses Engine. This strategy does not silently invent a second remote plugin execution protocol over arbitrary shell text. Engine-free native SSH functionality remains; adding general Engine-free plugin execution would require a separate explicit contract.

## How Home competes

Oma's established strength in the earlier research is a coherent, editable local environment: Home, Linux, agents, themes, widgets and authoring. Upgrade has to meet that breadth. A stronger agent inbox alone does not answer it.

The proposed advantage is composable control across the phone and multiple computers. The Home page itself can contain useful operations and live or last-observed state, not merely links to those features inside the app. It also has to function as a normal launcher.

### Home arrangements with actual jobs

These are proposed target arrangements, not current Home capabilities. Current Home composes the existing native and Luau cards plus the input-bar contributions. Machine/resource cards, native phone controls, launcher apps and browser destinations require W3/W5/W7 and the relevant capability adapters. The arrangements are editable templates, not fixed product tabs or three mandatory modes.

| Arrangement | Content visible on Home | Immediate actions | What makes it useful |
|---|---|---|---|
| Daily | Pinned Android apps; media; chosen server/service state; a running local environment; compact captured material | Launch an Android app; pause media; open the server's shell sheet; resume an environment application | Personal phone use and computer control coexist without a project or agent |
| Servers | Named remote hosts; service/job views where supported; desktop preview; a browser destination; parked SSH sessions | Inspect a service, open logs, resume VNC, open a web console, enter a shell | Multiple remote machines remain individually identifiable and actionable |
| Build | Phone Ubuntu/Arch/Alpine environments; remote builder; browser preview; agent queue; files/diff | Start an environment, resume a command, inspect a change, open preview, answer a supported request | Local and remote work use the same composition and navigation, with truthful capability differences |

A clock can be an optional contribution. Product branding need not consume the working area. Useful content determines space: a shell or remote screen needs room; a status/action pair often needs one row.

Android app launching/search, folders or equivalent organization, shortcuts, work-profile identity, app information/uninstall routes and reliable Home/Back behavior are required parts of Home mode. Third-party Android widget hosting should be an explicit parity target. These are platform work, not capabilities supplied by a Flutter card layout alone.

### Three renderers, shared meaning

1. **Inside Upgrade:** native and Luau contributions use the existing renderer, placement model and navigation controllers.
2. **Upgrade as Android Home:** reuse the same repositories and contribution identities, with launcher-specific application and system integration.
3. **On another Android launcher:** a supported Android widget representation exposes a bounded snapshot and supported actions, deep-linking to the original resource.

Shared data and actions do not imply identical rendering. A native terminal, interactive canvas or full plugin page cannot be promised inside every external Android widget. Each contribution needs declared supported presentations. A fallback can show the target, current or stale state and an Open action without pretending to embed the full tool.

## Interaction model

### The SSH sheet is a main feature

A placed shell entry, host row, resource action or parked bar opens the existing full-height SSH sheet over the current Upgrade/Home context. Keep its host-grouped tabs, key bar, attachment flow, text input and selection. It is not another application page and not a tiny terminal preview pretending to be usable input.

Sequence: Home service view → open its host's shell → inspect output → drag the sheet away → return to the same Home arrangement → tap the parked bar to resume. Dismissing the sheet leaves the session alive. Closing a tab is an explicit session action. New shell still offers the supported login shell/multiplexer choice.

Preserve the current one resting height. The old contract rejected a half-height resting terminal for a reason. On an expanded device, a docked terminal contribution is a separate proposed presentation of the same session, with one input owner; it is not an excuse to rewrite the proven compact sheet.

This sheet can cover Upgrade's own app and Home activity. A system-wide overlay over arbitrary Android apps is a different capability, not implied by this plan.

### Workspaces arrange tools; they do not launch duplicates

Keep existing columns, seam resizing, width bounds and remembered placements. Add contributions to a chosen workspace. Bind the target explicitly when the contribution requires one. Resizing, reopening or moving a view changes presentation, not the underlying process.

Compact posture prioritizes a useful summary and one active detailed interaction. Expanded posture can show independently scrolling columns and side-by-side tools where their minimum sizes fit. Preserve the existing fit-based model rather than forcing a new breakpoint or permanent side rail.

### VNC, browser and local windows are distinct

| Resource | Entry and behavior | Capability boundary |
|---|---|---|
| Remote desktop | Home or host preview opens the existing VNC screen; return restores the workspace | Existing SSH-carried RFB path; VNC setup and SSH forwarding permission still required |
| Browser destination | A saved web address is associated with its target and optional connection dependency | External browser opening, SSH port forwarding and an embedded browser are separate delivery choices |
| Local Linux GUI window | Find and resume the original application window; expose its environment and lifecycle | Requires the GUI/backend investigation already in ROADMAP; cannot be claimed from a VNC desktop tile |
| Remote Android/emulator screen | Open the existing device screen controller | Keep its provider identity and input model; do not call every screen VNC |

For a web service bound to a remote loopback port, propose a named tunnel resource carrying host and remote endpoint. Show whether the connection is available, which client needs it and what stopping it affects. Do not equate the VNC forwarding implementation with an existing general-purpose port manager. Browser cookies/authentication and tunnel lifetime need their own implementation decision.

### Native app and remote management have different powers

The Android app inventory should support launch/search, shortcuts, profile distinctions and available system management actions. It does not imply arbitrary silent installation or control inside third-party applications.

The machine inventory should show connection identity, local environment lifecycle where applicable, available integrations, tools and observed services/jobs. Plain SSH can always lead to the command path. Rich structured controls appear only through supported native integrations or advertised Engine/plugin capabilities.

For managed applications on a remote host, distinguish inspecting, launching, reopening a known session, stopping a process and uninstalling a package. These cannot share one ambiguous play/close icon.

## Luau is the customization mechanism

The existing package, attachment, contribution and instance model is the core investment. Expand it so users and agents can compose the controls they actually need. A built-in card should not gain a private privilege merely because it ships with Upgrade; native features can supply typed capabilities and native view contributions that Luau can request where supported.

Example: install a service-view plugin once, attach it to two Engine-equipped hosts, place one aggregate overview on Servers and a detailed view for one host beside its shell. A phone-only media plugin on the same page uses native phone capabilities. Neither infers its target from whichever shell was last focused.

The authoring loop extends `init`, `docs`, `check` and phone preview: describe → generate/edit → validate → fixture preview → selected live target preview → install/update → place → publish/share. Record which stages already work. Fixture-card preview is an asset to extend, not a finished live authoring system.

User layout edits and agent-authored layouts should target the same versioned model. Preview a candidate against actual contribution sizes and context bindings, then apply it. Export templates with unresolved target slots rather than embedding a user's machine addresses or credentials. Installing a template resolves those slots to registered hosts/environments.

## Linux distributions, Nix and NixOS

Phone Linux already supports independent Ubuntu, Arch and Alpine installations, including several installations of the same distribution. The existing Nix option supplies packages/tool compatibility in those environments. Build management around that actual model: installations, tools, storage, running resources and independent start/stop/remove.

The repository already exports `nixosModules.upgraded`, `darwinModules.upgraded` and `homeModules.upgraded`, plus Engine packages and scenario VMs. Declarative Engine ownership is existing work, not a new installer idea. Build on those modules and retain the owner-managed configuration model.

Three distinct opportunities:

| Area | Proposed product experience | Boundary |
|---|---|---|
| Nix inside phone Linux | Open a reproducible development environment; expose its command, tool set and execution state in a workspace | Existing Nix installation does not prove every flake/package works under PRoot or on arm64 |
| Remote NixOS management | Extend existing declarative Engine deployment with a plugin that inspects configuration/generations and prepares a declared change; show build/activation output and recovery choices | New integration requiring supported operations, privileges and target verification; not already built |
| Remote builds for phone work | Select a capable remote builder for an appropriate job; retrieve/view results on the phone | Architecture, build configuration and artifact transfer must be explicit; no promise of transparent universal offload |

Do not rename “Nix installed in Alpine” to “NixOS on the phone.” A full NixOS VM or device OS port is a different execution model. Full systemd/service/boot semantics cannot be inferred from PRoot. NixOS is a concrete remote-management opportunity without making that false claim.

## Visual strategy and icon comprehension

The aesthetic should make useful composition legible. Keep the established type, strong alignment, neutral contrast and sparse active color. Improve the arrangement and recognizable controls before adding a new theme or visual effect.

Home should show real application identities and real resource content. A desktop preview looks like a desktop. A terminal shows useful output or a clear named entry. A process/service view shows its target, meaningful state and available action. Different information should not become identical generic cards with different headings.

The icon grammar is a starting asset, not proof of comprehension. Review the task distinctions people must make: Shell, Files, Browser, Desktop, Device screen, Apps, Plugins, Jobs, Run, Resume, Stop and Remove. Use text labels for ambiguous actions and mixed resource launchers. Preserve familiar application/vendor marks where allowed; a custom symbol should not erase recognizable application identity.

Concrete icon study: collect the current glyphs and proposed alternatives, show them at actual 20–24dp size, and ask unfamiliar users to choose actions in task context. Record confusion pairs, first-choice accuracy and wrong destructive-action choices. Replace the confusing meanings, not necessarily the whole family. Candidate criterion: at least 90% correct first choices in the labeled task test, with no Run/Resume/Stop/Remove confusion; this is a proposed acceptance target, not measured evidence.

The next visual review should compare equally populated Home arrangements and real interaction sequences. No landing-page framing, oversized clock, branding hero, decorative metrics or fake terminal output as the main product evidence. Aesthetic preference remains a user evaluation; it cannot be proved by a synthetic interaction test.

## Concrete delivery packages

These are work packages under the existing roadmap. They define outputs and dependencies, not estimates or completion claims. Build them in parallel where dependencies allow.

| Package | Concrete output | Existing foundation | Depends on | Acceptance demonstration |
|---|---|---|---|---|
| W1 Capability inventory | Per-target available actions and reasons for unavailable ones | Host integration/probes and Engine service discovery | Source/runtime inventory | Ordinary SSH, herdr-only, Engine-equipped and stopped phone hosts all show truthful different capabilities |
| W2 Resource entry and continuity | A reusable open/resume path from contributions to original shells/screens/files | Existing shell, screen and code controllers; opaque session proposal | W1 for optional actions | Open one shell from two entries; same tab; dismiss and resume; ended session is not silently recreated |
| W3 Workspace composition | New native resource contributions in current tiling layout | Numbered spaces, placements, width ranges, column weights | W2; plugin context work | Daily/Servers/Build arrangements with explicit mixed targets survive resize/restart |
| W4 Engine-backed plugin operations | Attachment-aware execution/files/events and reconciled jobs | PLUGIN-SPEC P2/P3, existing Engine services | Existing plugin contract milestones | Same plugin on local and remote targets; disconnected result remains unknown until reconciled |
| W5 Android Home | Normal launcher operations plus the shared workspace model | W3, existing app/widget bridges | Native app inventory and Home lifecycle | Use ordinary Android apps, profile copies, shortcuts and widgets; return to the chosen workspace after reboot |
| W6 External widgets | Declared compact representations of supported plugin/native state | Existing BAR/SEND/USAGE providers | Shared observation/action references | Keep another launcher, observe target state and open the exact resource without a duplicated job |
| W7 Browser and connections | Saved browser destinations and explicit tunnel management | SSH transport experience, existing link opening | Transport/identity design; W2 | Open a remote loopback web service, lose the connection, show the failure, recover without changing target |
| W8 Local applications | Actual Linux GUI window lifecycle and app discovery | Existing multi-distro installations; roadmap backend investigation | Feasibility result and W2 | Resume a GUI window after backgrounding; stopping its environment shows an ended resource |
| W9 Authoring and templates | Live preview, diagnostics, install/update, placement and sharing | `d6fc4dd`, PLUGIN-SPEC authoring work | W3/W4 and supported contribution adapters | An outside author creates, fixes and installs a useful multi-target control without modifying app source |
| W10 Environment and remote management | Better distro/tool management; Nix environment and NixOS integration candidates | Linux catalog/lifecycle; host operations | W1/W4; integration-specific capability proofs | Two local distributions remain independent; a supported remote NixOS operation has attributable output and outcome |
| W11 Recognition and density | Tested action labels/glyphs and populated layout comparisons | Existing design system and icons | Run alongside all packages | Users find shell, desktop and app actions without decoding a symbol legend; compact controls remain readable |

W2/W3 should be the first integration proof because they establish whether existing tools can become a composed environment. W5, W7 and W8 remain required ambitions and can have parallel feasibility work. Do not spend the whole program polishing another agent overview while launcher and GUI capabilities remain absent.

## Demonstrations that can support a competitive claim

1. **Home to real shell and back:** an ordinary SSH host with no Engine; open its shell from Home, use the key bar, switch host groups, dismiss, resume the same session. Keep Android apps available throughout.
2. **Mixed-machine Home:** a phone-native media control, an Alpine environment, a remote service widget and a VNC entry in one editable workspace. Each acts on its named target; one offline target does not break the others.
3. **Browser plus command:** open a remote service's browser destination, return to its logs/shell, stop the tunnel, show the dependent view's state. No hidden association with the last-used host.
4. **One plugin, different computers:** attach the same release to two supported environments; place different instances; update the package without losing placement or binding.
5. **Author without app source:** build a personal control with an agent using the existing author workflow, diagnose a bad layout, preview on the phone, install and share a template.
6. **Linux environment management:** start Ubuntu and Alpine independently, use a Nix-provided tool where supported, stop one environment and observe only its resources end.
7. **Real window lifecycle:** local GUI application, Android app switch, resume the original window, then inspect the honest result of environment termination.

Run equivalent supported tasks on a pinned competitor version and comparable hardware. Record action count, completion time, errors, recovery behavior, sustained performance and what cannot be attempted. Ask users to compare visual clarity using equally populated arrangements. Do not infer an overall win from a feature count, repository inspection or an attractive mock.

## Decisions carried forward and decisions still needed

Carried forward: local-first ownership; optional Engine on remote hosts; ordinary SSH; the shell sheet/parked bar; multiple independent phone environments; current Luau runtime and package identity; existing placements and width-based layout; capability negotiation and truthful unknown outcomes.

Recommended additions to specify when implemented: full Android Home reuse of the layout model; native resource contributions; generalized external widget representations; browser/tunnel resources; environment application discovery; useful Nix/NixOS integrations; recognition-driven revisions to ambiguous icons.

An embedded browser would also change the current SPEC decision that link content opens outside the app. Browser/tunnel work must explicitly resolve that decision; it is not silently approved as current behavior by appearing in this strategy.

Still requires an implementation decision: local GUI backend; browser embedding versus an external client for each use case; how an in-app live resource is represented in external Android widgets; terminal input ownership across multiple views; which rich operations are available without Engine. The strategy identifies these decisions instead of pretending a screen mock settles them.

## Evidence and limits

- Current repository baseline and recent commits listed above; current SPEC, PLUGIN-SPEC and ROADMAP. Their planned sections remain planned.
- Earlier Faraday inspection: 123 Drops and a dominant raw-list arrangement, plus recent ideas about projects, canvas, kanban, machine setup, attachment handling and reconnect behavior. Only recent entries were sampled. They were not edited. This visit is not evidence of every current layout configuration or latest behavior.
- Earlier [Oma video](https://x.com/devsec_ai/status/2113403750371278911) inspection and [source at 1c07b78](https://github.com/SimonSchubert/omalauncher/tree/1c07b78bda7a494238a6c9e75d6f986a36068aec). The clip and the inspected source have different versions. No new competitive runtime benchmark was performed for this strategy.
- The first browser prototype demonstrated simulated state changes only. It cannot establish native capability, performance or comparative superiority.

This document is ready to turn into implementation specifications package by package. The next product artifact should prove the shell/resource composition and genuine Android Home interactions described here, with the existing implementation as its starting point.

## Source audit: exact foundation and gaps

A Claude source audit resolved the `upgrade` code graph first, then read implementation and tests. The second Claude reviewed the product scenarios against the prior contracts. The lead used their evidence but rejected two overclaims from the scenario critique: that machine-bound Home compositions already exist in full, and that capabilities form a simple ladder ending in guaranteed durability. They do not. Attachments/instances still need implementation; durability depends on the advertised operation and runtime.

“Coverage present” below means test source was found. No test suite was executed for this documentation task.

| Area | Implementation evidence | Coverage found | Concrete boundary |
|---|---|---|---|
| SSH sheet | [shell_sheet.dart](../lib/features/shell/sheets/shell_sheet.dart), [parked_shell_bar.dart](../lib/features/shell/parked_shell_bar.dart), [shell_header.dart](../lib/features/shell/shell_header.dart) | Shell sheet, parked bar, tabs and host-switch tests | Reuse these controllers; do not replace the sheet with the prototype's terminal page |
| Engine-absent shell | [shell_tunnel.dart](../lib/platform/shell/shell_tunnel.dart) | `test/platform/shell/shell_tunnel_test.dart` fallback cases | Actual fallback path includes Engine shell transport, Mosh and plain SSH; capability combinations are not a linear upgrade tier |
| Engine-absent files and code | [host_files.dart](../lib/platform/ssh/host_files.dart), [workspace_commands.dart](../lib/platform/workspace/workspace_commands.dart) | Host-files and workspace parsing tests | Native fallbacks exist; this does not authorize arbitrary new plugin host execution |
| Terminal program status | [program_status.dart](../lib/features/shell/session/program_status.dart) | Program-status tests | OSC status does not imply a structured agent API |
| Herdr without Engine | [herdr_client.dart](../lib/platform/herdr/herdr_client.dart) | Client/socket tests | Forwarded Unix socket integration is independent of Engine hook services |
| VNC | [vnc_tunnel.dart](../lib/platform/vnc/vnc_tunnel.dart), [rfb_client.dart](../lib/platform/vnc/rfb_client.dart) | VNC and screen tests | Current destination is fixed at remote `127.0.0.1:5900`; general port configuration is additional work |
| Device screens | [device_link.dart](../lib/platform/devices/device_link.dart), [device_float.dart](../lib/features/devices/device_float.dart) | Device-link and device UI tests | Screenshot-based transport; no scrcpy-class streaming found; simulator control and device typing are not general current capabilities |
| Browser | [browser.dart](../lib/platform/links/browser.dart) | Not established by this audit | External application launch only; no embedded browser or user-managed forwarding inventory found |
| Layout persistence | [plugin_placement_repository.dart](../lib/data/repositories/plugin_placement_repository.dart), [plugin_placements.dart](../lib/application/plugins/plugin_placements.dart) | Placement migration, widths, columns and workspaces tests | Existing versioned JSON in `plugins/placements.json`, not Drift tables; preserve its data when adding instances |
| Luau capabilities | [manifest.dart](../lib/platform/plugins/manifest.dart), [plugin_sdk.dart](../lib/platform/plugins/plugin_sdk.dart), [plugin_hosts.dart](../lib/application/plugins/plugin_hosts.dart) | Plugin and Luau tests | Host services currently expose hosts/scheduler/agents; generic execution/files/events and host Luau remain target work |
| Author preview | [plugin_development.dart](../lib/application/plugins/plugin_development.dart), [plugin_check.dart](../lib/platform/plugins/plugin_check.dart), [upgrade_plugin.dart](../tool/upgrade_plugin.dart) | No direct author/check test references found in this audit | Fixture cards over SSH; no candidate install, full page/host-effect preview or publication proof |
| Android widgets | [LauncherWidget.kt](../android/app/src/main/kotlin/dev/luisnquin/upgrade/LauncherWidget.kt), [launcher_widget.dart](../lib/platform/launcher_widget/launcher_widget.dart) | Dart bridge/feed/send tests | Three native providers; no generic plugin representation, Home role or third-party widget host found |
| Phone environments | [catalog.json](../assets/linux/catalog.json), [PhoneLinux.kt](../android/app/src/main/kotlin/dev/luisnquin/upgrade/PhoneLinux.kt), [phone_linux.dart](../lib/application/phone_linux.dart) | Catalog, application and picker tests | Independent distro instances and optional Nix; GUI/GPU/per-window Android tasks remain absent |
| Declarative host integration | [flake.nix](../flake.nix), [options.nix](../nix/engine/options.nix), [scenarios.nix](../nix/host-vm/scenarios.nix) | No flake `checks` output found in this audit | Existing NixOS/Darwin/Home Manager modules; not an existing NixOS management UI |

The audit did not establish live-device reliability, every absence across dependencies, or current benchmark performance. Its negative findings are scoped to this repository baseline. Historical test files are useful evidence of prior investment, not proof of a fresh passing run.

## First implementation specification to prepare

Prepare W2/W3 around **one native host/resource contribution in the existing Home layout**, with the ordinary SSH path as the first concrete case. This is an integration task inside the full program, not a replacement product scope.

- Place a host contribution in an existing numbered workspace using the current columns and width constraints.
- Show available entry actions from that host's actual integrations: shell, files/code, desktop and devices where supported.
- Open the existing shell sheet. Leave it by its existing dismissal gesture. Resume through the parked bar. Preserve workspace scroll, placement and shell identity.
- Place a second host view without duplicating the underlying session or silently changing the first view's target. Identify what requires the planned instance model instead of faking it with copied packages.
- Carry observation age and the relevant unavailable state; do not make a stopped phone environment start merely because its card becomes visible.
- In parallel, produce separate feasibility evidence for Android Home role/app inventory, generic web forwarding and the local Linux GUI backend. Each feeds W5, W7 or W8 rather than becoming a decorative mock.

Use the existing `bare`, `herdr`, `engine` and `declared` VM scenarios as the remote capability matrix. Use at least two phone Linux environments for local identity/lifecycle. `bare` proves SSH usefulness without Engine; `herdr` proves integration independence; `engine` proves advertised rich operations; `declared` proves the owner-managed configuration path. The scenario's existence does not mean these acceptance runs have already happened.

W2/W3 reuse the existing connection supervisor and its lifecycle policy. Placing another view of a host does not itself require another connection or a second retry mechanism.
