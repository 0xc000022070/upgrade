# Upgrade everywhere

> Superseded direction: the user rejected this study. See [the revised strategy](../../STRATEGY.md). This file retains the earlier research and prototype record; its visual proposal is not the current direction.

Interface proposal, 22 October 2026. This is a design study, not a change to the product contract. All prototype actions use in-memory demo data. No command executes, no package installs, and no real Drop changes.

[Open the interactive study](./index.html). Use **All frames** for the design board, or choose a screen from the left rail. Run `python3 -m http.server 8765` from the repository root and open `http://localhost:8765/docs/design/everywhere/`.

## Recommendation

Build Upgrade into a personal work environment that spans Android Home, system entry points, projects, remote machines and phone Linux. Keep the full ambition already recorded in the roadmap. Make project context survive every transition.

The distinguishing experience should be concrete: capture a reference in another app, choose a project and agent, answer its request, inspect its change, open its running result, then unfold the phone into the same workspace. Home, a widget and a notification should reopen that exact work. Custom widgets and plugins should participate in this flow.

This requires coherent behavior as well as coherent graphics. A visually impressive launcher is not proof of better execution, and a strong SSH foundation is not proof of a better daily environment. Upgrade needs both. I would not claim it is superior today.

## What the competitor actually demonstrates

The [devsec_ai video](https://x.com/devsec_ai/status/2113403750371278911) is a 37-second OmaLauncher customization demo. I inspected extracted frames. It shows a desktop-like home, workspace selector, Android app dock, menus, terminal/editor tiles, system monitors and customization settings. The visual continuity across these parts is its strongest demonstrated quality.

It does not demonstrate an agent completing a task, remote-host work, reliability, battery use or Linux GUI performance. Those cannot be inferred from the clip.

Claude inspected [OmaLauncher's source at 1c07b78](https://github.com/SimonSchubert/omalauncher/tree/1c07b78bda7a494238a6c9e75d6f986a36068aec). The current source and maintainer documentation describe a broader product than the clip: local Linux windows, an editable widget language, real previews, a widget catalog, phone controls, notification actions and inline replies. Source presence is not device verification. The clip reports version 0.11.0; the inspected source is newer.

| Area | Oma evidence | Upgrade direction |
|---|---|---|
| Home and customization | A demonstrated, coherent daily environment | Optional full Home mode with apps, pages, widgets and recoverable layout editing |
| Local computing | Source and documentation describe Linux GUI windows and a compositor | Phone Linux becomes a visible machine and window provider, with actual runtime work required |
| Authoring | Editable UI files, checking, previews and catalog | Describe, build, check, preview, attach, place, update and share in one understandable flow |
| Work on other machines | No dedicated multi-host product model found in inspected source | Keep SSH/Mosh, host identity, agents, code and screens connected to the project |
| Use with another launcher | No own Android widget providers found in inspected source | Existing Upgrade widgets remain useful without adopting Upgrade Home |
| Capturing outside the app | No inbound share target found in inspected source | Extend the existing share entry point into explicit project and agent routing |
| System access | Notification listener actions exist in inspected source | Own notifications, shortcuts and capture access first; broader phone controls remain explicit capabilities |

Negative source findings are bounded to that revision. They are not permanent claims about OmaLauncher. Neither researcher ran OmaLauncher on a device.

## What the maintainer's phone adds to the decision

I inspected Upgrade on the maintainer's phone, including the unfolded Home and recent Drops, then released it. The Home showed 123 Drops. Its raw list occupied most of the available space, with capture, resume and navigation below. That is a real composition problem: the user's collected material dominates the place intended to show ongoing work.

The recent Drops contain several connected requests:

- An Oma-style home and apps, including the linked demo.
- Stronger project presentation and motion.
- A notes/canvas plugin and kanban-style agent organization.
- Better machine setup, including adding a host and adding phone Linux.
- Cropping attached photos and making host identity clearer on tabs.
- A reconnect complaint after shutting down and restarting the computer.

The prototype uses synthetic summaries of these ideas. Real Drops were not edited, moved or marked done. Device screenshots remain outside the repository. I sampled recent Drops, not all 123 entries. The reconnect complaint was read, not reproduced or fixed.

## Interface direction

### Home should make active work visible

Keep the Upgrade identity: condensed headings, precise labels, dark neutral panels, restrained lime state accents and the existing icon family. The study changes composition, not the brand.

Home shows a selected project, a pending decision, a compact recent inbox and direct access to apps and windows. A large inbox opens into its own workspace. Let users choose the Home layout and its widget density; do not make a long backlog automatically determine the entire screen.

Support two entry arrangements: widgets on the user's existing launcher and an optional Upgrade Home. Full Home mode must include ordinary app launching, search, useful shortcuts and compatibility with third-party Android widgets. A replacement home has to remain useful beyond coding.

### Projects should preserve the working context

A project brings together its objective, references, hosts, sessions, changed files and windows. Give it an identifiable title and composition. Every jump keeps the project and execution machine visible.

The important cross-screen identifiers are project, host, directory and session. Labels alone do not create continuity; the implementation needs stable object identities and deep links that reopen the correct object.

### Agents should lead to inspectable results

Show the actual request, execution target and evidence. An approval on one view updates every other representation of the same request. Denied, expired and already-answered requests must not look actionable.

The transcript is readable; the original terminal remains reachable. The current contract does not support general follow-up sending from the conversation. This study does not claim otherwise. Adding that would require a separate product ruling and delivery reconciliation.

A completed run should lead to its changed files, test evidence and relevant device or application preview. These are connected destinations, not unrelated tabs.

### Unfolding should add useful working space

On a compact phone, keep one task legible. On an unfolded phone, open code beside the result and keep a narrow project rail. Preserve selection, drafts and session identity when the posture changes.

Local Linux windows and remote device screens remain different resources. Each window names its provider. An environment stopping, a remote host disconnecting and a remote host rebooting are different states. The interface must not imply a process survived when it did not.

The study illustrates a wide workspace; it does not implement Android Recents integration, a compositor, GPU acceleration or remote streaming.

### Drops need a workspace, not just a longer list

Retain immediate capture. Add readable source titles, destinations, a project lens and a canvas view for related material. Separate unfiled material from work already attached to a project. Grouping is a view, not permission to silently reorganize the user's data.

A share entry should preserve source, text and attachments, then let the user select a destination. Cropping and annotation belong before saving or sending. Those image tools are annotated concepts in this mock, not working editors.

The project-motion and notes references are useful research inputs, not evidence that their visual style belongs in Upgrade. Keep the existing visual vocabulary.

### Customization and plugins should complete the loop

A package, a configured host attachment and a widget placed on a page are distinct objects. Their screens should make that understandable without exposing implementation jargon.

The intended authoring sequence is complete: describe the tool, open its source, check it, preview it with real data, choose its target, install it, place it, revise it, and share it. A gallery without this sequence will not match OmaLauncher's strongest advantage.

Layout editing needs direct manipulation plus accessible alternatives, preview sizes for compact and expanded devices, explicit host bindings and recovery to the last valid layout. The mock demonstrates density, placement and attachment state only. It does not implement plugin execution, real checking, publication or drag-and-drop authoring.

### Reach beyond the application deliberately

Use Home widgets, share targets, dynamic shortcuts, notifications and Quick Settings for the actions people need while elsewhere. Keep the notification entry tied to the exact session. Offer the full interface when the decision needs more context.

Android owns the system shade, lock screen and parts of widget rendering. The mock's system frame is an explanation of entry points, not a promise that Upgrade can restyle Android everywhere. Broader notification access, radio controls and media actions have platform-specific limits and permissions. Android Live Updates are not a guaranteed fit for arbitrary agent jobs; eligibility needs a separate platform check.

## The full ambition and its proof

This is one product program. The rows below identify what must exist before the corresponding experience can be claimed. They are not a recommendation to shrink the product.

| Experience | Required implementation | Proof |
|---|---|---|
| Work continues across entry points | Stable project/session links, widget and notification actions, share routing | Open the same session from Home, a notification and a project; answer once; all views agree |
| Home is a daily environment | Android Home role, apps/search/shortcuts, third-party widget hosting, layouts | Use ordinary Android apps and widgets for a day without losing work context |
| Phone Linux is a computer | Environment lifecycle, local GUI/window integration, input and clipboard, truthful failure states | Open a GUI app, switch through Recents, return, stop the environment, show the correct state |
| Foldable work is productive | Adaptive project/code/preview layouts, state preservation, keyboard and hinge handling | Fold and unfold mid-review without losing selection, draft or session |
| One integration works across machines | Plugin attachments, capability checks, durable job state, real previews | Attach once locally and once remotely; stop one target without breaking the other |
| Users can create useful tools | Authoring/check/preview/install/update/share loop | Have an outside user build and revise a tool without editing Upgrade itself |
| Drops become actionable | Source previews, project routing, image preparation, triage views | Capture in another app, file a reference, send selected material to the intended target |
| Remote work survives interruptions honestly | Existing connection lifecycle, reconciliation, reboot distinction | Network loss and host reboot produce different outcomes; no duplicate send or fabricated recovery |

Oma's coherent home is a useful standard. Upgrade can aim beyond it by making the whole work lifecycle equally coherent across local and remote computers. The mock makes that direction inspectable; superiority still needs working native behavior and comparative task evidence.

## Reading the artifact

The interactive mock has Android Home, projects, project workspace, agent decision, code review, a wide window workspace, phone Linux, Drops/canvas, capture, layout studio, plugin workshop and system access.

Working interactions include navigation, allowing or denying the sample request, file tabs, workspace tabs, environment state, saving a sample Drop, widget placement and density, and plugin target selection. These are browser simulations, not operational controls. Reset clears the session's demo state.

All frames mode exposes the screen family together. Individual frames contain the design intent, what changed and an action to try. The browser artifact is the reviewable proposal; SPEC.md, PLUGIN-SPEC.md and ROADMAP.md remain unchanged by this study.

## Sources

- [OmaLauncher demo](https://x.com/devsec_ai/status/2113403750371278911), recovered through the [metadata mirror](https://api.fxtwitter.com/status/2113403750371278911) and its video URL.
- [Pinned OmaLauncher source](https://github.com/SimonSchubert/omalauncher/tree/1c07b78bda7a494238a6c9e75d6f986a36068aec), inspected by Claude.
- [Oma widget catalog](https://github.com/SimonSchubert/omarchy-widgets).
- [Android app widgets](https://developer.android.com/develop/ui/views/appwidgets/overview), [sharing shortcuts](https://developer.android.com/training/sharing/direct-share-targets), and [Live Updates](https://developer.android.com/develop/ui/compose/notifications/live-update).
- [Project motion reference](https://x.com/salungprastyo/status/2113100863304855896), [notes reference](https://x.com/steveruizok/status/2113370058135068899), and [kanban reference](https://x.com/odd_joel/status/2112211109533061194). Their text was recovered; this study does not claim a full audiovisual review of those three references.
- Local product contracts: [SPEC](../../SPEC.md), [plugin target](../../PLUGIN-SPEC.md), [roadmap](../../ROADMAP.md), plus direct inspection on the maintainer's phone.

Two Claude Code instances researched competition and product structure independently of the main implementation pass. They shared the task and repository context, so this was parallel research, not a blind evaluation. The lead made the final proposal.

## Validation of this artifact

The lead checked the final artifact in Chromium at 1440px and 375px viewport widths. All 12 screens rendered without page-level horizontal overflow. Browser checks covered approval propagation, denial propagation, capture persistence, the crop button not submitting the form, attachment followed by widget placement, all-frames rendering, and request state surviving a posture change. Folded and unfolded screenshots were inspected. JavaScript syntax checking passed.

Claude completed the artifact's state and interaction fixes and reported its URL. Its own checks were source/render checks and HTTP responses; the lead performed the real-browser pass. Native Android behavior, compositor performance, image editing and production Flutter behavior were not tested by this frontend study.
