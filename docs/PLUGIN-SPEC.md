# Plugins, attached hosts, and authoring with agents

## Status and purpose

This is the target contract for the next plugin developments. It specifies proposed behavior, not a claim that the current build implements it. [SPEC.md](SPEC.md#plugins) remains the contract for existing behavior. Each delivered increment moves its corresponding behavior into that contract and updates the implementation status here. Until then, this document guides design and sequencing; it does not make an absent API available.

The product promise is: install a plugin once, choose where it works, and use its Luau pages and widgets to control that work. A plugin can work entirely on the phone, attach to one host, or attach to several hosts, including Linux environments running under PRoot on the phone. A person can describe a plugin to their coding agent and complete the authoring, preview, installation, diagnosis, and publication loop without modifying Upgrade.

The two success criteria are independent. Authors must be able to build useful integrations without a new Upgrade service for each integration. Users must be able to discover, understand, attach, place, update, and remove those integrations without understanding the runtime architecture.

[ROADMAP.md](ROADMAP.md#competitive-delivery-program) owns the product milestones, dependencies, and broader Android Home and Linux desktop work. This document owns the plugin contracts and their acceptance scenarios. A milestone can deliver a useful subset, but it cannot mark a capability complete by pointing to this plan.

### The existing decisions this model keeps

- The phone remains local-first and single-user. Browsing a public catalog needs no Upgrade account. Installed plugins and their locally available data remain usable without the catalog.
- Downloaded plugin code is Luau. Native Flutter modules remain compiled-in implementations. User-installed programs invoked by a plugin can use other languages; they are tools on a target, not another downloadable plugin runtime.
- Remote operations use the existing SSH connection lifecycle and the user-installed Upgrade engine. The app does not install or replace that engine on a remote host. Phone-hosted Linux follows the existing exception for app-owned files.
- The engine is the single host integration program. A general service can run a user's installed tool, but a plugin does not introduce its own host daemon or an untracked installation script.
- PRoot environments are called `PHONE LINUX` in the interface. They share the phone's kernel and are not described as full virtual machines. A remote VM is an ordinary registered host.
- Existing data, plugin identities, grants, disabled states, and placement preferences survive migration.

The new host-facing plugin APIs extend the engine's generic operations. They do not reinstate the previously rejected scheduler-specific Python adapter. Host-side Luau execution is a separate advertised engine capability, delivered only after its runtime exists.

### What exists and what remains to build

| Area | Inspected foundation | Target work |
|---|---|---|
| Phone runtime | Luau worker, bounded calls, private datasets, manifests, retained revisions | Attachment-aware context and author tooling |
| UI | Luau pages, Home cards, canvas, native controls, placements | Multiple configured instances, explicit target context, real previews |
| Host runtime | Engine has versioned filesystem, execution, scheduling, agent, shell, and Git services | General plugin access with attachment identity, job ownership, reconciliation, and negotiated limits |
| Plugin host registry | Hosts, scheduler, and agents adapters | General execution and filesystem adapters; later host-side Luau |
| Phone Linux | Multiple installations registered as ordinary loopback SSH hosts | Reuse those hosts as attachment targets |
| Management | Dependency board, detail sheets, Browse, user-added Sources | Installed library, Discover, setup, host detail views, update center |
| Distribution | GitHub refs resolved to commits, source indexes, package digests | Useful default catalog, previews, release metadata, publish workflow |
| Development | Source examples, SDK documentation, debug fetch-origin override; a repository author tool (`init`, `docs`, `check`, `preview`), one phone-only template with fixtures, and a fixture card preview on the phone | Standalone author CLI, page and live previews, reload, screenshot artifacts |

This inventory is based on source and the current product contract. It is not handset performance evidence. In particular, an engine service existing does not imply that a third-party Luau plugin can already call it.

## The user model

### A package, an attachment, and a widget are different things

| Object | What it means | Stable identity and lifetime |
|---|---|---|
| Catalog listing | A discoverable description pointing to a release | Source identity plus package identity; removing a source does not uninstall anything |
| Package | The author's plugin, with a manifest and its declared files | Manifest ID anchored to its canonical source origin |
| Release | One immutable set of package contents | Source revision and content digest, with a display version |
| Installation | This user's installed package | Installation UUID, one selected release, enabled state, phone grants |
| Attachment | One configured use of an installation against one registered host | Attachment UUID, host UUID, optional workspace, configuration, grants, desired state |
| Contribution | A page, widget, or action declared by the package | Stable contribution ID within the package |
| Widget instance | One placed and configured copy of a widget | Instance UUID, contribution ID, explicit context, placement and view state |
| Job | One accepted operation on one target | Target-owned job ID and originating request identity; records its release and attachment |
| Development session | A temporary author workspace linked to a preview device | Session UUID and distinct development installation |

Installing a package does not create one copy per host. Attaching it to a second host does not reinstall its phone UI. Placing a second widget does not create another host attachment unless the user asks to configure another use.

For example, `Git status` is installed once. `Laptop / app` and `Laptop / infrastructure` are two attachments to the same host with different workspaces. `Phone Arch / app` is a third. The user places three cards, or one aggregate card if the plugin declares that contribution.

The package's display name, a host's name, and a workspace label may change without changing identity. Host names and addresses are never ownership keys.

### A plugin declares whether it needs a host

The manifest declares `none`, `optional`, or `required` host support, independently of its UI contributions. A contribution can require a narrower context than its package. A local settings page can open even when the package's host card needs an attachment.

| Context | Meaning |
|---|---|
| Phone | Pure Luau UI, private data, or declared phone APIs; no host attachment |
| One attachment | A specific host and optional workspace, selected by the user |
| Attachment set | An explicitly selected set for a declared aggregate contribution |

An aggregate widget has a saved selection. `All attached hosts` is an explicit mode that follows the installation's attachments; it does not attach the plugin to newly registered hosts. A fixed selection remains fixed until edited.

The author declares whether multiple attachments to the same host are meaningful. The default permits them only when their configured workspace or named instance differs. Exact duplicates offer `OPEN EXISTING` rather than silently creating another configuration.

### A target is selected, then checked

The target picker lists registered remote hosts and `PHONE LINUX` hosts together, grouped by location. Rows show the familiar host name, system, connection state, and compatibility result. A stopped phone environment is selectable and says `STOPPED`; an offline remote host is selectable and says `NOT CHECKED` if its capability information is stale.

Compatibility has three outcomes: supported, unsupported with a concrete reason, and unknown until connected. Cached capability information includes when it was observed. Unknown is not silently treated as supported or incompatible.

The user can choose multiple hosts during setup. Each becomes an independent attachment with its own result. One missing tool or offline host does not undo successful attachments elsewhere. A saved attachment that cannot yet be checked reads `SETUP PENDING` and cannot execute until checked.

If no host exists, the picker offers `ADD HOST` and `ADD PHONE LINUX`, using the existing flows and returning to this setup afterward. These are choices, not automatic downloads or automatic registration of a machine the agent happens to use.

The author can specify compatibility requirements, not a hardcoded user's hostname. The user supplies host, workspace, credentials, and instance configuration after installing.

## Installed plugins and discovery

### Plugins opens on Installed

The existing Plugins entry opens a full screen with `INSTALLED` and `DISCOVER`. It remembers the selected tab during navigation; a fresh visit defaults to Installed. `SOURCES`, `UPDATES`, and `DEVELOPMENT` are named secondary destinations in that screen. A badge on Updates counts packages with an available compatible release, not every attachment to those packages.

The dependency board becomes `DEPENDENCIES`, a secondary view of the same installations. It keeps its useful graph and dependency explanations. Routine management does not require interpreting graph edges or pips.

Installed contains every installation, including built-ins, direct installs, disabled packages, incompatible retained releases, and development packages. A failed or removed catalog source cannot hide an installed package. Search matches display name, purpose, author, host, and workspace. Filters include `ALL`, `ENABLED`, `DISABLED`, `NEEDS ATTENTION`, and a host filter. A development package has an explicit `DEVELOPMENT` label.

A row communicates:

- Name and a one-line purpose, led by its icon or emblem.
- Installed version and availability of an update.
- What it adds, such as `2 WIDGETS · 1 PAGE`.
- Where it works, such as `PHONE`, `LAPTOP + 2 HOSTS`, or `NEEDS A HOST`.
- A useful aggregate state, such as `2 READY · 1 OFFLINE`, rather than declaring the whole plugin broken.

The row's main action follows the next task: `OPEN`, `SET UP`, or `FIX`. A detail menu exposes enable/disable, attach, placement, and removal. Counts remain legible with text scaling and never depend on color alone.

An empty library explains what a plugin adds and offers `DISCOVER PLUGINS` and `CREATE WITH AGENT`. An empty filter shows `NO MATCHES` with `CLEAR FILTERS`; it does not look like an empty installation.

### Details answers what, where, and what next

Details is a full page with persistent back navigation. Its first screen shows the name, purpose, version, preview, current state, and the next useful action. Technical counters do not displace these.

Named sections contain:

| Section | Contents |
|---|---|
| Overview | Description, screenshots, quick start, author, source, license, release notes |
| Where it works | Attachments with host/workspace, state, last successful contact, and per-attachment actions |
| Widgets and pages | Previews of contributions, placed instances, `ADD TO HOME`, `OPEN PAGE`, and placement editing |
| Settings | Package settings and explicitly separate attachment settings |
| Activity | Current jobs, recent results, errors, and pending host changes |
| Access | Existing grants, host scope, and requested changes |
| Data | Phone and host data summaries, retention, export, and removal choices |
| Diagnostics | Runtime/API versions, calls, limits, detailed logs, and an export for an agent |

`DISABLE` pauses the installation; `DETACH` removes one association with a host; `REMOVE` removes the phone installation. These are separate actions with their concrete consequences. The product does not describe any of them as deleting a user's repository.

### Host details also shows attached plugins

Every host detail page has `PLUGINS`. It lists attachments to that host, including distinct workspaces, and offers `ATTACH PLUGIN`. This picker starts from installed packages compatible with that host, with a route to Discover. It uses the same setup and grants as the global library.

Selecting a plugin from a host opens its detail with that attachment selected. Selecting a host from a plugin opens the existing host detail. Both routes reach the same attachment record.

### Discover is useful without configuring a source

Upgrade supplies one named, removable curated source whose catalog is hosted as static files. The exact repository and public URL must exist before the feature ships; placeholders are not a working marketplace. Users can add independent sources and install directly from a repository. No account is required to browse or install public packages.

The curated source starts with packages that the app can actually install, with real screenshots and compatible releases. A built-in plugin can appear as `INCLUDED`, linking to its installed detail rather than offering a duplicate download.

Discover provides search, category filters, `WORKS WITHOUT A HOST`, `PHONE LINUX`, and `WORKS WITH MY HOSTS`. The last filter uses known capabilities and keeps `NOT CHECKED` separate. Categories describe jobs such as Development, Monitoring, Productivity, and Utilities; they are data in the index rather than new app code for each category.

Each listing shows a real preview, name, purpose, author/source, and `INSTALLED`, `UPDATE`, or `INSTALL`. The preview illustrates a result, not only an emblem. Selecting it opens a detail page before setup. Filters and scroll survive opening details and returning. At wider widths, details may sit beside the list; the information and actions remain the same.

Ranking is deterministic and explained by its selected mode: curated, recent releases, or name. The first version does not invent ratings, install counts, or popularity statistics. Lack of an account service does not prevent search, categories, previews, or a useful installed view.

Catalog data and previews are cached. Offline browsing identifies the cache and its age. An install requiring uncached files says so. Refresh failures retain the last valid catalog and show the failed source independently.

### A listing does not define package identity

A listing points to an immutable release and its expected content digest. Display metadata includes name, summary, description, category, author, source, license, release notes, supported API ranges, host requirements, contribution inventory, and preview assets. Optional measured package sizes include what is measured; a platform download is not presented as an entire dependency cost.

The package identity is its manifest ID plus canonical source origin. Two indexes pointing to that identity and release produce one listing with both source labels. Two origins claiming the same manifest ID produce a visible identity conflict; a catalog cannot replace an existing installation merely by repeating its ID. A fork normally gets a new manifest ID. Changing an installed package's origin is a distinct migration with an explicit data-ownership decision.

`CURATED` means a specific release was admitted to that source. It is not a claim about every future release or a substitute for capability review. A locally modified development package does not retain the curated badge of the package it started from.

The first marketplace relies on pinned content and a reviewed source. Publisher signatures and account-backed reputation are separate designs, not prerequisites for making discovery useful. A digest proves which bytes were fetched; it does not identify a trustworthy author.

## Installation and attachment

### Installation prepares the package before setup

The install flow resolves and fetches one immutable release, validates it, computes the dependency plan, and presents what it adds and requires. `INSTALL` saves the package. It does not silently attach hosts, place widgets, or start host work. The next step offers `SET UP` and `LATER`.

For a phone-only plugin, setup grants its phone capabilities and offers contributions to open or place. For a host-capable plugin, setup proceeds through host selection, compatibility, configuration, requested access, and an attachment summary. Returning to a prior step retains the user's choices.

The final action names its effect, such as `ENABLE ON 2 HOSTS`. Package enablement and attachment activation can be part of that explicit action. There is no second identical confirmation for each operation already covered by the reviewed attachment grant.

Install-time dependency resolution shows required packages and versions together. Missing dependencies can be fetched through their declared canonical origins. Ambiguous sources require a selection. A failure leaves the prior enabled installation set intact. Installation of a dependency is not permission to use all its data.

### Configuration has declared scope

Every configuration field has a schema, help text, validation, and one scope: installation, attachment, or widget instance. The interface explains the scope before saving. A change to the repository path for one attachment cannot move another attachment's workspace.

Secrets are credential references, not ordinary persisted text fields. Settings and diagnostic exports show the reference's label and whether it is configured. A package manifest, marketplace listing, fixture, or share link contains no user's resolved credential value.

Package configuration supplies defaults only where the schema explicitly declares inheritance. The details page identifies an inherited value and supports an attachment override. Removing an override restores the named default rather than an undocumented runtime choice.

### Attachments carry execution context

An attachment stores its installation ID, host ID, optional canonical workspace reference, user label, configuration, grants, desired enabled state, desired release digest, last observed compatibility, and last reconciliation result. A host rename does not invalidate it; deleting and recreating a host creates a new identity and requires rebinding.

The phone creates an invocation context from the chosen attachment. The plugin receives display metadata and opaque handles. It cannot substitute a raw host ID in an effect to make that call escape the invocation's selected attachment. An aggregate contribution receives one handle per selected attachment and results that name their origin.

Concurrent invocations capture their own context. Switching a page's target affects subsequent actions; an in-flight result remains attributed to its original target and cannot populate the newly selected host's state.

The attachment namespace is separate from the engine's authenticated account owner. Plugin identity is not an alternate SSH account. Namespaces organize data and jobs; they do not provide OS isolation from arbitrary programs running as the same account.

### Existing services obey the selected context

Opting into attachments changes every host-facing adapter, including existing services. Scoping only command submission leaves reads, subscriptions, and job management ambiguous.

| Operation | Required scope |
|---|---|
| List hosts | Only the installation's attached hosts; the native attachment picker owns discovery of other registered hosts |
| List workspaces | Selected attachment's host; workspace-bound operations use its canonical workspace |
| List/watch agents | Selected host and, for workspace-bound attachments, matching canonical workspace; unknown workspace association is not a match |
| Open/answer an agent item | Revalidate the item's current host/workspace against the invocation; possession of an item ID grants no additional scope |
| Schedule work | Installation and attachment namespace; two workspaces on the same host have independent schedules |
| Job status/output/cancel/history | Validate installation and attachment ownership, including for an already accepted job |
| Cleanup | Exact recorded resources in that installation and attachment namespace |

An installation-wide agent inbox requires a separately declared and granted scope across its selected attachments. It does not turn an ordinary widget invocation into access to every host. Raw host arguments in older services are supplied by the adapter from the validated context. Legacy packages keep their declared API behavior until they opt into this model.

Two phone installations connected to the same SSH account have different installation/attachment namespaces by default. Importing SSH credentials does not clone those identities. Development installations have separate namespaces too. Shared management across phones would require an explicit ownership-transfer or sharing design; copying a package ID is insufficient.

The engine's account-wide lifecycle teardown remains a host administration operation. It cannot implement plugin removal, detachment, or development-session cleanup. Those operations require namespace-scoped resource inventory and deletion. Direct SSH programs running as that same account still have the account's OS authority; this API scope is not a process sandbox.

## Execution on the phone and on hosts

### General capabilities make new integrations possible

The initial general API families are execution, files, and HTTP, alongside the existing hosts, scheduler, and agents services. Public API names and payloads are generated from a versioned contract, shared by the validator, documentation, client adapters, and engine negotiation.

| Family | Required behavior | Where it runs |
|---|---|---|
| Execution | Structured argv, working directory, environment references, input, timeout, job status, bounded output, cancellation | Selected attachment through engine `run` services |
| Files | List, stat, bounded read, write with conflict detection, and explicit transfer; watch when advertised | Selected attachment through engine `fs` services |
| HTTP | Method, URL, headers/credential references, bounded request and response, timeout and cancellation | Phone unless a distinct target capability is requested |
| Events | Lifecycle and job changes, subscribed data changes, and visibility-aware refresh | Phone dispatcher and advertised host sources |
| Host Luau | Execute a declared host entry with structured input and output | Future engine runtime; absent until implemented and advertised |

A `cwd` identifies where a process starts; it is not a filesystem sandbox. Direct filesystem grants can restrict their adapter's paths, but granting general process execution delegates the account's program authority, including what that program can reach. The access UI states that distinction without claiming that an executable allowlist confines all its behavior.

Execution uses an argument vector by default. An explicit shell command is a distinct operation when supported, not accidental interpolation of a UI field. Installed tools such as Git, Python, Node, or a user's CLI can be invoked through that general interface. Downloaded plugin code remains Luau. A personal tool already installed on the target can be a dependency without becoming a plugin-owned daemon.

The existing engine already has basic execution and filesystem services. The first implementation exposes them through the plugin model and adds missing semantics explicitly. In particular, current `run/1` does not by itself prove request deduplication, plugin job namespaces, resumable streams, or per-attachment revocation. New protocol semantics require an advertised feature or new service version.

### Capability coverage has explicit delivery gates

The following table is the target API inventory. The IDs refer to the delivery packages below. All rows are planned; an existing native implementation supplies a foundation, not automatic plugin access.

| Capability | Minimum usable contract | Delivery gate |
|---|---|---|
| Phone data and configuration | Installation, attachment and instance scopes; revision-aware updates; typed configuration; migration | P2 |
| Phone HTTP | GET, POST, PUT, PATCH and DELETE; credential references; structured response/status; cancellation; declared limits | P3, with an independent phone-only slice allowed earlier |
| Host commands and files | Structured arguments, ownership, request reconciliation, output cursors, conflict-aware writes and negotiated watches | P3 |
| Live data | Host event subscriptions and phone WebSocket subscriptions with reconnect, gap and resnapshot behavior | P3 |
| Credentials and private endpoints | Scoped credential references, rotation, revocation and explicit endpoint trust configuration | P3 |
| Existing terminal/agent sessions | Discover within scope, open the original session, observe state, and embed a native terminal view when supported | P3 |
| Agent follow-ups | Supported adapter reports delivery separately from execution; unknown delivery preserves the draft and blocks automatic resend | P3; unsupported adapters retain the shell route |
| Phone capabilities | Versioned adapters for selected Android data/actions, with clear unavailable and permission states | P7, coordinated with the roadmap's phone integration work |
| Host Luau | Versioned runtime, release identity, resource limits, namespace and negotiated job lifetimes | P6 |

Phone WebSockets connect to endpoints selected during plugin setup. This is a proposed direct integration capability, not a Upgrade relay or account service. The current contract's absence of service WebSockets must be narrowed explicitly when this capability ships. Keep protocol transport separate from where the user's computation runs.

### Live data reconnects without inventing continuity

A subscription declares its attachment or phone endpoint, resource, event schema and limits. Each event carries origin, schema version, observation time, and a stream generation with sequence or resume cursor when the provider supports one. A fresh connection is not evidence that missed events were delivered.

The adapter reports `CONNECTING`, `LIVE`, `STALE`, `RESYNCING`, `AUTH REQUIRED`, or a specific failure. It resumes from a retained cursor when supported. Otherwise it requests a fresh snapshot and marks the gap. Ordering is defined within one stream generation, never across unrelated hosts by arrival time alone.

Each subscription has a bounded buffer and an explicit overflow policy. Replaceable observations may coalesce to the latest state. Dropped non-replaceable events cause a gap and resync, rather than silent loss. Reconnect uses bounded backoff and respects visibility, lifecycle and explicit user pauses. Mutating messages are not replayed merely because the socket reconnects; their operation contract must define reconciliation separately.

Matching widgets can share observations under the existing attachment and grant rules. A live dashboard must not spawn one polling process per visible row. Transport diagnostics record connection attempts, bytes, gaps and resyncs without exposing credential values.

### Credentials belong to configuration, not source code

A credential reference binds to the installation or attachment, the intended endpoint and the permitted use. The adapter resolves it into the request; Luau receives its configured/expired state rather than a reusable plaintext secret. Rotating a credential replaces its value without rewriting package source. Revocation closes affected subscriptions and requires setup before further authenticated calls.

Normal HTTPS uses the platform's certificate validation. Private endpoints can use an explicitly configured private CA or public-key pin, with hostname and expiry behavior specified by the adapter. A certificate change produces `SERVER IDENTITY CHANGED`; it cannot silently become an insecure connection. Setup and diagnostics distinguish an untrusted server from an expired credential. Host commands use separately declared environment or input references and retain the account-authority limits described above.

Fixtures contain sample credentials only. Publication strips user configuration and rejects unresolved examples that contain real credential values. Copying a configured widget never copies its access grant. A restored credential reference that cannot be resolved returns to setup.

### A session view opens the original work

The session API uses an opaque reference to host, canonical workspace, runtime/session identity and generation. A label, process ID, tab index or terminal title alone is insufficient. Opening an existing session validates that identity and returns the existing shell, pane or agent view. If it has ended, the result says `SESSION ENDED` and offers an explicit new session action.

A native terminal contribution observes that reference. Mounting it, resizing it, refreshing data, or reloading plugin UI does not launch a process or send a prompt. The view starts with observation access. User interaction activates input through the native terminal controller, with the target visible, keyboard composition, selection, Back and focus handled consistently with the full shell. Removing the view releases observation; ending the underlying session is a separate action.

Live terminal preview uses a fixture or a specifically selected live session. It cannot reuse a production session by guessing the last active tab. Multiple views of the same session share its transport and state; input ownership is explicit so two focused views cannot duplicate a keystroke.

Supported agent adapters expose follow-up submission as a capability. The caller supplies a request identity and receives `ACCEPTED`, `DELIVERED`, `REJECTED`, or `DELIVERY UNKNOWN` as supported by actual evidence. Delivery does not mean the agent completed the task. The composer preserves text and attachments until delivery is known. An adapter that cannot acknowledge or deduplicate submission falls back to opening the original pane with the draft ready for the user. It cannot claim successful structured chat control by pasting into an unidentified terminal.

### The same API negotiates different machines

Before activation, the engine probe establishes platform, architecture, libc where relevant, services, operations, policy denials, limits, and supported job lifetimes. Tool requirements identify executables and usable versions. An unknown version is reported as unknown, not guessed from a distribution label.

Phone PRoot and remote Linux use the same attachment API with different capability reports. A feature depending on systemd, kernel facilities, hardware, or a background supervisor cannot infer support from `Linux`. In particular, a PRoot target does not inherit remote systemd scheduling just because both can run a command.

A missing engine yields `ENGINE REQUIRED` with the existing owner-install route and `CHECK AGAIN`. A missing tool yields `NEEDS <tool>` with the requirement and `SET UP WITH AGENT`. That action uses the selected authoring agent workflow against that target. Merely attaching a plugin does not run a package manager or edit the host's declarative configuration.

The same plugin may have a working manual mode on a host that lacks its optional scheduling capability. The UI disables only the unavailable operation and explains why. A required capability blocks that attachment, not the package's phone-only contributions or other hosts.

### Phone Linux starts through the existing host lifecycle

A foreground action to use an attachment on stopped phone Linux follows the existing start-and-connect flow. A visible card showing cached data does not repeatedly restart an environment the user stopped. Automatic refresh reports `STOPPED` until an explicit use starts it again.

Stopping or removing phone Linux follows the existing host controls. Every affected attachment changes state, jobs become stopped or unknown as evidence allows, and other environments remain independent. An app-owned environment can still lose its processes when Android ends it. Durable jobs on a remote host and jobs on phone PRoot have different survival guarantees.

### Every operation has a bounded lifecycle

An invocation carries installation, release digest, attachment, activation generation, caller contribution, request ID, and operation input. The host adapter supplies the authenticated account and validated namespace. The result records the same identities.

Jobs state whether they are session-bound or detached. A session-bound subscription ends when its subscriber is disposed; session disposal also requests cancellation of its session-bound jobs. Disposing an observation does not prove that remote execution ended. A detached job is tracked after the page closes and exposes status and cancel. Detachment is offered only when supported by the engine and selected operation. The manifest states which lifetime an action needs, and setup explains it. A guaranteed execution bound requires an advertised host-enforced timeout or lease; phone connectivity alone cannot provide one.

Luau callbacks remain short and bounded. Long-running work belongs to a host job, and results return as events. No phone-side infinite Lua loop is required to tail a log, render a progress card, or wait for a job.

Output has cursors, byte limits, and a declared retention limit. The client requests the next retained segment. A missing segment returns `OUTPUT GAP` with the earliest available cursor; it does not silently repeat old lines or pretend a truncated log is complete. Where an engine only provides snapshots, the API identifies them as snapshots and cannot claim resumable streaming.

Cancellation changes locally to `CANCEL REQUESTED`. Acknowledging the request means the target accepted the cancellation attempt. `CANCELLED` requires a terminal result confirming cancellation. If the job finished before cancellation took effect, its result remains `COMPLETED` or `FAILED`. An unreachable target or expired history leaves the outcome unknown. Closing a screen is not evidence that a remote operation stopped.

### A lost answer does not authorize a duplicate job

The client records a request ID before submitting a side-effecting operation. Where the negotiated service supports deduplication, the target records its association with the job and returns the same job for the same request. A different payload under that ID is rejected. The engine defines recovery around its acceptance and spawn boundary before this behavior ships.

On disconnection, the client queries that request or job before considering resubmission. A legacy service without this contract reports `OUTCOME UNKNOWN` and requires an explicit new action; the adapter does not automatically replay a command that may have run.

Deduplication is bounded by a stated retention period. After expiry, the result is unknown. The product does not promise exactly-once side effects across arbitrary programs, crashes, or expired host history.

### Enablement, reachability, and compatibility are independent

| Dimension | Values and meaning |
|---|---|
| Installation | Installed, enabled, disabled, incompatible, update available |
| Attachment intent | Enabled, paused, detached |
| Compatibility | Supported, missing requirement, unsupported, unchecked |
| Connectivity | Connected, offline, phone Linux stopped |
| Reconciliation | Up to date, pending apply, pending pause, pending cleanup, failed |
| Job | Submitted, running, completed, failed, cancel requested, cancelled, outcome unknown |

The UI composes these into a concise state and keeps the details accessible. It never stores one overloaded status that loses whether the user disabled something or the network merely disappeared.

Disabling an attachment revokes new invocations immediately on the phone and requests pause of future host triggers. Existing jobs keep their declared lifetime; the dialog offers a separate `CANCEL RUNNING JOBS` action when jobs exist. Disabling the installation applies that operation to its attachments and withdraws its interactive contributions. Data and placement remain.

An offline target can leave a pause or cancellation pending. A durable host timer can continue until the host receives the change. The interface states this and retains the pending task after the plugin is removed, using a cleanup record that needs no execution of removed plugin code. Re-enabling does not silently resume paused schedules.

Detaching removes the active binding after recording outstanding reconciliation and retained data. A user can later restore an archived attachment; an unrelated new attachment receives a new namespace. Deleting a host does not acknowledge cleanup on an unreachable machine.

## Luau pages, widgets, and data

### Widgets are configured instances

A package can declare several widget contributions. The user can place multiple instances of the same contribution with different attachments, filters, or display settings. Each instance has its own stable ID and layout state. Package release updates preserve IDs and instance configuration when compatible.

`ADD TO HOME` shows a real preview, chooses a contribution, selects its context, then picks a supported size and placement. A host-required contribution offers attachment setup when none exists. It does not bind to the last shell opened or the first host in a list.

Every host-bound widget displays the target name, and the workspace when ambiguity exists. An aggregate widget labels each result and offers a route to its originating attachment. A mutating aggregate action names the affected targets and returns separate outcomes; a partial failure cannot read as global success.

Widgets use the current native UI vocabulary and theme tokens. Authors own composition and Luau logic. The first delivery does not require a second widget language, arbitrary Flutter code, or a Wayland compositor.

Multiple Home cards are supported. The input-bar contribution remains one exclusive slot under the existing placement rules. Adding host attachments does not multiply input bars or change the selected bar implicitly.

### Displaying a widget does not own the job

Widget visibility controls rendering and observation, not the lifetime of a detached host job. Offscreen instances suspend UI refresh and release unnecessary subscriptions. Returning shows the latest retained state and reconnects observation when supported.

Repeated widgets observing the same attachment/resource share a bounded subscription where their query and grants match. Results stay keyed to their attachment; pooling never mixes hosts. Refreshes are coalesced rather than queuing indefinitely behind a slow connection.

A widget shows `LOADING`, `EMPTY`, `OFFLINE`, `STOPPED`, `NEEDS SETUP`, or `ERROR` as appropriate. After a successful render, a later failure can keep the last good view with its last-updated time and a stale indicator. A cached result cannot enable an action that requires current capability or ownership checks.

Instance state, attachment state, and installation state have separate keys. Mount and layout do not perform undeclared side effects. Scheduled or event-triggered host actions are explicit capabilities and setup choices, rather than behavior hidden inside rendering.

### Data is local or target-owned, never implicitly synchronized

| Scope | Examples | Ownership |
|---|---|---|
| Installation on phone | Preferences, saved views, local-only content | Installation and original source identity |
| Attachment on phone | Cached result, selected workspace, target configuration | Installation and attachment UUID |
| Widget instance | Display filter, collapsed state, size preference | Widget instance UUID |
| Host attachment | Job history, host-side plugin records | Authenticated account plus plugin/attachment namespace |
| Existing workspace | Repository files, user's tools and configuration | User-owned host data, not plugin-owned cleanup data |

Attaching the same package to another host does not copy its datasets, secrets, repositories, or history. `DUPLICATE CONFIGURATION` is an explicit action that previews copied non-secret fields and revalidates the destination. An aggregation reads several targets; it is not replication.

Shared dataset access retains the current declared dependency and export-contract model. An attachment cannot accidentally read another attachment's private state through an unqualified dataset name. Migration preserves existing installation-scoped dataset identity rather than moving old data into a newly invented attachment.

Removing a phone installation retains data by default, with clear controls to delete its phone data and request deletion of its own host namespaces. Cleanup never deletes a workspace merely because its path appeared in configuration. Host cleanup can remain pending; the app keeps a visible management route for that state.

### A bundle restore resolves ownership before activation

The existing sealed bundle gains package provenance, retained releases where included, instance layouts, configuration, datasets and reconciliation records. Import reports absent package contents, excluded phone Linux files and unresolved credentials. A bundle with configuration alone does not claim that its target hosts are ready.

By default, importing onto another phone assigns new installation and attachment identities, remaps instance references and leaves restored attachments paused for compatibility/setup checks. Imported SSH keys do not give these new identities ownership of the old phone's jobs or schedules. The original job references remain attributed as imported history, not active controllable handles.

Replacing a phone while retaining remote ownership requires a distinct takeover operation. The engine must inventory the old namespace, fence its prior controller generation and acknowledge the replacement before it activates triggers. Until that protocol exists, restore local data and reattach under new identities. This is an explicit extension to the current bundle's replace-by-ID behavior for the new plugin records; it does not silently rewrite existing host/key import semantics.

## Releases, dependencies, and updates

### A release has one immutable identity

The selected phone release is a content-addressed collection of the manifest, declared Luau files, required package assets, and API requirements. Source branch/tag is a discovery input; the installed release records the resolved revision and digest. Marketplace preview assets have their own bounded metadata and expected digests.

Dependencies have separate meanings: another plugin, an engine service, an installed tool, or a platform capability. The manifest distinguishes them. A plugin dependency is not a package-manager command. Tool availability does not imply a compatible engine service.

Future manifest fields cover target mode, attachment configuration, contribution context, tool/service requirements, and supported job lifetimes. They require a new manifest format. Existing formats keep their original meaning. The format number and exact field schema are assigned in the first implementation increment and reflected in generated SDK artifacts; examples marked as proposed are never passed off as valid current manifests.

### An update is visible before it changes behavior

Updates show the installed and proposed version, changelog, API compatibility, contributions added or removed, configuration migrations, new or broadened capabilities, tool requirements, and affected attachments. Identical grants for unchanged scopes are reused; new scopes or changed authority are reviewed.

There is one selected release per installation in the first model. Per-host permanent version pinning is not introduced. Already accepted jobs retain their original release and input. A widget observes such a job as an older-release job until it finishes.

Phone package activation is atomic after download, validation, and preparation of compatible phone data. Attachment reconciliation is distributed and may be partial. Each attachment records desired and last acknowledged release. An offline attachment becomes `UPDATE PENDING`; new phone requests to it are blocked until reconciliation, without silently falling back to old code. Previously accepted host timers can still launch old-release jobs until their pause or replacement is acknowledged. When such timers exist, the state says `UPDATE PENDING · OLD SCHEDULES MAY RUN`. Other compatible attachments can operate on the new release.

The runtime retains the previous package until active contexts no longer need it. Pending changes revoke old invocation generations. A response created before the update can finish its recorded job but cannot acquire fresh grants through a stale handle.

### Data migration is ordered against old writers

Phone activation prepares a candidate schema and data snapshot or another recorded, recoverable migration. Incompatible old phone writers are stopped or fenced before migration. Validation precedes committing the selected code and readable data together. A failed preparation leaves the previous release usable; a successful phone activation does not claim that host data has migrated.

Each attachment reconciles independently in this order:

1. Check the new release's capabilities, configuration, and grants.
2. Pause or replace old triggers, and obtain target acknowledgement before treating future old-release submissions as stopped.
3. Identify running writers. Before an incompatible migration, wait for them to finish, obtain a terminal result after explicit cancellation, or use a representation compatible with both releases. Otherwise keep the migration blocked.
4. Prepare and validate a recoverable migration of plugin-owned host data. Record its progress and recovery information so reconnecting can resume or diagnose it.
5. Commit the attachment's data and runtime configuration, acknowledge the new release, then activate its requested triggers. A crash between steps remains a recorded reconciliation state.

Old job results retain their original release and schema. They can remain as versioned history without being decoded or written into the new schema. Completion of an old job cannot bypass a writer fence. Arbitrary user programs may still change workspace files; plugin data migration does not make those external effects transactional.

An offline target cannot acknowledge a pause, migration, or new release. A failed attachment migration blocks that attachment and preserves its recovery record while other attachments continue. There is no transaction spanning every host. Migration and rollback support must be declared before offering an update that changes persisted data.

### Rollback is explicit about data

`ROLL BACK` selects a retained compatible release and recomputes the dependency and attachment plan. It can restore code only where the stored schema is compatible. A migration without a backward-compatible representation requires an export or snapshot and a stated recovery path before the update is offered.

The app never promises to undo arbitrary commands or external side effects by rolling back a plugin. Host data migration is a separate recorded operation; an unavailable host cannot be counted as migrated or restored.

Release removal, source removal, and package removal are distinct. A source disappearing does not corrupt installed packages. A release withdrawn from a catalog remains identifiable in Installed, with the source notice and available replacement, rather than silently changing the user's version.

## Development with a coding agent

### The app makes the authoring entry point visible

Installed offers `CREATE WITH AGENT`. Plugin detail offers `CUSTOMIZE WITH AGENT` and, when diagnostics exist, `FIX WITH AGENT`. These use the existing agent launch flow and require a selected coding agent, host, and project workspace. The development host can itself be phone Linux.

The authoring host, execution target, and preview device are different selections. An agent on a laptop can edit a plugin that will execute on a server and render on the phone. Choosing an authoring agent never automatically attaches its machine as the plugin's runtime target.

The create flow asks for the intended job in ordinary language, the desired contributions, and whether the plugin needs a host. It supplies a task description plus exact SDK information. It creates an ordinary editable workspace. A user can inspect or continue that project with any agent or editor.

Customize creates a development copy with explicit origin and separate storage. It does not mutate the installed immutable release or reuse its production grants. Publishing a fork requires a distinct identity unless the author controls the original source.

### The agent receives facts it can act on

The SDK context package contains:

- App/runtime versions, supported manifest formats, and exact API schema digests.
- Available native controls, property types, events, effects, and resource limits.
- Manifest, configuration, capability, listing, and diagnostic schemas.
- A minimal working project for the chosen template, including expected outputs.
- Documented CLI commands and how to reach the selected preview session.
- A capability snapshot for selected targets, with observation age and missing requirements.
- The user's task, selected non-secret configuration, and references to diagnostic artifacts when fixing a plugin.

The context is versioned and available locally and at stable documentation URLs. It is ordinary SDK documentation and machine-readable data, not a generated behavioral policy or a replacement for the user's agent instructions. No Upgrade API key is needed to read it. SSH keys and resolved secrets are not included.

The app offers `COPY DEVELOPMENT CONTEXT` when a direct agent launch is unavailable. The same information works with an agent outside Upgrade.

### One author CLI serves humans, agents, and CI

The proposed command name is `upgrade-plugin`. None of the commands below is claimed to exist yet. The CLI is an optional tool the author installs in their development environment, not a second runtime artifact pushed onto every target host.

| Proposed command | Result |
|---|---|
| `upgrade-plugin init <name> --template <template>` | A minimal project, pinned SDK requirements, fixtures, and a README with working next commands |
| `upgrade-plugin docs --app-version <version> --json` | SDK index and locally resolvable schemas for that app version |
| `upgrade-plugin check --json` | Manifest, Luau syntax/types, imports, capability use, contributions, and compatibility diagnostics |
| `upgrade-plugin doctor --session <id> --json` | Preview connection, app version, target capabilities, tools, and actionable setup gaps |
| `upgrade-plugin preview --session <id> --fixture <name> --json` | Render on the real app renderer and return screenshot, accessibility/layout diagnostics, and artifact paths |
| `upgrade-plugin dev --session <id>` | Watch the workspace, submit revisions, retain the last valid preview, and report new results |
| `upgrade-plugin test --fixtures --json` | Deterministic behavior tests against declared fixture capabilities |
| `upgrade-plugin pack --json` | Immutable package, digest, dependency inventory, and listing-ready metadata |
| `upgrade-plugin publish --dry-run --json` | Publication validation and the exact proposed catalog change, with no remote write |

Commands support stable exit statuses and a versioned JSON envelope. Diagnostics include code, severity, source path, line/column where available, operation, expected/actual value, relevant API version, and a specific next action. A failure is not only an unstructured stack trace.

The checker consumes the same schemas as the runtime. Luau type definitions and examples are generated or checked against that contract. A new API does not ship with a documentation-only name that the app rejects. `check` reports unsupported host/runtime APIs against the selected app version even if the package parses correctly.

The JSON envelope contains `schema_version`, `ok`, `diagnostics`, `artifacts`, and `context`. A diagnostic can name `HOST_TOOL_MISSING`, `CAPABILITY_NOT_GRANTED`, `STALE_SDK`, `UI_OVERFLOW`, or `TARGET_OUTCOME_UNKNOWN` without the agent parsing prose. Human output explains the same result.

### Preview runs in the real renderer

A user starts a development session in Upgrade, selects an author workspace on a registered host or imports a local development bundle, and receives a session ID. Release builds support this explicit workflow; an author should not have to compile Upgrade to build a plugin. The existing debug-origin override can remain an implementation aid but is not the public author experience.

The device initiates the connection using its existing host transport. A session reads the selected workspace and exchanges preview requests/results through a versioned development protocol. The implementation must not require an unauthenticated public listener on the phone. Preview artifacts are written to the selected development session's artifact directory or exported through the app.

Fixture mode is the default preview mode. It supplies predictable empty, loading, success, offline, and failure results, and records requested effects. A separate live mode selects real attachments and their grants. The mode is always visible in the preview. Live actions are real operations; a screenshot result alone cannot be interpreted as evidence that an external action succeeded.

Preview covers a compact phone width, an expanded width, the active theme, a second theme, and larger text. A screenshot records device, viewport, app/SDK version, package digest, fixture, and render outcome. It is produced by the actual Flutter plugin renderer. Static documentation images and fabricated mockups cannot satisfy this check.

Editing a Luau file triggers validation and a new preview revision. Invalid revisions show diagnostics while preserving the last good preview. A valid reload resets ephemeral VM state but preserves explicitly declared development data. `RESET DEVELOPMENT DATA` is separate. Development data never aliases production installation data.

Ending a session closes its local preview subscriptions, revokes new invocations, and requests cancellation of session-bound host jobs. Pending cancellations remain reconcilable after the session closes, including when the target is offline. Only terminal job evidence establishes that execution ended. Detached live jobs remain visible in normal Activity. Development installation identity is distinct from the production package, so testing the same manifest ID cannot overwrite its installed release.

### The agent can finish a complete development loop

The initial templates are a phone-only widget with durable data, a host command page with a result card, and a multi-host dashboard. Each includes fixtures and at least one meaningful behavior test. Tests assert user-visible results and failure handling, rather than repeating every generated field assignment.

The documented loop is: inspect SDK and selected target capabilities; scaffold; implement; check; exercise fixture behavior; render a real preview; inspect its diagnostics and image; try the selected live operation when appropriate; pack; install the candidate locally; then prepare publication.

The UI shows this loop as actual state, such as `PROJECT CREATED`, `CHECK FAILED`, `PREVIEW READY`, or `READY TO INSTALL`. These states come from CLI/runtime results, not from interpreting an agent saying it is done.

`FIX WITH AGENT` assembles the exact failing release, diagnostic codes, relevant logs, reproduction fixture when available, and target capability snapshot. It returns to the same development workflow. A successful repair produces a new candidate release; it does not silently replace the installed one.

SDK documentation includes a task-oriented quick start, API reference, compatibility tables, manifest reference, layout examples, error-code reference, packaging guide, and a guide for moving one plugin between phone Linux and a remote target. Examples are small enough for an agent to read without loading the entire app repository.

### The user can learn the workflow inside the app

`CREATE WITH AGENT` offers `START FROM EXAMPLE` and `DESCRIBE A PLUGIN`. The first path opens a small working example and asks for one visible change. The second collects the intended result and contributions, then chooses a compatible template. Both reach the same development session.

The quick start walks the user through these observable steps:

1. Choose where the agent edits the project and which phone renders the preview. Setup checks CLI, SDK and connection before asking the agent to implement anything.
2. Describe a change, such as showing two repository statuses. The agent receives the exact SDK and fixture context.
3. Open the real preview. The app shows which revision rendered and whether it used fixtures or real targets.
4. Select `INSTALL CANDIDATE`, choose runtime attachments and place a widget. Development grants do not become production grants implicitly.
5. Make a second change, inspect its release/configuration effects and update the local installation. Sharing and publishing remain available after this succeeds.

Every failed step has a usable next action: select a host, install the author CLI, repair an API call, open diagnostics, retry preview, or reconnect to the same project. Leaving the flow preserves its workspace and last good revision. `RESUME DEVELOPMENT` returns to that state without creating a duplicate project.

The first-run guide, CLI help, example README and in-app actions use the same terms. A supported user with an external coding agent can complete the same loop through `COPY DEVELOPMENT CONTEXT` and a paired session. The workflow cannot require an undocumented prompt, a particular hosted agent subscription, or access to Upgrade's source repository.

### Reference packages exercise the public API

Maintain the following examples as ordinary installable packages, each with source, setup, fixtures, expected results and a named maintainer role. They receive no private Dart service or hidden built-in permission. Their releases declare the SDK versions they exercise.

| Package | Coverage | Failure fixture |
|---|---|---|
| HTTP status card | Phone-only HTTP, settings and credential references | Offline, authentication expired, rate limited |
| Repository status | Same command/file APIs on phone Linux and remote Linux; two workspaces on one host | Missing Git, moved workspace, denied operation |
| Agent sessions | Multi-host status, live events, open original session, native terminal contribution | Ended session, stale stream, unsupported adapter |
| Job monitor | Submission, bounded output, reconnect, cancellation and history | Lost submission response, output gap, cancellation race |
| Configured dashboard | Several instances from one package, aggregate view, upgrade and configuration retention | One target offline and one migration blocked |

These packages are release fixtures and useful catalog entries. A stub screen or prerecorded screenshot does not satisfy them. Catalog admission and CI use the same public tooling offered to outside authors.

## Publishing and catalog maintenance

### Publication follows a local working package

`PUBLISH` in a development package opens a publication preparation flow. It verifies package validation, fixture results, preview artifacts, metadata, source availability, and version increase. The user can save the prepared result without sending it anywhere.

The initial submission mechanism is a pull request to a static catalog repository. The agent can prepare the exact listing, package pointer, digest, requirements, release notes, and screenshots. `SUBMIT` is the explicit external action. Existing GitHub authentication belongs to the user's chosen publishing tool; Upgrade does not require a new account system.

Catalog CI runs the same package and metadata checks available to the author, verifies pinned content, and produces a review report. The report identifies operations and requirements; it does not claim arbitrary program behavior has been proven harmless. Review status belongs to the admitted release.

Catalog maintainers can reject incomplete metadata, unsupported APIs, broken links, or missing preview evidence with structured reasons an author can feed back to their agent. Publication does not require a new app build. A new category is catalog data; a new runtime API still requires a compatible app/engine release.

### Sharing preserves identity and configuration boundaries

A share link identifies a package origin and immutable release, optionally a catalog source. Opening it reaches the normal detail/install flow. It does not carry host IDs, private workspace paths, access grants, or credential values.

Sharing a configured example exports a template with named placeholders and sample data. The recipient chooses their own hosts and supplies their own configuration. Large packages are referenced rather than embedded in a QR code. Offline bundle import can use the same verifier when delivered; it is not a separate trust or identity model.

## Compatibility and migration

### Existing installations remain recognizable

The migration assigns installation and instance IDs while preserving existing package IDs, source identities, data keys, disabled states, grants, and contribution placement. It does not infer a host attachment from whichever host was used most recently in a shell.

Existing scheduler bindings can become attachments only when the mapping to a host and namespace is unambiguous. Otherwise the package reads `FINISH SETUP`, retains its old data and pending pauses, and names what must be selected. Host-side owner namespaces are not renamed without an explicit migration and reconciliation path.

Current single-instance widgets gain one instance record each. The input bar keeps its exclusive choice. Packages that never requested hosts continue to run without attachments. A legacy package's own host picker remains supported under its declared API version; adopting the new attachment model requires a new manifest/API opt-in so old packages do not silently acquire different semantics.

The dependency board and new Installed library operate on the same repository. There is no second source of truth for enabled state, grants, dependencies, or placement. Data migration and UI delivery are separate increments with backward-compatible readers as needed.

### Conflicts with the current contract are explicit

| Current decision | Target change |
|---|---|
| Board is the primary plugin screen | Installed becomes primary; graph remains under Dependencies |
| No default catalog source | A named removable curated source is supplied |
| One widget contribution maps to its current placement | Multiple configured instances, preserving the original placement during migration |
| Narrow host capabilities | General execution/files APIs bound to explicit attachments |
| Development origin requires a debug build | Explicit development sessions work in release builds |
| No service WebSockets | Direct user-configured plugin streams, with endpoint and lifecycle scope; no mandatory Upgrade service |
| Conversation hands off to its shell/pane | Capability-based follow-up delivery for supported adapters; existing shell route for the rest |
| Bundle replaces rows by ID | Explicit plugin identity remapping on a second phone; remote takeover requires reconciliation |
| Host engine only, no plugin-specific installed adapter | Preserved; new operations extend that engine |
| Luau on both sides | Preserved as the plugin language contract; host runtime is gated on actual implementation |

The roadmap now schedules author layouts, a curated catalog, phone integrations and later Home/desktop work explicitly. Publisher-signature infrastructure remains a separate choice rather than blocking the initial static catalog. This document defines the plugin contract; [ROADMAP.md](ROADMAP.md#competitive-delivery-program) defines its place in the broader release sequence.

## Delivery sequence and proof

All increments below are planned. P0's minimal loop is delivered; its status lists what remains. None is marked complete by writing this document. Each increment must be usable on its own and update the current product contract when delivered.

### Work packages and dependencies

| ID | Work package | Depends on | Required handoff |
|---|---|---|---|
| P0 | Contract and author-tool foundation | Current manifest/SDK inventory | Versioned schemas, capability inventory, one template, checker and minimal real preview |
| P1 | Installed library and useful discovery | Existing installation repository; P0 for reference package validation | A real curated source and independent local inventory |
| P2 | Attachments and widget instances | P0 | Identity/data migration, context adapters, settings and grants |
| P3 | General execution, live data and session APIs | P2; P0 for an early phone HTTP slice | Advertised engine changes, public adapters and reference packages |
| P4 | Complete authoring with agents | P0; P2/P3 for host examples; P1 for local install management | Create/Customize/Fix, preview/reload, candidate installation and quick start |
| P5 | Publishing, updates and recovery | P1, P2, P4; P3 lifecycle contracts | Catalog submission, migration/rollback and cleanup evidence |
| P6 | Host-side Luau | P0, P2, P3 | Advertised engine runtime and matching fixture/live results |
| P7 | Phone integrations and authored layouts | P2, P4; native platform adapters | Capability coverage, reusable page layouts and recoverable customization |

P1 and P2 can progress independently after their contracts are settled. The minimal P0 author loop ships with the first reference package; authors do not wait for every host API before creating a phone-only widget. P4 completes and documents that loop across targets. P6 does not block plugins invoking existing user tools through P3.

Each package has one accountable subsystem owner and names its schema/protocol owner before implementation starts. The handoff includes affected records, compatibility behavior, error codes, migration/rollback rules and the scenarios that prove the change. A dependency marked planned is not available merely because another package expects it.

### Contract and author-tool foundation

P0 inventories the current runtime, exports its schemas and settles the proposed manifest/API versions. Deliver one phone-only template, a machine-readable checker, and a development session capable of rendering it with fixtures in the actual app. Keep unsupported future APIs visible as unavailable in the capability reference.

Proof: an outside author starts from the documented template, changes a displayed value, sees a real preview, and receives a source-specific error for an invalid property. This proves the small authoring loop without claiming complete host support.

Status: the minimal loop exists in the repository and is described in [SPEC.md](SPEC.md#a-plugin-workspace-previews-on-the-phone-before-it-installs). The pieces are the template under `plugins/templates/phone-card`, the `just plugin` commands (`init`, `docs`, `check`, `preview`), envelope `schema_version` 1, and `DEVELOP PLUGIN` rendering fixtures through `PluginUi` over the pooled host link. The proof scenario ran on an emulator against the fixture VM. P0 is not complete. Still open:

- **Packaging.** The tool runs only from a Upgrade checkout with the Dart SDK; there is no standalone `upgrade-plugin`.
- **Preview coverage.** Cards only, no pages. Effects and datasets are not executed. There is no screenshot artifact. Live mode and reload of an installed candidate do not exist.
- **Diagnostic positions.** Runtime-located diagnostics carry a line, not a column.
- **Proposed manifest/API versions.** Not settled; the inventory reports the current format 5, API 2.1.0 and UI API 2, with the future APIs listed as planned.

P1 can start from the reference package and the checker. Its first step is to validate a curated source's listings with the same check and envelope before they reach Discover.

### Installed library and useful discovery

Deliver Installed, Discover, a real curated source, listing previews, search/filtering, detail pages, and Updates. Preserve the board under Dependencies and migrate no host semantics yet.

Proof: a fresh user can find a real plugin, see what it adds, install it, find it again while offline, disable it, and find its retained data. A failed source does not hide installed packages. An incompatible listing explains the missing API. Built-ins and direct installs remain visible without catalog membership.

### Attachments and widget instances

Deliver stable attachment/instance IDs, per-host configuration and grants, host-detail attachment lists, explicit widget context, and lifecycle state. Integrate existing host capabilities before adding new ones.

Proof: one package attaches to two distinct phone Linux installations and a remote host. Two attachments on one host use different workspaces. Renaming a host changes no ownership. Switching a page target during a pending request cannot put the old response into the new target's card. One host going offline leaves the others usable.

### General host execution

Expose engine execution and file operations to opted-in Luau packages. Deliver tool/capability negotiation, request correlation, bounded output, explicit job lifetime, cancellation, live subscriptions and existing-session views. Add protocol support before claiming deduplication or resumable output. Phone HTTP can ship independently because simple integrations should not require Linux.

Proof: the Repository status, Agent sessions and Job monitor packages use only public APIs on phone Linux and a remote host. A missing engine/tool yields a useful setup result. Disconnecting after submission cannot silently start a second job. A stream gap is visible and recoverable. Opening a terminal returns to the original session. A denied operation remains denied. No host package is installed merely by attaching.

### Authoring with agents

Deliver the CLI, generated SDK contracts, templates, fixture execution, real preview, live development sessions, diagnostic bundles, Create/Customize/Fix with agent, and local candidate installation.

Proof: an author with a coding agent creates a phone-only widget, previews it on the development emulator, installs it locally, then creates a host-backed page/card that works against two prepared targets. A deliberately invalid API call gets a file-specific diagnostic. A UI overflow is visible to the author through the preview report. A development reload cannot replace production data or grants.

### Publishing and resilient operations

Deliver publish preparation/submission, reproducible catalog checks, release comparison, staged update reconciliation, rollback constraints, pending cleanup after removal, and complete diagnostics.

Proof: a package enters the catalog through the documented author process and can be installed without a new APK. Updating with one host offline shows partial reconciliation accurately. Removing a plugin with a remote pause pending leaves a working cleanup record. A rollback blocked by data compatibility explains the required recovery step.

### Host-side Luau and advanced capabilities

Deliver host-side Luau only after the engine implements and advertises a versioned execution contract, resource limits, source/release identity, and storage scope. Invocation can carry a declared source payload through the engine protocol; it does not install a second executable or daemon. The current app must not advertise this runtime merely because the manifest has a runtime-kind field.

Persistent host triggers require an advertised scheduler/supervisor. Advanced file watches and provider-specific capabilities use the same attachment/configuration model. A transport fallback must report reduced guarantees rather than emulate capabilities it cannot provide.

### Phone integrations and authored layouts

P7 exposes the native phone adapters and composition support specified in the roadmap. Users can arrange several plugin instances into named pages, export non-secret layout templates and recover the last valid layout after a broken edit. Package updates preserve instance identity. A theme preview cannot execute a plugin action or change its grants.

Phone capabilities report supported, permission-required, denied, unavailable and policy-restricted states separately. A card with an unavailable optional source remains useful where its manifest declares a fallback. The capability reference lists each supported OS/API level and observed permission behavior.

Proof: an outside author builds a phone-aware widget and a page combining local and remote results. Export/import preserves the recipient's host-selection step. A denied Android permission produces an actionable state. Large text, keyboard focus and Back remain usable after layout changes. Android Home integration is a later roadmap milestone, with its own acceptance gate.

## Acceptance scenarios

| Scenario | Required observable result |
|---|---|
| No hosts configured | A phone-only widget installs and works; host-required setup offers both host creation paths |
| One package, several hosts | One installed row, independent attachments, correctly labeled results |
| Same host, two workspaces | Separate configuration and data; no path inheritance between attachments |
| Foreign agent or job ID | Read, watch, answer, cancel, and cleanup cannot cross the invocation's attachment scope |
| Two phones, one SSH account | Separate default namespaces; plugin cleanup on one phone cannot invoke account-wide teardown |
| Stop one phone environment | Only its attachments lose reachability; card refresh does not restart it |
| Offline attachment | Cached data is labeled stale; other attachments continue; writes are not silently queued for later replay |
| Unknown command outcome | Request/job reconciliation or explicit unknown result; no blind retry |
| Cancellation while offline | Cancel requested remains pending until the target confirms or a terminal result is observed |
| Completion races cancellation | Accepted cancellation alone does not mean cancelled; the actual completed, failed, or cancelled result is retained |
| Development session ends offline | Local preview closes; remote cancellation remains pending and manageable |
| Stream cursor expires | The subscription reports a gap and resynchronizes; old events do not appear as fresh state |
| Credential rotates | The adapter reconnects with the replacement reference; package source and fixtures remain unchanged |
| Private endpoint changes identity | Setup reports the identity change; it does not silently disable certificate validation |
| Open a live session twice | Both routes reach the same session; no extra shell or agent starts |
| Plugin reload while terminal is visible | The UI reload preserves the underlying session identity and releases obsolete observers |
| Follow-up delivery becomes unknown | The draft remains available with unknown status; reconnect does not resend automatically |
| Resume authoring | The original workspace, session context and last good revision are recoverable |
| Restore a layout on another phone | Package/instance relationships survive; target bindings and credentials require explicit resolution |
| Disable with future schedules | New phone calls stop; target pauses acknowledge independently; active jobs are reported separately |
| Remove with pending cleanup | A host cleanup task remains manageable without the removed plugin's code |
| Two sources reuse an ID | Source conflict is visible; an installed package is not overwritten |
| Source unavailable | Installed library and local contributions remain usable; cached discovery reports its age |
| Update with an offline host | New phone release is identified; new phone invocations are blocked there; previously accepted old timers may still run and are labeled |
| Migration with an old writer | Incompatible migration waits for a terminal result or uses a declared compatible representation; old results retain their schema |
| New required permission | Update review names the changed scope before activation |
| Rollback after incompatible migration | Rollback is blocked with a concrete recovery path, not offered as an undo of external work |
| Multiple widget instances | Placement and settings remain independent; matching observations can share work |
| Preview a failing fixture | Screenshot and structured diagnostic identify the failed state and exact candidate digest |
| Agent uses a stale API | Checker reports app/SDK mismatch before the user installs the candidate |
| Agent has no hosted service account | Local scaffolding, checking, fixtures, and preview remain available; public submission uses the user's chosen authenticated tool |
| Fresh unrelated author | The documented workflow works without reading Upgrade's application source |

### What success means to a user

Evaluate with at least three people who did not implement the subsystem, using coding agents they already know. Measure first successful discovery/install, finding an installed plugin again, attaching to a second target, first useful widget, first successful agent-created plugin, and recovery from one real failure. Report where they needed help and the actual device/target setup.

Initial usability targets are finding an installed plugin's state and targets within ten seconds, completing a second attachment within one minute on an already compatible host, and producing a fixture-backed preview of a scaffolded plugin within fifteen minutes excluding tool downloads. These are proposed acceptance targets, not measured claims or promises that an agent can implement any idea in fifteen minutes.

Performance budgets retain the phone runtime's bounded execution and rendering model. Benchmarks must include multiple widgets observing several attachments, a slow target, reconnection, text scaling, and background/foreground transitions. Host-only benchmark numbers do not establish phone responsiveness or battery use.

## Implementation starting points

| Concern | Existing code to extend or reconcile |
|---|---|
| Installation and lifecycle | `lib/application/plugins/plugins.dart`, `lib/platform/plugins/store.dart`, `lib/data/plugins/access.dart` |
| Manifest and package identity | `lib/data/plugins/manifest.dart`, `lib/platform/plugins/index.dart` |
| Management UI | `lib/features/plugins/plugin_management_screen.dart`, `lib/features/plugins/plugin_board.dart`, `lib/features/plugins/plugins_panel.dart` |
| Contributions and placement | `lib/application/plugins/native_plugins.dart`, `lib/data/repositories/plugin_placement_repository.dart` |
| Luau pages and cards | `lib/features/plugins/plugin_page.dart`, `lib/features/plugins/plugin_card.dart`, `lib/features/plugins/plugin_ui.dart` |
| SDK and worker | `packages/upgrade_luau/lib/ui_sdk.dart`, `packages/upgrade_luau/lib/upgrade_luau.dart` |
| Existing host adapters | `lib/application/plugins/plugin_hosts.dart` |
| Phone Linux as a host | `lib/application/phone_linux.dart`, `lib/platform/phone_linux.dart`, Android `PhoneLinux.kt` |
| Connection policy | Policy header in `lib/platform/ssh/connection_supervisor.dart` |
| Engine negotiation and operations | `engine/src/services/lifecycle.rs`, `engine/src/services/run.rs`, `engine/src/services/fs.rs` |

The schema increment introduces explicit installation, attachment, widget-instance, request/job reference, and reconciliation records. Existing records migrate into these identities rather than maintaining parallel legacy and new stores. The concrete tables and transaction boundaries are designed against the then-current Drift schema in the implementation increment.

### Engineering decisions to settle before their increment ships

- Assign the manifest format and API versions; publish generated schemas and validated examples with the implementation.
- Define request deduplication retention and crash recovery on the host, including the acceptance/spawn boundary. This blocks automatic retry of side effects, not the Installed UI.
- Specify the authenticated development protocol and fixture-result format before release-build preview is exposed.
- Select and create the curated source repository and its maintainers before shipping Discover with a default source.
- Measure and set package, preview, output, subscription, and job-history limits. Existing limits remain until a measured revision replaces them.
- Define host-side Luau service compatibility and resource accounting before advertising that runtime.

These are bounded implementation decisions. They do not reopen the user model: one installation, explicit host attachments, independently configured widgets, and a complete authoring loop with an agent.

## Evidence and competitive reference

OmaLauncher establishes a concrete usability baseline: a preview grid, search, category and Installed filters, update indications, and listing details. Its author workflow includes local checking with preview artifacts and agent-assisted submission to a reviewed catalog. Its catalog publishes pinned files and metadata through static hosting. These are source/documentation observations, not a comparative user study.

- [OmaLauncher store implementation](https://github.com/SimonSchubert/omalauncher/blob/main/app/src/main/kotlin/dev/omalauncher/ui/StoreScreen.kt)
- [OWL authoring and sharing documentation](https://github.com/SimonSchubert/omalauncher/blob/main/app/src/main/assets/widgets/README.md)
- [Reviewed widget catalog and publication process](https://github.com/SimonSchubert/omarchy-widgets)
- [OmaLauncher architecture](https://github.com/SimonSchubert/omalauncher/blob/main/docs/ARCHITECTURE.md)
- [Existing Upgrade plugin contract](SPEC.md#plugins)
- [Existing Upgrade phone Linux contract](SPEC.md#the-phone-is-a-host-too-running-linux-of-its-own)
- [Current Upgrade Luau SDK documentation](../packages/upgrade_luau/README.md)

The competitive claim is earned when an outside author can create, discover, install, and operate the same useful plugin on phone Linux and remote hosts with less bespoke integration work. Choosing Luau or having SSH in the app does not establish that result by itself.

## Competitive assessment and remaining gaps

### Scope of the comparison

This is a plugin-platform development plan. Completing it does not establish superiority across every OmaLauncher feature. OmaLauncher is also an Android home replacement and a local Linux graphical environment. Those areas need their own requirements and comparative evidence.

The following assessment inspected upstream main at `ccd9d7fa0722ec57b72d3c08a570c382b90c3fae`, documentation, release metadata, and issue discussions on 2026-10-21. GitHub's release API listed `v0.10.1`; main also contained newer OWL 12 work. Source on main is not proof that the same behavior is in the Play Store build. No comparative device session or performance measurement was performed. Issue reports describe individual observations unless corroborated by source; an open issue alone does not establish a reproducible current defect.

### Strengths that Upgrade must take seriously

| OmaLauncher strength | Evidence | Consequence for this plan |
|---|---|---|
| A short author feedback loop | Saved OWL files reload, `owl-check` returns actual renderer previews and errors, and edit/fix/publish actions launch an agent | Agent support and real previews are baseline requirements; adding a prompt button is insufficient |
| Broad UI authoring | Widgets, complete home pages, full-screen apps, panels, custom keybars, canvas/shaders, and native phone data | Luau's language features do not establish equal UI or device capability coverage |
| Visual discovery | Preview grid, categories, search, installed filtering, update indications and a reviewed public catalog | The first delivery must contain useful real packages and previews |
| Local Linux desktop integration | Arch packages, separate Android tasks for Linux windows, a Wayland compositor and optional supported GPU drivers | SSH execution does not substitute for a compositor or a polished local GUI workflow |
| Coherent customization | Themes apply across the launcher and guest; style and home layout are editable files | Comparable customization needs its own scope and acceptance evidence |

The authoring and contribution observations come from the [pinned author guide](https://github.com/SimonSchubert/omalauncher/blob/ccd9d7fa0722ec57b72d3c08a570c382b90c3fae/app/src/main/assets/widgets/README.md). Desktop behavior comes from the [pinned architecture](https://github.com/SimonSchubert/omalauncher/blob/ccd9d7fa0722ec57b72d3c08a570c382b90c3fae/docs/ARCHITECTURE.md). The [changelog](https://github.com/SimonSchubert/omalauncher/blob/ccd9d7fa0722ec57b72d3c08a570c382b90c3fae/CHANGELOG.md) records layout, styling and release changes.

### The strongest structural opportunities

| Priority | Observed constraint | What Upgrade can offer | What must be demonstrated |
|---|---|---|---|
| First | Widget command services receive one local `Proot`; the documented command/dependency path assumes that Arch environment | Explicit remote and phone-Linux attachments through one API, with per-host capability negotiation | One unchanged package works against two phone environments and a remote machine, with independent setup and results |
| First | Runtime instances and persisted values are keyed by widget filename | Package releases separate from configured instances and host bindings | Three instances share one package update while retaining separate settings, workspaces and data |
| First | Ordinary sources and repeating triggers follow page liveness; local guest processes end with the app | Host-owned detached jobs, durable request identities, pending changes and reconnectable observation | A remote job continues while the phone app exits; reopening finds the same job without duplicating it |
| Next | The store's Installed filter starts from catalog entries rather than the complete local widget inventory | A local Installed library independent of catalog membership or availability | Custom, direct, disabled and delisted installations remain visible after a cold offline launch |
| Next | The documented OWL language and native node set constrain integrations; richer remote clients can require host code changes | Luau modules plus sufficiently general execution, streaming, credential and native-view APIs | A representative live remote-agent dashboard works as a package without changing Upgrade's Dart or native code |

The first row is a boundary in the inspected [command adapter](https://github.com/SimonSchubert/omalauncher/blob/ccd9d7fa0722ec57b72d3c08a570c382b90c3fae/app/src/main/kotlin/dev/omalauncher/widgets/WidgetServices.kt). It does not mean users cannot invoke SSH inside a command or build a remote bridge. The opportunity is product-managed target identity, configuration, jobs and recovery.

Filename ownership appears in [WidgetEngine](https://github.com/SimonSchubert/omalauncher/blob/ccd9d7fa0722ec57b72d3c08a570c382b90c3fae/app/src/main/kotlin/dev/omalauncher/widgets/WidgetEngine.kt) and the [persistence documentation](https://github.com/SimonSchubert/omalauncher/blob/ccd9d7fa0722ec57b72d3c08a570c382b90c3fae/app/src/main/assets/widgets/docs/declarations.md). Copying a file can create another widget, but it also creates another code copy to maintain. The new Upgrade model must prove that updates preserve each instance's configuration.

The lifecycle distinction has exceptions. OmaLauncher's `at` trigger can fire offscreen, and a terminal tile continues offscreen until removed or its file changes. It is inaccurate to say every task stops when its page disappears. Its [trigger contract](https://github.com/SimonSchubert/omalauncher/blob/ccd9d7fa0722ec57b72d3c08a570c382b90c3fae/app/src/main/assets/widgets/docs/declarations.md) and [terminal contract](https://github.com/SimonSchubert/omalauncher/blob/ccd9d7fa0722ec57b72d3c08a570c382b90c3fae/app/src/main/assets/widgets/docs/nodes.md) define these exceptions. Upgrade's own PRoot targets also depend on Android process survival. Stronger continuity requires a compatible remote host or an explicitly advertised supervisor.

The library limitation follows directly from [StoreList](https://github.com/SimonSchubert/omalauncher/blob/ccd9d7fa0722ec57b72d3c08a570c382b90c3fae/app/src/main/kotlin/dev/omalauncher/ui/StoreScreen.kt): its installed rows filter `market.entries`. [Market](https://github.com/SimonSchubert/omalauncher/blob/ccd9d7fa0722ec57b72d3c08a570c382b90c3fae/app/src/main/kotlin/dev/omalauncher/widgets/Market.kt) loads installation records separately but keeps fetched catalog entries in memory. Therefore that store view can omit local custom widgets or delisted items, and has no persisted catalog to rebuild its rows after a cold offline start. This is a source-based consequence to confirm on a device; it does not imply installed widgets cease working.

The extension constraint has a concrete outside-author example. [Issue 174](https://github.com/SimonSchubert/omalauncher/issues/174) describes a remote-agent dashboard implemented in a fork and asks for instance settings, native elements, authenticated streaming and other APIs. Several details in that report have already changed upstream. Its existence supports the integration problem, not every claim in the original report. Upgrade also retains compiled-in native widgets, so a new Luau runtime cannot remove every native integration limit.

### Weaknesses that must not become stale competitive claims

- Main already contains encrypted secret state and password inputs. Do not claim current upstream only stores plaintext credentials. See the [secret-state change](https://github.com/SimonSchubert/omalauncher/commit/ccd9d7fa0722ec57b72d3c08a570c382b90c3fae).
- Home layout became an editable file in the 0.10 series. Do not repeat an older claim that agents cannot edit it. A portable full backup remains a separate question.
- The 0.10.1 changelog records the panels-store crash fix and changes to backup exclusions. Neither a closed crash report nor rootfs exclusion proves the current launcher is generally unreliable.
- The maintainer says local-network permission is already declared and asks for a new reproduction in [issue 166](https://github.com/SimonSchubert/omalauncher/issues/166). The Bluetooth-modifier report was not reproduced on the maintainer's setup in [issue 160](https://github.com/SimonSchubert/omalauncher/issues/160). Neither supports a universal failure claim.

The clearer remaining user reports concern [agent follow-up typing](https://github.com/SimonSchubert/omalauncher/issues/173) and [recovering an existing Linux window](https://github.com/SimonSchubert/omalauncher/issues/157). They justify comparative scenarios for composing a second agent prompt and returning to existing work. They do not establish that Upgrade already handles either better.

### Gaps the plugin plan still has to close

The upgraded target now assigns streaming, credentials, private endpoint trust and native session views to P3, with contracts under [capability coverage](#capability-coverage-has-explicit-delivery-gates). These are planned requirements. Wire schemas, platform implementations and runtime proof remain work for their increments. Downloadable native modules are outside this model.

The authoring templates need a maintained reference set that exercises the proposed model:

- A phone-only HTTP widget with setup and credential references.
- A Git page/card used on phone Linux and a remote host without changing source.
- A multi-host agent dashboard with a route to the original session.
- A long-running job view that survives navigation and reconciles after disconnection.
- Multiple copies of one widget with separate configuration and one shared package update.

Publication readiness includes documentation and continued ownership of those examples. Catalog size alone cannot show that ordinary users can complete those tasks.

Broader product leadership needs the workstreams below. They are now scheduled in [the competitive delivery program](ROADMAP.md#competitive-delivery-program), with explicit exit criteria. This documentation task does not implement them.

| Area outside this plugin contract | Evidence needed before claiming superiority |
|---|---|
| Android home behavior | App launch/search, shortcuts, work profiles, folders, gestures, keyboard and Back behavior on representative devices |
| Phone integrations | An API comparison for media, notifications, alarms, volume, clipboard and application actions, including permission and unsupported-state UX |
| Themes and layout | Theme consistency, user customization, larger text, foldables, editable/exportable layouts and recovery from a broken customization |
| Linux GUI | Window discovery, return to an existing session, clipboard/input, external displays, rendering and supported GPU paths |
| Installation and recovery | Fresh setup, interrupted download, missing tools, storage pressure, backup/restore and an app upgrade with active work |
| Responsiveness and energy | Measured launch time, input latency, memory and battery on matched devices and equivalent workloads |
| Distribution and support | Working download/update routes, maintained docs, understandable errors, diagnostic export and response to reproducible failures |

Requiring the owner-installed engine adds setup and compatibility work on remote hosts. Capability probing, actionable setup and an honest unsupported state must make that cost visible. A remote execution architecture can reduce phone workload, but it does not prove lower battery use without measurement.

### Competitive acceptance is task-based

For each comparison, record exact app builds, devices, host setup, agent/model, package revisions and whether the needed host was already prepared. Run matched tasks with outside authors. Distinguish a task unsupported by the product from one attempted and failed.

| Task | Record |
|---|---|
| Find, install and find a plugin again | Completion, elapsed time, wrong turns, offline behavior |
| Ask an agent to create and fix a useful widget | Manual interventions, failed iterations, preview fidelity, working output |
| Configure three instances and update their code | Data/configuration retained, duplicated code, recovery work |
| Use the same integration locally and remotely | Source changes, per-target setup, target mistakes, partial failure behavior |
| Leave and return to a long-running operation | Actual job identity, result recovery, duplicate submissions, unknown outcomes |
| Compose a follow-up and recover the original session | Input errors, typing support, navigation steps, accidental new sessions |

Win claims name the task and the measured result. The current plan has a plausible advantage in multi-host operation and instance management. It still has to match OmaLauncher's authoring and discovery workflow and earn every reliability or performance claim through implementation.
