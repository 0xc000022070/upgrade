# Upgrade roadmap

Updated 2026-10-21. This file owns the release sequence and competitive delivery program. [PLUGIN-SPEC.md](PLUGIN-SPEC.md) owns the detailed plugin contracts. [SPEC.md](SPEC.md) remains the current product contract. Planned work below changes that contract only when its implementation lands. All new competitive milestones are pending.

## Product position

Upgrade should be the local-first mobile workbench for coding agents and the machines they use. The phone is both a control surface for remote work and, on Android, a host that can run Linux and agents. Projects, hosts, shells, agent state, approvals, code, and device screens belong in one place.

The first competitive releases focus on reusable plugins across phone Linux and remote hosts, with a complete authoring workflow for users with coding agents. The broader program also covers Android Home, customization and local Linux windows. These are later, separately gated milestones. The ordinary app remains usable without choosing it as the default Home application or installing phone Linux.

The earlier blanket deferral of authored layouts, Android Home and Linux desktop work is superseded by this sequence. Upgrade keeps its own visual identity. Scope is functional capability and user outcomes; copying OmaLauncher's themes, branding or implementation is not a release objective.

### What competitors prove

| Product | User expectation it sets | Upgrade response |
|---|---|---|
| [Moshi](https://getmoshi.app/docs/install) | Easy Pair gets a host connected with a command and QR. SSH, Mosh, durable sessions, and agent hooks make remote work usable from a phone. | Make first connection and session recovery simple. Then show project, agent, code, and device context in the same app. |
| [OmaLauncher](https://github.com/SimonSchubert/omalauncher) | Agent-assisted authoring, real previews, useful discovery, deep home customization and local Linux windows. | Match the authoring/discovery workflow; deliver explicit multi-host attachments, reusable instances and recoverable jobs; then close the Home/desktop gaps under their own gates. See the [source-backed assessment](PLUGIN-SPEC.md#competitive-assessment-and-remaining-gaps). |
| [Happier](https://github.com/happier-dev/happier) | Users want one mobile client for agent sessions across several runtimes and machines. | Keep Upgrade’s project, host, code, approval, and device context attached to the session. Add adapters where users ask for them. |
| [OpenMinis](https://github.com/OpenMinis/OpenMinis) | Users want agents to run on the phone and use native phone tools. | Treat Android phone-host Linux as a strength. Add native phone capabilities after the remote and local session loop is reliable. iOS needs its own supported implementation. |
| [Omarchist](https://github.com/tahayvr/omarchist) | People want reusable, reviewable automations and a community catalog. | Deliver a reviewed static catalog with immutable packages and visible access changes. Design reusable flows after job cancellation and recovery. Publisher signatures remain a separate enhancement. |

Do not use GitHub stars as the success measure. Track installs, successful first sessions, return use, and outside contributions.

## Current foundation

These are already in Upgrade’s contract or implementation. Recheck them in a release build; do not schedule them as new features from stale competitor notes.

- The app is single-user and local-first, with no account, backend, cloud, or sync today. See [the product contract](SPEC.md#what-it-is).
- Android can host Linux distributions and install multiplexers and coding agents. See [Linux on this phone](SPEC.md#the-phone-is-a-host-too-running-linux-of-its-own).
- Android launcher widgets can open the app, show agent usage, and send prompts. See [the launcher widgets](SPEC.md#the-launcher-carries-three-widgets-a-door-to-the-input-bar-a-send-and-the-plans-usage).
- Upgrade has SSH and Mosh sessions, host and project context, agent status, approvals, transcripts, code and diff views, remote device screens, and a capability-based plugin system.
- An agent conversation does not send a follow-up prompt. The current contract sends the user to the agent's shell or pane. See [the conversation decision](SPEC.md#a-session-reads-as-a-conversation-from-the-transcript-the-agent-already-writes).
- Agent terminal tabs already have a composer and dictation path. Extend and prove that path instead of scheduling a second composer. See [terminal composition](SPEC.md#voice-dictates-and-an-agents-tab-gets-a-composer).
- A sealed bundle already exports app data and keys, excluding phone Linux. Extend its coverage and identity rules for the new plugin model. See [the bundle](SPEC.md#a-bundle-carries-the-phone-to-another-phone).

The last point limits the product claim. Do not market Upgrade as full chat-based control of every agent until the contract and implementation support it.

## Release target

The first release must show one complete job, not a long feature list:

1. Connect to a supported host or start the Android phone host.
2. Open a shell or start a supported coding agent.
3. See what the agent is doing and answer a real approval request.
4. Inspect the resulting code change or remote screen.
5. Return after a network interruption without losing the session.

Goal for a prepared, supported host: first shell in under five minutes and first agent task visible in under ten. Measure this with people who did not build Upgrade. If setup misses the target, improve setup before adding broad features.

The launch demo should show the same flow on the phone itself and on a remote host. The local Linux host is the clear answer to “why this app instead of a mobile SSH client?” The agent inbox, code view, and device screen show why it is more than a launcher.

## Stage 1: make public release safe

These are release blockers. The previous release audit was checked through 2026-10-12. Revalidate its unchecked items against the current tree before marking them done.

- [ ] Choose the app license. There is no root `LICENSE` file as of 2026-10-19. Align the app, `pubspec.yaml`, and `engine/Cargo.toml` declarations.
- [ ] Resolve third-party licensing, especially the `dart_mosh` relationship to Mosh. Keep required upstream notices and generate a complete dependency list.
- [ ] Review design references and explorations for artwork the project cannot redistribute. Keep private reference material out of the public source tree and Git history.
- [ ] Audit current files and full Git history for secrets, private host topology, device identifiers, and personal paths. Removing a file at HEAD does not remove old history. Decide whether to publish this history or prepare a cleaned repository before changing it.
- [ ] Confirm test keys and host keys authorize only disposable fixtures. Keep release signing keys outside the repository and document backup and version-code handling.
- [ ] Confirm the Android application ID and public name before the first store build. The current application ID is `dev.luisnquin.upgrade`.
- [ ] Publish a stranger-ready README, install steps, supported-host requirements, troubleshooting, privacy statement, security contact, and contribution guide.
- [ ] Decide the first distribution route: GitHub release, Play testing track, or both. Keep local screenshots and captures with personal host data out of public artifacts unless reviewed and redacted.

## Stage 2: remove first-session friction

Moshi’s clearest advantage is first connection. Its current setup guide uses a host command and QR, then adds agent hooks after the first terminal works. Upgrade should answer the same user need without hiding what runs on the host.

- [ ] Give a fresh install a clear first-host path, useful empty states, and exact SSH, Mosh, VPN, and agent prerequisites.
- [ ] Add a copyable public-key install command to key details and the `KEY REJECTED` state, then let the user retry. This keeps the current rule that Upgrade does not write `authorized_keys` itself.
- [ ] Explain host-key verification in plain language before the first connection. Never send a password before the host key is trusted.
- [ ] Test the full setup with non-authors on a fresh emulator and supported guest. Record time to first shell, time to first visible agent, and where people need help.
- [ ] Document the Android phone-host path, expected download size, battery and heat limits, and which agents work on each Linux distribution.

Product decisions, not assumed work:

- A one-time password bootstrap that writes the app’s key to `authorized_keys` conflicts with the current spec. Decide whether that trust tradeoff is worth a spec change.
- QR pairing that installs a key also needs a trust and host-side execution design. It is not a small UI task.
- Private-key import could help people moving from another client, but it changes the current phone-generated-key model. Keep it separate from the first release unless users show it blocks adoption.

## Stage 3: prove reliability and fix visible friction

The connection supervisor needs evidence on the project’s Android emulator and supported VM scenarios. The follow-up note had not recorded this run as of 2026-10-12.

- [ ] Verify SSH, Mosh, and Engine sessions across sleep, network changes, a dropped control connection, and app resume. Include a slow login, a half-open connection, a network change during paste, and slow pinentry.
- [ ] Verify multiple tabs and the agent watcher share a host connection without breaking each other. A dropped link must show a stale state and recover; a wrong key must fail clearly without retry.
- [ ] Verify the engine exits cleanly if its SSH caller disconnects while a response or diagnostic is being written. A closed stdout and stderr must not abort or leave a core dump.
- [ ] Re-measure scrollback memory and catch-up traffic on the current Upgrade build. The 2026-10-12 measurements showed about 64 MB RSS per live tab, 84 MB peak, and repeated keyframes could resend more data than a wrapped-output flood produced. Do not make performance claims from those old numbers.
- [ ] Verify an approval can be answered from the phone and that a timed-out approval is no longer actionable.
- [ ] Recheck the old folded-device findings on the current Upgrade build. The device bubble was still able to cover ordinary controls such as Edit and New. It must not block a common action.
- [ ] Recheck code `Next Change`. The old audit marks its sideways-scroll bug fixed; confirm that the line number and start of the changed line remain visible.
- [ ] Check compact and expanded layouts, keyboard handling, first-run empty states, and plugin controls on current emulator builds.
- [ ] Make session cards readable without relying on mostly black terminal thumbnails. Keep host, agent, and current activity visible.
- [ ] Review the Drops search label, plugin layout controls, device-preview resize affordance, and Back behavior from plugin management. Keep changes consistent with `SPEC.md`.

Do not treat old screenshots from the Dazzle-named build as proof for the current Upgrade release. The old audit did not exercise fresh SSH authentication, restart persistence, agent takeover, destructive saves, or accessibility.

### Development-loop items

These affect contributors and emulator automation, not the product’s public feature set. Keep them visible, but do not hold the app release for them unless they block the validation above.

- The `phone` CLI has trouble targeting Flutter text fields. The existing host-fixture helper avoids that path for SSH setup.
- Emulator voice tests lack a repeatable microphone-audio source. Current coverage checks draft state and the empty-audio path, not Android speech recognition end to end.
- A clean development machine builds the host VM closure on first boot. A binary cache or prebuilt closure would reduce contributor setup time.

## Stage 4: make the release easy to understand

- [ ] Prepare one short demo: start or connect to an agent, show its state, handle an approval, inspect a code change, and return after a connection interruption.
- [ ] Show phone-host Linux as a first-class capability in setup and release material, not as a buried technical option.
- [ ] Use real, scrubbed screenshots from a current Upgrade build. Show compact and expanded layouts only where each helps the workflow.
- [ ] Write an install guide for a developer who has never used Upgrade. Separate the fast supported path from optional Mosh, Herdr, and engine setup.
- [ ] Make the first release’s limits clear: Android first, local-first, and only the listed agent integrations. Do not promise iOS parity or cloud relay.

## After the first release

The competitive delivery program below replaces the previous unordered feature list. Share intake, agent control, the catalog, phone capabilities and richer layouts have assigned milestones. Additional agent adapters follow demonstrated needs and publish their support level. Reusable flows follow the execution/recovery contract; their first design must specify cancellation, partial failure, logs and ownership.

## Competitive delivery program

### Outcomes and release order

The scope is Android first. A product milestone is complete only when its stated outcome works in a release build and its evidence is recorded. The plugin work-package IDs below link to [their dependencies and contracts](PLUGIN-SPEC.md#work-packages-and-dependencies). They are planning identifiers, not versions already shipped.

| Milestone | User outcome | Required work | Exit criterion |
|---|---|---|---|
| R0: reliable daily work | Connect locally or remotely, work with an agent and recover the same session | Existing public-release stages; current implementation inventory; baseline measurements | Outside users complete the release target; unresolved first-session/data-loss blockers have an owner and are fixed before release |
| R1: useful plugins and first creation | Find/install/manage a real plugin and ask an agent to change a working phone-only example | P0, P1; minimum supported development session and SDK distribution | A fresh user finds an installed custom package after a cold offline launch and creates a real preview without reading app source |
| R2: one plugin across machines | Attach to phone Linux and remote hosts, place independent instances, operate live sessions and jobs | P2, P3, P4, P5; five reference packages; scoped backup behavior | Same package works across prepared targets; update preserves each instance; reconnect finds the original job/session; an outside author publishes a validated candidate |
| R3: adaptable phone workbench | Use phone data/actions, authored pages, themes and recoverable personal layouts | P7; phone integration inventory; layout/theme schemas; share intake and bundle extensions | Permission changes, large text, interrupted import and a broken layout all have recoverable outcomes; an agent can edit a page using public SDK/docs |
| R4: Android Home and Linux desktop | Use Upgrade as Home and return to individual local Linux windows | Home workstream; desktop feasibility result and selected backend; native input/window APIs | Each listed Home/desktop task passes on the declared device matrix; software rendering works without GPU support |
| R5: comparative release | Demonstrate advantages across the agreed capability matrix | All required rows below; repeated matched comparisons; current competitor recheck | Measured results support each claim; unsupported or untested rows remain visible and prevent an "every aspect" claim |

P6, host-side Luau, follows the P3 engine/runtime contract. It may progress beside R3/R4, but must pass its own local/remote execution and lifecycle scenarios before being advertised. R2 can use installed tools through the engine without waiting for it.

R0 recovery work and P0 can progress together. P1 discovery and P2 attachment storage can progress independently after shared identity/schema decisions. Home and desktop feasibility work can start earlier, but their production delivery must not consume the first usable authoring loop. There are no calendar estimates until each work package has an owner and a scoped implementation plan.

### Coverage matrix

Every row starts pending. Existing code can satisfy part of a row after verification; a plan or screenshot alone cannot close it. Broad superiority requires all required comparison rows. A product can ship R1 or R2 while later rows remain openly incomplete.

| Area | Target | Required proof | Milestone |
|---|---|---|---|
| Discovery | Match preview/search/category quality; support independent sources and direct installs | Fresh install, cached/offline catalog and source failure | R1 |
| Installed inventory | Include built-in, custom, disabled, development and delisted packages | Local inventory survives cold offline restart and source removal | R1 |
| Authoring with agents | Full create, preview, fix, install, update and publish loop | Outside authors using at least two supported agent setups, with no app-source access | R1 small loop; R2 complete loop |
| Host coverage | Explicit multi-host/workspace attachments across phone Linux and remote hosts | Same release on two phone environments and a remote host; one target offline | R2 |
| Instance management | One package, independently configured views | Several instances survive package upgrade without source duplication | R2 |
| Execution and live data | Owned jobs, bounded streams, truthful delivery/cancellation and recovery | Lost response, cursor expiry, phone process death and remote continuity | R2 |
| Agent control and terminal input | Open original work, compose follow-ups, expose supported adapter actions | IME, paste, dictation, physical keys, session-ended and delivery-unknown scenarios | R2, extended in R4 |
| Phone integrations | Native data/actions with declared support and permission states | Permissions denied/revoked, background limits and unsupported platform behavior | R3 |
| Layout and themes | User and agent customization through recoverable schemas | Edit, preview, export, import, migration and last-good fallback | R3 |
| Android Home | Daily launcher operations and plugin-backed pages | Launch/search, profiles, shortcuts, folders, gestures, Back and restart | R4 |
| Linux windows | Local GUI windows, discover/reopen, native input, clipboard and display handling | Existing window recovery, software rendering, monitor/keyboard scenarios | R4 |
| GPU support | Acceleration where advertised, with correct fallback | Actual render output and driver failure on each supported device family | R4 hardware sub-gate |
| Reliability and portability | Setup, upgrades, bundles, recovery and clear support limits | Fresh device and interrupted-operation scenarios; no data/session misattribution | R0 and every milestone |
| Performance and accessibility | Responsive UI and usable controls under representative loads | Device measurements, screen-reader tasks, text scaling and keyboard navigation | Every milestone; compared in R5 |
| Distribution and ecosystem | Usable downloads, documentation, catalog maintenance and outside packages | Clean-machine author setup; independent publication and update; support reproduction | R1 through R5 |

### Authoring and ecosystem workstream

The primary author is a user working with a coding agent. R1 must provide a visible `CREATE WITH AGENT` entry, a working template, pinned SDK context, a checker and a real preview. R2 adds host templates, live sessions, diagnostics, candidate install/update and publication. Setup explains the authoring machine, runtime targets and preview phone separately.

Package the author CLI for the development environments used in the supported path: phone Linux on arm64 and a Linux remote development host. Publish exact installation instructions and supported architectures. Add other author platforms when their binary/package and preview transport are exercised. A link to an unbuilt tool is not a completed onboarding step.

Maintain five public reference packages from the plugin spec. Give the catalog a source repository, a release process, maintainers and a support route. Review notes identify the exact release. A removed source does not hide an installation. Independent sources and local development remain usable without a Upgrade account.

Documentation includes a ten-minute guided exercise for a prepared environment, a troubleshooting path and complete machine-readable API help. The time is a target to measure, not a promise that downloads or arbitrary agent work finish within ten minutes. Collect failed author steps and repair the SDK/docs before increasing catalog breadth.

### Phone integration workstream

Reuse native implementations already present. Publish a capability table covering the following groups, with OS support, required user configuration, state transitions and limits. Platform policy restrictions must appear as concrete unsupported states.

| Group | Planned user capability | Minimum acceptance |
|---|---|---|
| Work intake | Share text/images/files into a selected project and agent; select documents and capture an attachment | Destination remains explicit; cancel preserves the original draft; URI expiry is explained |
| Phone status | Battery/charging, connectivity and device facts useful to widgets | Event-driven updates where available; no hidden high-frequency polling |
| Media and alerts | Playback state/control, volume, notification data/actions, next alarm and applicable device modes | Denied/revoked permission and unavailable actions leave the rest of the widget usable |
| Android applications | Installed apps, launch, pinned shortcuts and supported profile identity | Duplicate app names and work-profile copies launch the selected identity |
| Phone UI actions | Clipboard, document picker, share sheet and scoped notifications | Each action has a visible result or failure and respects the active invocation |

Expose capabilities through versioned plugin adapters. Keep broad notification access separate from posting Upgrade's own notifications. Background observation follows the existing connection/notification policy until a specific target contract changes it. R3 cannot claim an always-running phone agent or watcher on the strength of a foreground demonstration.

### Customization and Android Home workstream

R3 starts inside the app. Deliver named pages composed of installed contributions, stable instance placement, supported size rules, theme previews and exportable templates. Use one versioned layout model for touch editing and agent editing. Validate changes before activation, retain the last valid revision, and show the offending field on failure. Removing a layout does not uninstall its packages or delete their data.

Theme customization uses Upgrade's tokens and semantic roles. It covers app chrome, plugin controls, syntax and terminal palettes through explicit profile choices. This extends the current HOUSE/SYSTEM contract; that contract remains unchanged until implementation. Preview readability, focus, disabled states and errors in every supported theme. Styling cannot hide the route to reset a broken layout.

R4 adds an optional Android Home mode using the same package, instance and layout repositories. Required behavior includes app search/launch, pins, folders, app shortcuts, work-profile distinctions, configurable gestures, wallpaper handling and returning from another app. Plugin failure leaves a minimal working app launcher and settings route available. Installing Upgrade or a plugin never selects it as default Home implicitly.

The Home acceptance run includes reboot, app install/uninstall, profile availability changes, an invalid custom page, large text, keyboard open/close, and changing the default launcher away and back. The ordinary Upgrade app must remain usable throughout. Custom keybars and app-drawer/panel composition follow this workstream's schemas; they cannot depend on an unrestricted renderer bypass.

### Linux desktop and session workstream

The first desktop task is a bounded feasibility implementation with a written decision. Compare an embedded existing display/backend with a compositor-based approach against the same requirements: local PRoot compatibility, individual window identity, rendering correctness, native input, license/maintenance cost, memory and device coverage. Prefer reuse where it meets the requirements. Neither choice is settled by this roadmap.

The investigation must produce a real local Linux GUI window, clipboard round trip, keyboard/pointer input and recovery of the same window after backgrounding. Stop the investigation at a recorded budget and publish the unresolved limits. A failed backend trial keeps R4 open and can change the backend; it cannot turn a full remote desktop screenshot into proof of per-window integration.

Production scope includes:

- A session/window registry with host, environment, stable runtime identity, title and last-observed state. Reopening never launches a duplicate command by default.
- A route from Home, the agent dashboard and plugin widgets to existing windows. Missing or dead windows have an explicit recovery/new-session choice.
- Separate Android tasks for local Linux windows where the selected backend supports the required lifecycle. This is a required parity target, not satisfied by a single unrelated desktop stream.
- Text composition, selection, clipboard transfer, Back, pointer buttons, wheel input, modifier keys and per-display scaling.
- A functioning software path before optional GPU drivers. GPU enablement requires device-specific checks, visible failures and a working fallback.
- Clear behavior when Android kills the local environment. Recovery can restore navigation and saved configuration; it cannot claim to revive a dead process without host support.

Physical keyboard, mouse and external-display claims need physical-device evidence before public release. Emulator scenarios remain the implementation loop.

### Recovery and transfer workstream

Extend the existing sealed bundle instead of adding a second backup format. Inventory package releases, instance layouts, configuration, datasets, credential references and pending reconciliation. Test importing older bundles as the schema grows. Report missing package bytes, unavailable credentials and excluded Linux root files before the user mistakes a partial restore for a complete working host.

A new-phone import creates new plugin installation/attachment identities by default and remaps its widgets to them. Copied SSH credentials alone do not transfer remote job ownership. Restored host bindings begin paused until checked. Explicit replacement-device takeover is a separate engine reconciliation design: inventory old jobs/triggers and fence the prior controller before activating the replacement. Until that is supported, recover phone data without claiming remote ownership transfer.

Keep package rollback separate from undoing external commands. Restore paths cover interrupted writes, missing storage, an unavailable source, an offline host and a revoked key. A cleanup record survives package removal and remains actionable from host management. The recovery UI does not need to execute the removed package.

### Performance and usability gates

Before R1, record a baseline on the development emulator and define representative supported physical devices for release measurements. Capture app/runtime/build, OS, hardware, thermal state, power mode, network, host setup and workload. Emulator timings help find regressions but cannot establish handset battery performance.

| Workload | Measures |
|---|---|
| Cold and warm launch; open Installed | Time to usable controls, frame timings, memory peak |
| Six widgets across three attachments | Frame timings, CPU, memory, network bytes and subscription count |
| Long output and reconnect | Time to first retained output, bytes transferred, memory growth and duplicate operations |
| Agent follow-up | Input latency, draft loss, duplicate submissions, target errors and delivery result |
| Background remote job and stopped phone Linux | Poll/reconnect frequency, wakeups, battery use and lifecycle accuracy |
| Expanded layout and Linux GUI | Resize responsiveness, input correctness, memory and rendering failures |

Set numeric budgets from the first measured baseline before beginning performance-sensitive implementation. Every budget records the device, workload, metric, threshold and owner. Compare distributions and raw samples rather than a single best run. For energy, use repeated sufficiently long matched workloads and report variation; small noisy differences do not support a superiority claim.

R1 retains the plugin spec's proposed ten-second find-state and fifteen-minute template-preview targets. R2 targets a second attachment within one minute on an already compatible host. Setup/download time is measured separately and is never removed from the user's total journey when presenting results.

Usability runs use at least three non-authors initially and expand before a public competitive claim. Accessibility scenarios cover screen-reader labels/actions, focus order, larger text, contrast, keyboard navigation and controls obscured by the IME. A terminal screenshot with unreadable text is not an accessibility pass.

### Comparative evidence and completion

Track every coverage row with status `NOT STARTED`, `DESIGNED`, `IMPLEMENTED`, `VERIFIED`, or `BLOCKED`, an accountable owner, relevant app/engine/SDK revisions, acceptance artifacts and remaining limits. Assign the owner when implementation is selected; unassigned work remains not started. A blocker names the missing decision, capability or reproducible failure and the next resolving step.

For each milestone, recheck OmaLauncher's current released build and relevant main changes. Keep released features separate from upstream source. Use the same device and equivalent tasks where possible, balance task order, record agent/model and prompt, and include unsupported outcomes. Maintain both end-user completion measures and technical limits. A feature count or a single successful demo cannot substitute for this comparison.

R5 can support a claim such as faster multi-host setup or more reliable job recovery only for the tested tasks and configurations. If Home, desktop, battery or accessibility coverage is incomplete, the report names it. The ambition to lead across the product does not convert unknown results into wins.

### Next implementation handoff

Start with P0 and P1 while R0 recovery blockers are resolved. The first implementation plan must name the installation repository reused by Installed, current manifest/API limits, SDK artifact destination, curated source, preview transport, and one functioning reference package. Deliver the smallest complete author-to-installed-widget path, then attach it to hosts through P2/P3.

P0 status: the template, checker and fixture preview exist, and the open items are listed in [PLUGIN-SPEC.md](PLUGIN-SPEC.md#contract-and-author-tool-foundation). The author-to-installed-widget path still stops at preview: nothing installs the previewed workspace yet.

Do not begin by writing all five examples against hypothetical APIs or by replacing the renderer. Each reference package enters with the public capability it proves. A milestone cannot close while its documentation instructs users to run a command that is not distributed.

## Explicitly outside the current program

- A Upgrade account, mandatory relay, cloud sync or popularity backend. Direct SSH and user-configured endpoints remain the supported model; revisit only with separate evidence and design.
- Downloadable native plugin modules. Native controls and platform bridges remain compiled into Upgrade; downloaded plugin logic is Luau.
- An iOS promise of unrestricted Linux processes, Android Home or Android-level device control. An iOS product needs its own capability and delivery plan.
- Copying competitor branding, artwork or theme assets.

## Evidence sources

- [Upgrade product contract](SPEC.md)
- [Plugin target and competitive assessment](PLUGIN-SPEC.md)
- [Moshi host setup and Easy Pair](https://getmoshi.app/docs/install)
- [Moshi connections and authentication](https://getmoshi.app/docs/connections)
- [OmaLauncher](https://github.com/SimonSchubert/omalauncher)
- [Happier](https://github.com/happier-dev/happier)
- [OpenMinis](https://github.com/OpenMinis/OpenMinis)
- [Omarchist](https://github.com/tahayvr/omarchist)
- [Apple App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
