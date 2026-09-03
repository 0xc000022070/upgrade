# HOTLINE — MVP UI / ART DIRECTION SPEC

Source of truth for design + MVP scope. Primary visual reference: `design/references/concept/hotline-concept-v0.png` (AI-generated concept, treat as direction, NOT pixel spec; fix its typography/alignment/icon/spacing inconsistencies).

## 1. Product
- Name: Hotline. Personal control plane. Local-first, single-user MVP, mobile-first, Flutter.
- MVP scope: Projects, Goals, Tasks, Inbox, Notes, Activity, Global search.
- Future (do NOT implement, but visual system must grow into it): E2E encrypted comms, priority/critical comms, device coordination, sync, vault, system/service status.
- Core idea: user's direct line to what matters: objectives, pending actions, context, activity, later trusted comms. Must feel like a real tool, not a gamified task manager.

## 2. Reference qualities to preserve
dark high-contrast; dense but readable; strong typography; restrained tactical/HUD character; hard-edged hierarchy; subtle system/terminal influence; custom iconography; compact navigation; functional composition.

## 3. External influences (language only, never copy assets/logos/icons/layouts/fonts)
- Watch Dogs 2 DedSec UI: objective hierarchy, black/white contrast, strong section headers, unconventional icons, information density, deliberate irregular details. NOT hacker parody (no graffiti, fake terminal jargon, hex strings, fake hacking, glitch everywhere).
- Ghost Recon Breakpoint: tactical info organization, compact status, objective/state/metadata hierarchy, modular panels, utility-first HUD, compact symbolic language.
- Control: severe typography, institutional confidence, graphic simplicity, strong geometry, signage, black/white/limited accent, restrained brutalism, structured blocks.
- Real systems: avionics displays, tactical radios, industrial control panels, SCADA/HMI, emergency comms equipment, technical diagrams, equipment labeling, signal diagrams, wayfinding, instrumentation. These keep it from becoming fake sci-fi.

## 4. Anti-slop (forbidden by default)
Lucide or Lucide-like icons; generic outline icon sets; glassmorphism; blue-purple / purple-pink gradients; pastel blobs; giant blurred lights; excessive glow; generic SaaS cards; huge radii; excessive pills; giant one-stat cards; fintech/Notion/Linear/crypto-dashboard aesthetics; floating widgets; decorative charts; arbitrary futuristic numbers; meaningless HUD decoration.
Rule: if an element does not communicate hierarchy, state, interaction, identity or useful context, remove it.

## 5. Identity
Feeling: technical, controlled, direct, serious, personal, highly functional, slightly unconventional, tactical without military cosplay, futuristic without sci-fi clutter.
Keywords: signal, control, connection, routing, status, structure, intent, priority, acknowledgement, system, local, trusted.

## 6. Color
```
background.primary   #08090B
background.secondary #0B0D10
surface.primary      #111317
surface.secondary    #15181C
border.subtle        #252A31
border.normal        #2E343C
text.primary         #E8E8E3
text.secondary       #9A9FA6
text.muted           #6F767F
text.disabled        #50555C
accent               #B7FF2A   (alt, less aggressive: #A7D91E)
warning              #D6A34B
danger               #B84A4A
info                 avoid blue unless functional
```
Rules: accent sparse; screens overwhelmingly neutral; accent = active/progress/selection/important status; no neon decoration; no large colored surfaces.

## 7–8. Typography
Font in reference is unknown; do not treat as identifiable. Use real, legally usable fonts.
- Display/headers: condensed, strong, industrial, uppercase-friendly. Candidates: Barlow Condensed (first experiment), Teko, Oswald, Bebas Neue, Rajdhani. No distress textures on normal UI text (rare branding only).
- UI/body: IBM Plex Sans, Barlow, or Inter. Practical.
- Technical metadata: IBM Plex Mono or JetBrains Mono. Timestamps, IDs, state values, small readouts. Not the whole UI.
Hierarchy: Display (rare hero, condensed uppercase); Screen title 24–30px condensed medium/bold; Section heading 12–14px uppercase tracked; Item title 15–17px medium/semibold; Body 14–16px; Metadata 11–13px mono or condensed. Readable on normal phones; never sacrifice usability for HUD imitation.

## 9. Geometry
8px grid; allowed spacing 4/8/12/16/24/32/40. Corners mostly 2–8px, square OK, no large radii. Borders thin 1px, used actively to organize. Shadows minimal; prefer border/surface contrast. Panels flat, compact, structured; not every section is a card. Prefer separators/grouping/alignment/typography over nested containers.

## 10–13. Iconography
NO LUCIDE (not dependency, reference, placeholder, or inspiration). Original Hotline vector system: geometric, angular, technical, compact, schematic, internally consistent, minimal rounding, recognizable at 16–24px, not cyberpunk glyphs.
Primitives: brackets, nodes, lines, routed paths, frames, signal waves, diamonds, triangles, crosses, squares, broken/open geometry, directional markers.
Initial set:
- Navigation: home, projects, inbox, activity, search
- Entities: project, goal, task, note, event, attachment
- States: done, pending, active, blocked, warning, failed
- Future: message, channel, priority, critical, acknowledged, encrypted, verified, device, sync, relay, vault, connection
Workflow: FIRST an exploration sheet of ~20–30 glyph experiments from the primitives; select a grammar; THEN derive the family. Define base viewBox (suggest 24x24), stroke (~1.5–2px equiv), corner behavior, fill rules, optical padding, min size, alignment grid; mostly square/angled terminals; stroke+solid mix allowed if systematic. All icons must look authored by one system.
Research categories: tactical HUD glyphs, avionics symbology, technical diagrams, telecom symbols, industrial labeling, map symbols, signal routing, radio interface symbols, equipment status icons, geometric wayfinding. Games = visual research only; never extract their SVGs/textures.

## 14. Asset strategy
```
design/
  references/    external research, never shipped
  explorations/  icons/ layout/ typography/ textures/   (agent-generated exploration)
  production/    icons/ textures/ branding/             (approved, Hotline-owned)
```
App ships only assets with safe licensing/provenance.

## 15. Texture
Allowed, extremely restrained: subtle noise, slight print/scanner texture, fine grid, faint scanline, tiny signal distortion. Forbidden: giant glitch overlays, RGB split everywhere, grunge on normal text, unreadable surfaces, usability-harming CRT. Texture belongs to backgrounds, branding moments, transitions, empty states. Never on important text or controls.

## 16. Motion
Quick, deterministic, sharp, controlled. 100–220ms; short opacity; short directional movement; controlled panel reveal; subtle signal pulse; progress interpolation; occasional scan transition. No bouncy springs, overshoot, toy movement, particles, constant animation, huge glitch transitions. Motion communicates change/connection/new info/state transition/hierarchy.

## 17. Navigation
Bottom nav: HOME, PROJECTS, INBOX, ACTIVITY, SEARCH. Custom icons, icon + label, strong active / understated inactive. No floating center button, no iOS pill container unless justified. Active: accent, small indicator line, or partially filled icon. No glow.

## 18. Home / Today (highest-value screen)
Answers: what am I working toward / what next / what is blocked / what changed.
Sections: ACTIVE GOALS (project name, goal title, progress); NEXT ACTION (exactly one, project context, optional effort); BLOCKED; RECENT. No vanity metrics.

Screen title is `TODAY`, nothing else in the header. No date, no clock, no day-of-week readout: the OS status bar already shows the time, and a date line is redundant noise (user feedback 2026-09-01). General rule for every screen: never repeat information the system UI already displays.

## 19. Projects list
Name, state, current main goal, progress, next action or blocker. Not oversized cards. Examples: Cuentacero, Infra personal, Rommy, Dotfiles.

## 20. Project detail
Fields: name, short description, status, priority, optional date. Sections: MAIN GOAL, GOALS, TASKS, NOTES, RECENT ACTIVITY.
Example: Infra personal → goal "Reduce SaaS dependency" → tasks: Postgres propio, Redis propio, Object storage, Backups externos, Monitoring. Task states: todo / doing / blocked / done.

## 21. Inbox
Zero-friction capture: enter text, save immediately, no classification at capture. Item can later become task/note/project/goal. Sections: capture field, unprocessed, processed. Examples: revisar pgbouncer; idea para Rommy; comprar cable USB-C; probar paquete de Nix. Capture must be exceptionally fast.

## 22. Activity
Chronological system history (audit stream, not social feed). Events: task completed/updated, note created, project updated, goal progress changed.
```
12:35  TASK COMPLETED   Postgres propio            Infra personal
11:47  GOAL UPDATED     Reduce SaaS dependency     40% → 50%
```

## 23. Search
Global across projects, goals, tasks, notes. Results show entity type + context.
```
BACKUP
TASK  Backups externos   Infra personal
NOTE  Backup strategy    Infra personal
```

## 24. Concepts
Inbox = capture now, organize later. Task = actionable item with context/state. Goal = desired outcome. Project = container/context. Note = reference/information.

## 25. Writing style
Concise, utilitarian. Good: Today, Active, Blocked, Recent, Next Action, In Progress, Processed, Search, Priority, Completed. Bad: OPERATION BLACKFIRE, TACTICAL EXECUTION MATRIX, MISSION CRITICAL STRIKE, THREAT LEVEL DELTA.

## 26–27. Future comms constraints (design for, do not build)
Concepts: Messages, Channels, Priority/Critical comms, Encrypted, Verified, Delivered (device received), Read (opened), Acknowledged (explicit confirm). Priority levels NORMAL / PRIORITY / CRITICAL; critical distinct without turning app red.
Motifs: direct lines, routing paths, connections, signal interruption, nodes, transmission, acknowledgement, endpoints. Not: telephone graphics everywhere, rotary clichés, chat bubbles as dominant identity.

## 28–29. Flutter
Custom design system, not default Material. Tokens: colors, typography, spacing, radii, borders, motion, icon sizing.
```
lib/
  app/
  design/  colors.dart typography.dart spacing.dart motion.dart components/ icons/
  features/ home/ projects/ inbox/ activity/ search/
assets/ icons/ textures/
```
Icons: SVG via flutter_svg. Never substitute Material/Lucide icons because faster. Placeholders only during isolated functionality work, never final.

## 30–33. Architecture
Fully local: no auth, backend, cloud, websocket, sync. Flutter → application layer → repositories → SQLite (Drift). IDs: UUIDv7 or ULID from day one.
Entities:
- Project: id, name, description, status, priority, createdAt, updatedAt
- Goal: id, projectId, title, description, status, progress, createdAt, updatedAt
- Task: id, projectId, goalId?, title, description?, status, priority, nextAction, dueAt?, createdAt, updatedAt
- Note: id, projectId?, taskId?, goalId?, content, createdAt, updatedAt
- InboxItem: id, content, processed, createdAt
- ActivityEvent: id, entityType, entityId, action, payload, createdAt
Task states: todo, doing, blocked, done (no more). Goal progress: pick manual OR computed-from-tasks, one behavior consistently. No dependency/weighting logic.

## 34. Branding restraint
Must be distinctive with no logo, no accent, monochrome icons. Identity from typography, geometry, composition, icon grammar, hierarchy, interaction.

## 35. Quality bar (every screen)
1 primary action visible in ~1s; 2 every panel necessary; 3 can a container become spacing; 4 any decorative element; 5 looks like generic AI dashboard?; 6 works in monochrome?; 7 readable on real phone?; 8 icons consistent?; 9 tactical influence credible?; 10 feels like Hotline, not a game-UI collage?

## 36. Objective
Private, local, high-signal control surface for one person's projects, goals, context and later trusted comms. Target is NOT "video game UI as an app"; it is a real tool whose visual language absorbed tactical interfaces, industrial systems and strong game UI.

## 16b. Motion identity: glitch as event (amendment 2026-09-01)

The user wants the hacker character: icons that glitch, screens that scan in, things that act on their own. Reconcile with 4/15/16: **glitch is an event, never a state.** Every effect must be triggered by a real change or a scheduled system tick, be over in under 400ms, and be deterministic (seeded, same input = same frames). No infinite loops, no random jitter on idle text, no RGB split. Palette for all effects: text.primary, text.muted, accent. Reduce-motion setting disables everything below except opacity fades.

Vocabulary (implemented in Flutter, no shaders required):
- **Icon glitch**: 3-5 frames over 180-260ms. Frames: horizontal slice displacement (2-3 bands, 1-3 px offset), one frame of the icon replaced by its "signal" variant (nodes only, routes hidden), one frame at accent color, settle. Triggers: state change of the entity the icon represents (task todo→done, doing→blocked), nav tab becoming active, a capture landing. A capture landing fires on the capture panel's own target glyph as well as the HOME nav icon: with the IME up the nav bar is covered, so the glyph under the thumb is the only visible landing (ruling 2026-09-01). Once the entity leaves its list (done toggle), the row is held in place for the glitch duration (220ms) while the write goes out immediately.
- **Text decode**: screen titles and section headers resolve on entry: 2-4 characters cycle through a small mono glyph set (`/ \ | - _ ▪ ▫ ◆`) for 120-200ms then lock, left to right. Only on screen entry and on data refresh; never on scroll.
- **Scan reveal**: a 1px accent line sweeps a panel top→bottom over 220ms as its content fades in; used for the NEXT ACTION panel, search results arriving, and project detail entry. Optional scanline texture at ≤4% during the sweep only.
- **Signal pulse**: LIVE/active indicators pulse once per 4s (not continuous sine): 80ms up, 200ms down. Progress bars snap-then-settle: jump to 90% of delta in 60ms, ease the rest over 160ms, diamond head marker flashes accent for one frame.
- **Autonomous ticks** ("it just goes and does it"): a scheduler fires low-frequency micro-events so the tool looks like it is running, not idle: every 20-40s (seeded, per screen) exactly one of: the mono clock readout re-decodes, one metadata value flickers to muted and back, the active nav icon does a 2-frame slice glitch, the LIVE dot pulses. Never more than one at a time, never on text the user is reading (input fields, the row under a touch), paused while scrolling or typing.
- **Transitions**: tab switch = 140ms fade with a single 1-frame horizontal slice on the incoming screen title. Push = existing 220ms fade+2% slide plus scan reveal on the primary panel.

Forbidden still: constant flicker, glitch on body text, screen-wide displacement, particle noise, effects that delay input readiness, anything over 400ms.

### 16b.1 Static background (amendment 2026-09-01, user feedback)

Exception to "glitch is an event, never a state": the scaffold background noise may be ANIMATED as TV static. Rules:

- Source is the existing alpha-only tile `noise-fine.png`. Animate by jumping the tile OFFSET to a new random (x, y) each frame. Never regenerate pixels, never a shader, never a GIF/video.
- Frame rate 8 fps by default (Timer.periodic, never a Ticker: a Ticker requests a frame per vsync and the 2026-09-01 build idled at ~49 fps because of it), 8-12 allowed. Low rate is what makes it read as static instead of smooth drift.
- Opacity stays at the texture table value (4%). Static is felt, not seen. If a screenshot makes it obvious, it is too strong.
- Pauses when the app is not in the foreground, when the device is in battery saver, and whenever the OS reduce-motion flag is set. In those cases the tile is drawn once, unmoving.
- Static lives on the scaffold background only. Panels, rows, sheets and text never carry it.
- Debug toggle in settings later; default ON.
- Thermal ruling 2026-09-01 (user: faraday warmed up after the static landed, was cold before): the static is a thermal bug until measured. Budget: CPU delta ON vs OFF under 3% on the emulator, frame count equal to the tick rate (about 600/min at 10fps), repaint confined to the background layer. Implementation rules: the background sits under its own RepaintBoundary and a tick rebuilds nothing above it; the tile is drawn as a GPU-tiled ImageShader over one rect ("never a shader" above means no procedural noise, GPU tiling of the same bitmap is allowed); 8fps is acceptable if 10 fails the budget. Additional pause gate: PowerManager thermal status at MODERATE or worse, merged with battery saver into one `throttle` platform stream. Measured 2026-09-01 on the emulator (release, idle on HOME): 16.5% CPU at ~49 fps before, 5.3% at 8 fps after, 0% while throttled; the grain paint itself costs ~0.2%, the rest is the emulator's per-frame floor, so the 3% budget is waived on the emulator.

### 36b. Launcher icon (amendment 2026-09-01, user feedback)

The launcher icon is an EMBLEM and is exempt from the UI icon grammar and from the flat/no-texture rule. Direction: tactical patch, raven carrying an AKM, composed like `design/references/branding/raven-patch-ref.png`. Grain/white-noise texture on the emblem is wanted, visibly, not at the 4% UI level. Still monochrome plus one accent. The monochrome (themed icon) layer stays a clean silhouette without grain.

Chosen 2026-09-01: `design/explorations/branding/app-icon-sheet-06-raven-akm` variant B (olive shield #3E4A3A, greige #C9CBC4 outline, crosshair, diving raven with AKM in talons), grain 16%. Production layers live in `design/production/icon/`, PNGs mirrored to `assets/icon/`.

### 16c. Watch Dogs 2 translations (amendment 2026-09-01, user reference video)

Reference: WD2 boot sequence, login bar, main menu, in-game phone. What transfers, mapped onto our tokens:

1. BOOT LOG. Cold start shows a real log, not a fake one: open db, run migrations, count projects/goals/tasks, load fonts, "mounted device <model>". Mono 12, textMuted, status tokens `ok` in accent. Lines appear at 40ms each minimum (floor, ruling 2026-09-01: a 120ms roll read as a flicker), total capped at 600ms, then hard cut (no fade) to Home. Never blocks past the cap: if the app is ready earlier, remaining lines still roll at the floor cadence; if it is ready later, the log waits on the real step and the cap flushes whatever is left. The Android 12+ splash exit animation is removed (hard cut) so the log is not composited under the fade. Reduce-motion: skip entirely. Warm starts (resume) never show it.
2. SOLID ACTION BAR. Primary CTA = full-width flat block filled with accent, text in bg color, mono uppercase. No border, no radius beyond 2. Used for: capture submit when the field has text, the first (recommended) action in the inbox triage sheet, destructive confirm buttons (state color instead of accent). Not for navigation.
3. SELECTED ROW = BLOCK. In pickers and action sheets the focused/recommended row gets a solid accent block with inverted text, plus a `// ` prefix in mono. Everything else stays text on bg. Tab bar keeps its current accent text + top rule.
4. TEXT SMEAR. Screen title on tab change: 1-2 frames of horizontal slice displacement (same primitive as icon glitch, §16b), then settles. Under 120ms.
5. DITHER FIELD. Empty states and the boot screen background use an ordered-dither dot field (Bayer 4x4, 1px dots, textMuted at 12%) instead of blank space. Static, never animated. Complements the noise tile, does not replace it.
6. DOT SPINNER. Loading indicator = 3x3 grid of 2px squares, one lit at a time, clockwise, 80ms step. Only when a wait exceeds 200ms.
7. BRACKET LABELS. Detail-screen field labels may use `[ LABEL ]` mono form for the key facts (objective-style): `[ GOAL ]`, `[ BLOCKED BY ]`, `[ EFFORT ]`. Section headers keep the tracked uppercase form; brackets are for inline facts only.
8. BUILD STRING. Version + short build id in mono at the bottom of Settings only.

Does NOT transfer: magenta/cyan pixel art, spray-paint logo, glow, the light-grey bottom strip, any motion longer than §16b limits.

## 37. Scope cut (2026-09-01, user decision). OVERRIDES §§4-6, 18-24 where they conflict.

Reason: the app was becoming a personal Jira. The job is four questions (doing, next, stuck, dump an idea) and nothing else.

### Entities
- **Project**: name, description, `objective` (one line, the old "main goal"), status (active/paused/archived), priority (low/normal/high). Progress = done tasks / all tasks of the project. Zero tasks = 0%.
- **Task**: title, `projectId` NULLABLE, `done` bool, `blockedReason` nullable text (non-null = blocked), `isNext` bool (at most one true across the db, enforced in the repository), optional effort. No status enum. No "doing".
- **Note**: unchanged, belongs to a project.
- **ActivityEvent**: unchanged, still written in the same transaction as every mutation. Powers RECENT only.
- REMOVED: Goal, InboxItem. An "inbox item" is a Task with `projectId == null`.

### Navigation
Two tabs: HOME, PROJECTS. Activity and Search tabs removed. Search may return later as a field on Projects, not a tab. The activity stream is only visible as RECENT on Home.

### Home
Sections in order: NEXT ACTION (the `isNext` task; if none, the first open task of the highest-priority active project, labelled as a suggestion), PROJECTS (max 3 rows: name, objective, progress; "+n more" to the Projects tab), BLOCKED, LOOSE (tasks with no project, newest first), RECENT (last 5 events). Capture field pinned at the bottom of Home above the nav, always visible, WD2 login-bar style (§16c.2): typing + submit creates a loose Task. Never submits empty text.

### Project detail
Title, `[ OBJECTIVE ]` line, progress bar with n/m, then tasks in two groups: OPEN (blocked ones show their reason in warning color, the `isNext` one carries the accent arrow) and DONE (collapsed by default). Row tap toggles done. Long-press or trailing action opens a sheet: Set as next / Block with reason / Unblock / Move to project / Delete. Notes section below tasks.

### Loose task actions
From Home LOOSE rows: Move to project (picker), Set as next, Delete. No "processed" state.

### Migration
Pre-release, no user data: bump schema version and recreate; no migration path required. Seed data updated to the new model.

## 38. Visual re-alignment to the concept (2026-09-01). OVERRIDES §§7-15, 17 and every layout rule that conflicts.

The reference is `design/references/concept/hotline-concept-v0.png`, frames 1 and 2. The build drifted into an open, sans-serif, hairline-separated feed. The concept is a dense TUI dashboard of bordered panels. Rules:

1. PANELS EVERYWHERE. Every section on every screen is a Panel: 1px border (borderNormal), radius 2, surfacePrimary fill, 8px inner padding. The section header is a strip INSIDE the panel, filled one step lighter than the panel (surfaceRaised), full panel width, rule under it: mono 11 uppercase tracked, textMuted, with a right-side affordance (count, `VIEW ALL >`, `1 >`, `ALL +`) in the same style. Panels stack with 8px gaps. No bare section headers, no hairline-only separation between sections.
2. MONO DOMINANT. Screen titles: Barlow Condensed with a trailing `_` cursor (`TODAY_`, `PROJECT_`). Everything else is IBM Plex Mono: row titles 13 w500, row subtitles 11 textMuted, values 11 right-aligned, labels 10 uppercase tracked. IBM Plex Sans is reserved for long-form note bodies and descriptions only.
3. DENSITY. Rows are content-driven on a 4px rhythm (10 padding, 4 line gap: about 40/57/70 for one/two/three lines); the row box is the tap target. Panel gap 8, screen side padding 16. Rhythm is 4px based inside panels.
4. ROW ANATOMY. Left: 14px glyph (checkbox, node, warning) when the row is actionable. Middle: title over subtitle, both mono. Right: one value column, mono 11, right-aligned: percent, duration, time, count. Progress bars are SHORT and inline on the right (48-64px wide, 2px tall) next to the percent, never full-width under the row. A diamond node at the far right marks rows that open something.
5. HEADER CHROME. Top of every screen: a breadcrumb line `/ PERSONAL CONTROL PLANE` mono 10 textMuted, then the title with cursor. On Home the screen title row may carry a small mono toggle on the right (`FOCUS MODE OFF`) only if it does something; otherwise nothing. No clock (§18 stands).
6. HERO CARD ON DETAIL. The screen title is the project name with cursor (`INFRA PERSONAL_`), breadcrumb `/ PERSONAL CONTROL PLANE / PROJECTS`. The hero card below it: large project glyph (32px, signal-node grammar) on the left, description mono 11 muted; the name is NOT repeated in the hero. A STATUS row (`STATUS` left, value right) appears only when the project is paused or archived. Then the OBJECTIVE panel with the big percent (Barlow Condensed 28, accent) and `n OF m TASKS` mono under it.
7. TEXTURE. Keep the noise/static background. Panels may carry a 2% grid tile. Small ASCII/dither blocks are allowed as decoration inside a panel corner (e.g. the sparkline block in the concept) only when they encode real data.
8. NAV. Two tabs stay (§37). Style per concept: glyph over mono 9 label, accent on active, thin top rule segment over the active tab.
9. CAPTURE BAR on Home is a Panel like everything else: header strip `CAPTURE / QUICK ADD`, then the field line with a mono placeholder and the accent target glyph on the right.

Everything in §16b, §16b.1, §16c (motion, static, WD2) still applies on top of this skin.

Rulings 2026-09-01 (re-skin review): no diamond node on project rows; RECENT and STATUS carry no `>` (nothing to open); the next-task arrow sits in the trailing column; row overflow actions are long-press only; no Sans outside the action sheet; project detail is a pushed route without the nav bar.

## 39. Faraday review round 1 (2026-09-02, user feedback). OVERRIDES §37 and §38 where they conflict.

User verdict: "good as far as it goes". Data now exists on faraday. Findings: nothing can be created or edited, LOOSE reads twice on Home, NEXT ACTION reads as a mock, BLOCKED reads as read-only decoration, captured text cannot be re-read, filed or given links, and the launcher icon reads as a badge.

### 39.1 Entities (additive; §37 entities stay, columns are only added)
- **Goal** (returns, lightweight): id, `projectId`, title, `createdAt`, `order`. Progress = done items / all items under it. A project has zero or more goals. Project `objective` stays as the one-line statement; it is not a goal.
- **Task** (the single item type, UI word depends on where it sits): + `goalId` NULLABLE (references Goal), + `bundleId` NULLABLE text. Location is derived: `projectId == null` = a **drop** on Home; `projectId != null && goalId == null` = a **drop** inside the project; `goalId != null` = an **idea** under that goal. `done`, `isNext`, `blockedReason`, `effort` unchanged.
- **Link** (new table): id, `taskId`, `url`, `label` nullable, `createdAt`. An item has zero or more links.
- **Bundle**: items sharing a non-null `bundleId` always travel together: moving one moves all, they render adjacent in every list, and the quick view lists the mates under `[ WITH ]`. Pairing is symmetric; unpairing clears the id on the item only. No bundle entity, no name.
- Vocabulary: "LOOSE" is gone. Headers say DROPS (Home: unfiled; project: goal-less), GOALS (per-goal panels). No "idea" or "task" appears in headers; rows are rows.

### 39.2 CRUD (everything the user can see can be created, edited and deleted)
- **Project**: `NEW +` affordance in the PROJECTS panel header (Home and Projects tab) opens a full-screen form (pushed route, no nav): name, description, objective, status, priority. Detail screen header carries `EDIT` in the breadcrumb row; the same form prefilled. Delete lives at the bottom of the edit form as a solid warning block with an inline confirm (`DELETE PROJECT` becomes `CONFIRM DELETE` for 3s). Deleting a project un-files its items (they become Home drops), it never deletes them.
- **Goal**: `NEW +` in the GOALS area of project detail; inline single-line editor at the top of a new panel, submit on enter. Long-press the goal header strip: Rename / Delete (items fall back to the project's DROPS).
- **Item**: editable in the quick view (§39.4). Delete with inline confirm in the same place.

### 39.3 Home (replaces §37 Home)
Sections in order: NEXT ACTION (only when an `isNext` item exists; no suggestion fallback, the panel is absent otherwise), PROJECTS (as before, header carries `NEW +`), DROPS (unfiled items, newest first, bundles adjacent). BLOCKED panel and RECENT panel removed from Home. Activity events keep being written; nothing displays them for now. Blocking stays reachable from the item quick view and the reason still renders in warning color on the row; it is no longer a Home section.

### 39.4 Item quick view (replaces "row tap toggles done")
Row tap opens the item quick view: a bottom sheet in Panel style, header strip = location breadcrumb (`DROPS`, `INFRA PERSONAL / DROPS`, `INFRA PERSONAL / REDUCE SAAS`). Body: full title, mono 13, unclipped, editable in place (tap the text to edit, blur or submit saves); `[ LINKS ]` list, each row = label or host, mono 11, tap opens the browser via url_launcher, trailing `x` removes, `+ LINK` row at the end (pastes clipboard if it holds a URL, otherwise opens a one-line URL field); `[ WITH ]` bundle mates when any; `[ BLOCKED BY ]` reason when blocked; `[ EFFORT ]` when set. Footer: one row of solid action blocks per §16c (`DONE`/`UNDO`, `NEXT`/`UNSET`, `MOVE`, `PAIR`, `BLOCK`/`UNBLOCK`, `DELETE` with inline confirm). Long-press on a row opens the same sheet (no separate action sheet any more). Done can also be toggled without opening the sheet by tapping the left checkbox glyph (hit area 40px); the §16b glitch and row hold still apply. The sheet is the one modal in the app; nothing else may be modal.

### 39.5 Move and pair
- **MOVE** opens a target picker sheet: `DROPS` (unfiled) first, then every active project as a header row followed by its goals indented one level. Paused projects follow, archived are absent. Picking a project files the item as a project drop; picking a goal files it under the goal. A bundle moves whole.
- **PAIR** opens a picker of items (drops and ideas, open first, newest first, excluding the item and its current mates), search field on top. Picking joins bundles (union). `UNPAIR` replaces `PAIR` when the item is in a bundle.

### 39.6 Capture bar (extends §38.9)
When the field gains focus a toolbar row appears between the header strip and the field line: `+ LINK` block (same clipboard rule as §39.4) and a `→ DROPS` target block that cycles to any project or goal through the same picker as MOVE; the target resets to DROPS after each submit. Attached links show as small chips over the field. URLs typed inline are extracted on submit into Link rows and stripped from the title only when the title would otherwise be empty; else the title keeps the text as typed. Submit creates the item at the chosen target with its links in one transaction and fires the landing glitch as before.

### 39.7 Migration (replaces §37 Migration; faraday holds real data)
Schema version 3. Drift `onUpgrade` from 2 adds `goals`, `links`, `tasks.goal_id`, `tasks.bundle_id`. Nothing is dropped or recreated. Proof before any install on faraday: the emulator runs the current v2 build, gets seeded through the UI, then receives the v3 build as an upgrade install; every pre-existing row must still be there. Faraday only ever receives upgrade installs with the same signing key; `adb uninstall` and `pm clear` on faraday are forbidden.

### 39.8 Launcher icon (replaces §36b)
The raven+AKM shield is rejected: it reads as a badge. Direction: a minimalist emblem in the register of the Diamond Dogs mark (`design/references/branding/diamond-dogs-emblem-ref.png`, language only per §3): one animal head in hard-edged flat line art, single color on a flat dark ground, geometric frame, nothing photographic, no grain, no gradients, no weapon, no text. Subject stays the raven. Frame must not be a diamond or a shield. Deliver an exploration sheet of 4 variants first; production layers after the pick, with the 66dp safe-zone inset baked into the foreground, a monochrome PNG with real alpha, and no wrapper SVGs.

### 16b.2 Glitch language reference (2026-09-02, user reference: Public Memory, Wuthering Drum cover, `design/references/glitch/wuthering-drum-cover.jpg`)
The cover is the target look for every glitch in the app, motion and static. What it does, and what §16b's "horizontal slice displacement" must become:
- BLOCKS, not slices. Displaced regions are rectangles with independent height (from 1/64 to 1/4 of the glyph) and width (rarely the full width; most blocks span 1/8 to 1/2), shifted sideways by 1/32 to 1/6 of the glyph width. Blocks may overlap.
- MOSH. One or two blocks are copies of a different region of the same glyph (or of the neighbouring pixels), not just shifted originals, so a piece of the shape appears where it does not belong.
- FRAGMENTS. Two or three small blocks detach fully from the shape and sit in empty space next to it.
- PER-BLOCK TONE. Each block shifts luminance up or down one step (light block over dark ground, dark block over light). The accent frame of §16b stays as the single color event.
- GRAIN. The §16b.1 static already supplies grain behind everything; the glitch adds none of its own.
- Icon animation frames per §16b stay 3-5 over 180-260ms; each frame is a new random block set, the last frame is the clean glyph. Screen-level events (boot, project detail entry) may use the same language at panel scale.
Static application: the launcher icon may carry one frozen glitch state of its silhouette (§39.8 variant E). Ruling: the glitch must read as a deliberate corruption of a clean shape, so the un-glitched shape stays at least 70% intact.
Implementation rulings (shipped 2026-09-02, versionCode 10): §16b's nodes-only signal frame is dropped (on a 20px glyph it left none of the shape); five frames at 45ms, the fifth clean; blocks and fragments stay inside the widget box; blocks paint over an intact base rather than cutting holes; the §16c.4 smear uses blocks only; the boot event fires after the log roll settles (240 + 225ms, under the §16c.1 cap) and the detail-entry event after the push completes.

### 39.9 Keyboard toolbar (user correction, 2026-09-02; overrides §39.4 `+ LINK` editor and §39.6 toolbar placement)
The user's words: "pedí un toolbar al lado del teclado, solo deberían aparecer íconos, por ejemplo 'añade url'; actualmente parece que se despliega un modal form entero y eso es desagradable."

- One `KeyboardToolbar` widget, shared by the capture bar and the item quick view. It is a 44px strip pinned directly above the IME (keyboard accessory position), full width, panel-strip surface (§38 header strip), hairline on top. It exists only while a text field has focus; it leaves with the keyboard.
- Icons only. No labels, no captions. Mono glyphs at 20px, 44px hit each, ink `--fg-dim`, accent on press. Order left to right: link, target (capture only: DROPS/project/goal picker), next, block, pair, move, done. Quick view omits target; capture omits pair/move/done/next/block.
- Link icon: clipboard holds a URL → attach it as a chip, no prompt. Clipboard holds no URL → the focused field switches to URL mode (placeholder `https://`, url keyboard, icon lit); submit attaches the chip and the field returns to title mode. Never a second field, never a sheet, never a dialog.
- Chips render in a single row directly above the toolbar, 28px, `[ host ] ×`. They belong to the field, not to the body.
- The quick view body is a readout: title as text (tap to edit in place, which raises the keyboard and the toolbar), meta lines, links as rows (tap opens, long-press deletes), blocked reason as a line. No `FieldPanel`, no `+ LINK` row, no inline editors in the body. The footer blocks from §39.4 stay for one-tap actions when the keyboard is down.
- Capture bar: §39.6's "toolbar row between the header strip and the field" is withdrawn. The strip sits above the keyboard per this section. The `→ DROPS` target block becomes the target icon; the chosen target shows as the first chip.

### 39.8.1 Icon decision (2026-09-02)
The launcher mark is the glitch raven head from the user's reference (`design/references/branding/user-glitch-raven-head.png`), traced faithfully (`design/explorations/branding/user-ref-trace/head-white.svg`, `head-lime.svg`), with the brow notch removed. No rifle, no frame, no text, no grain. Centring rule: the solid head's centroid sits on the canvas centre; the slice tail trails left from it and is shortened, never the head moved, if it would cross the safe zone. The standing bird (`user-glitch-raven-standing.png`) is the reserve mark and the source of the lime cursor dash idea.

### 39.10 Capture is text and links; everything else behind `+` (user correction, 2026-09-02; overrides the §39.9 toolbar order)
The user's words: "no debería de poder hacerse más que texto y urls, aparte que son on-demand, con un '+' se podrían poner más a disposición. Lo de 'with', 'blocked-by' solo es ruido que hace que se pierda el punto, que es poner cosas de forma ágil. También podría soportar añadir imágenes. Los íconos no son claros. Un ligero overlay negro en el resto del contenido para hacer focus en el form."

- Default `KeyboardToolbar` row, both surfaces: `link`, `image`, `+`. Nothing else is visible. Text goes in the field, links and images attach as chips. That is the whole capture path.
- `+` swaps the row in place (120ms cross-fade, no growth in height) for the extras: capture bar → `target`, `next`, `block`; quick view → `next`, `block`, `pair`, `move`, `done`. A `←` glyph at the left of the extras row returns to the default row. The row also snaps back to default after the keyboard closes. Pair and block never appear on the default row again.
- Images: the `image` glyph opens the system gallery picker (`image_picker`, gallery only, no camera). The picked file is copied into the app support dir under `attachments/<uuid>.<ext>` and stored as an `attachments` row (`id`, `item_id`, `kind` = `url` | `image`, `value` = url or relative path, `created_at`). Additive migration; existing link rows migrate into `attachments` with `kind = url`. An image chip is a 28px square thumbnail with `×`; in the quick view readout, images render as a row of 56px squares, tap opens a full-screen viewer (black, pinch to zoom, back to close), long-press deletes with the same confirm as a link.
- Icons: Material Icons outlined at 22px, one glyph per verb and no glyph reused for two verbs: link `Icons.link`, image `Icons.image_outlined`, more `Icons.add`, back `Icons.arrow_back`, target `Icons.folder_open`, next `Icons.bolt`, block `Icons.block`, pair `Icons.call_merge`, move `Icons.drive_file_move_outlined`, done `Icons.check`. Long-press on any glyph shows a one-word tooltip (LINK, IMAGE, MORE, TARGET, NEXT, BLOCK, PAIR, MOVE, DONE). Glyph ink `--fg-dim`, accent while active (URL mode, extras open).
- Scrim: while the capture field or a quick-view title edit has focus, a `#000` scrim at 60% covers everything outside the form (the field, its chips, the toolbar and the keyboard stay clear). It fades in with the keyboard (120ms), tapping it drops focus and closes the keyboard. The scrim is the only thing that changes in the background; no blur.

### 39.11 Drops have no state (user correction, 2026-09-02; narrows §39.4 footer, §39.9 and §39.10 extras for drops)
The user's words: "tampoco quiero que ponga estados de 'drops', por favor, no."

- A drop is an item with no project (`projectId == null`). Ruling reversed 2026-09-02, same day: a `goalId == null` definition turned every pre-goal task on the user's device into a drop, zeroed project progress and hid blocked and next items; the user's own data shows project tasks carry state without goals, so goals are optional grouping, not a requirement for state. It is text plus attachments. It has no done, no next, no blocked, no pair. Those columns stay in the schema (the row becomes a task the moment it is filed) but no surface reads or writes them while the item is a drop.
- Capture bar extras behind `+`: `target` only. `next` and `block` are gone from capture altogether; they exist only inside a project.
- Drop quick view: readout (title, attachments) and one footer block, `MOVE`. No DONE/NEXT/BLOCK/PAIR blocks, no state line, no `BLOCKED BY` panel. Toolbar extras behind `+` while editing a drop title: `move` only. Delete stays on long-press of the breadcrumb as before.
- Drop rows on Home carry no state glyph, no checkbox, no strike, no dim. A project's DROPS panel holds that project's tasks without a goal; they are tasks, so their rows show the same checkbox, checked-and-muted done state and blocked line as goal rows (no strike-through exists in the app), their quick view is the full §39.4 sheet, and they count in the project's and Home's progress numbers and can be NEXT ACTION. Filing a Home drop into a project or a goal turns it into a task, and only then do §39.4's state blocks and §39.10's extras appear.

### 39.12 Drop rows: long-press actions, no default target chip, capture closes itself (user faraday review, 2026-09-02; amends §39.10 and §39.6)
The user's words: "Cuando mantengo presionado sobre un drop debería poder moverlos o borrar drops. Eso de '[ DROPS ]' es innecesario, no sé por qué se ha agregado. Cuando agrego un item, automáticamente cerrar el form."

- Long-press on a drop row (Home DROPS and a project's DROPS panel) opens a two-block action strip anchored on the row, Panel style: `MOVE` and `DELETE`. `MOVE` opens the §39.5 target picker; `DELETE` confirms in place with the same second tap as the quick view. Tap elsewhere dismisses. The row tap still opens the quick view.
- No target chip while the target is the default. The capture bar targets DROPS unless the user picks something else through the `target` extra; only then does a chip appear, `[ ROMMY ]` or `[ ROMMY / SHIP MVP ]`, with `×` to return to DROPS. The chip row is absent when there are no chips, so the toolbar sits directly on the field.
- Submitting a capture closes the form: the field clears, focus drops, the keyboard and scrim go, the toolbar leaves with them, and the new row appears at the top of DROPS. No re-focus for rapid entry; the user taps the field again for the next one. The target resets to DROPS on every submit.

### 39.13 Multi-select on drops (user correction, 2026-09-02, amended after the versionCode 4 review; replaces §39.12's strip)
The user's words: "mantengo sobre uno y el modo de selección múltiple se habilita para todos y ya no es necesario un long press, solo tap, y podría cancelar esa acción. Como las apps que muestran listas y permiten dos acciones, una flecha y un tacho, para mover y para borrar, también un modal de confirmación."

- Long-press on a drop row enters selection mode with that row checked. No strip, no menu on the row, ever.
- While the mode is on, every drop row in that panel shows a 20px mono checkbox at its left (`[ ]` / `[x]`, accent when checked). A tap toggles the row; rows do not open the quick view. Long-press is not needed again.
- The panel header strip becomes the contextual action bar, the way Files or Gmail do it: `×` on the left (cancel), `N SELECTED` next to it, and on the right two icons only, `Icons.arrow_forward` (move) and `Icons.delete_outline` (delete), 22px, 44px hits, ink `--fg-dim`, accent on press. No text blocks, no bottom bar; the capture bar stays where it is and is inert while the mode is on.
- Move opens the §39.5 target picker once and files every checked item. Delete opens a confirmation modal, Panel style: `DELETE N DROPS?` with `CANCEL` and `DELETE` blocks, the destructive one filled accent. Nothing is deleted before that second block.
- `×`, the back gesture, or finishing either action leaves the mode. Selection never survives a navigation away from the panel.
- Home DROPS and a project's DROPS panel both get this. Filed rows under a goal keep the quick view.

### 39.14 Projects without an objective, archive and unarchive (user faraday review, 2026-09-02)
The user's words: "al del drone FPV no le puse 'objective' y se pinta así, debería de poder soportarlo para solo mostrar el nombre por ahora. Además, debería de también poder archivar y desarchivar proyectos."

- Objective is optional everywhere. When it is empty, the project row (Home PROJECTS, Projects tab, pickers) shows the name on the title line and drops the small label line; no blank line, no dash, no placeholder. Project detail omits the OBJECTIVE panel entirely when it is empty; the hero, STATUS and progress stay. The form keeps the field, blank.
- Archive is a one-tap action, not a trip through the status field. Project detail breadcrumb row carries `ARCHIVE` next to `EDIT` (`UNARCHIVE` when the project is archived). Archiving asks once, Panel-style modal `ARCHIVE PROJECT?` with `CANCEL` / `ARCHIVE`; unarchive does not ask. Both keep every item filed where it is.
- Archived projects leave Home PROJECTS, NEXT ACTION and the §39.5 move picker. The Projects tab gets an `ARCHIVED N` panel at the bottom, collapsed by default, tap the header to expand; rows render dim and open the detail, where `UNARCHIVE` lives. Unarchive returns the project to active.
- The status field in the form still offers archived, and both paths write the same column.

### 39.15 Capture field URL highlight, SELECT entry into multi-select (orchestrator, 2026-09-02, from Todoist/TickTick composer reference)
- While typing in the capture field, any token that `extractUrls` already recognises is painted in the field itself, mono, `--fg-dim` ink on a `--panel-strip` background spanning exactly the token, no underline, no icon. It tells the user before submit that the token will file as a link. The token stays editable text; the highlight is a `TextEditingController.buildTextSpan` override, not a chip, and it never changes what `_submit()` does (§39.6 title and link rules unchanged).
- A DROPS panel header (Home and project) gains a `SELECT` text action on the right, next to the count, tracked uppercase like `NEW +`. Tap enters §39.13 selection mode with nothing checked; the contextual bar appears with `0 SELECTED`, arrow and trash disabled in the existing `textDisabled` ink until the first check (builder ruling: `--fg-dim` is brighter than the idle disabled ink, so it would invert the state). Long-press keeps working as before. `SELECT` is hidden while the panel is empty and while selection mode is active.

### 39.16 Settings and build string (orchestrator, 2026-09-02, closes §16b's "debug toggle in settings later" and §16c.8)
- No third tab (§37 navigation stands). The door is a `SYS` breadcrumb action on Home, same slot and style as a project's `EDIT`. It pushes a `SETTINGS` route without the nav bar, crumb `HOTLINE / SYS`.
- Contents, top to bottom, bracket labels per §16c.7: `[ STATIC ]` with `ON` / `OFF` as a two-row §16c.3 picker (block on the active one), persisted in a `settings` key-value table (new schema version, additive, migration proof required); OFF draws the tile once, unmoving, same as the throttle path. `[ BUILD ]` at the bottom, mono 11 `--fg-dim`: `v<version> (<versionCode>) <short sha>`, the sha injected with `--dart-define=HOTLINE_BUILD=<git rev-parse --short HEAD>` from phone.toml and the flake, `dev` when absent.
- No export. The user never asked for one; an orchestrator draft of 2026-09-02 added it as insurance and was struck the same day.

### 39.17 Unfolded display (orchestrator, 2026-09-02)
- faraday's inner display is near square. Above 600dp of width every screen keeps a single column capped at 600dp, centred; the scaffold static and the dither field fill the full width behind it, and the nav bar spans the full width with its tab labels inside the same cap. Panels, sheets and the capture bar obey the cap. Nothing else changes: no two-pane layout until asked.
- Fold and unfold mid-session must not lose state: the mounted tab, an open sheet, the capture field's text and the selection set survive the resize. Proof: `cmd device_state state 2` then `reset` on the emulator profile that supports it, otherwise a window resize on the desktop build.

### 39.18 Project hierarchy (user, 2026-09-02)
The user's words: a project can optionally belong to another project; projects form a tree of arbitrary depth; there is no subproject entity, a subproject is a project with a parent; every project holds its own goals, tasks, drops and notes wherever it sits; a parent is the aggregate scope of its descendants and its progress reflects the subtree; navigation into a child preserves the hierarchy through breadcrumbs; the hierarchy is navigational, not explorer-like, never the whole tree at once; a project screen exposes its immediate children; moving a project moves its subtree; archiving a parent hides its subtree.

Rulings that make it buildable:
- Data: `projects.parent_id`, nullable, references `projects.id`. Schema 5 -> 6, additive, migration proof from `build/baseline`. The repository refuses a parent that is the project itself or any of its descendants (cycle guard), and the form never offers those rows.
- Roots: a project with `parent_id == null`. Home PROJECTS (max 3, `+n more`), the Projects tab and the `ARCHIVED` panel list roots only. Children are reached through their parent's detail, never from a flat list. The §39.5 MOVE picker stays flat (every active project, then its goals) but a child's row carries its parent path as the subtitle, `INFRA / HOMELAB`.
- Progress: done over all tasks of the project and every descendant, one number. Zero tasks in the subtree = 0%. The `1 OF 3 TASKS` line under a parent's title counts the subtree too. NEXT ACTION's suggestion (§37) and its priority ordering keep using the task's own project.
- Detail: after the `[ OBJECTIVE ]` line and before GOALS, a `PROJECTS N` panel with the immediate children as §38.4 project rows (name, objective, subtree progress), each opening the child's detail as a pushed route on top of the parent's; `NEW +` on that panel opens the project form with the parent preset. The panel is absent when there are no children and the project is a root; a childless child shows it empty with `NEW +` so the depth stays discoverable.
- Breadcrumb: `/ PROJECTS / INFRA / HOMELAB` for a child two deep. Never wraps (§38.5 ruling); when the path does not fit beside the trailing verbs, leading ancestors collapse to a single `…` and the immediate parent always stays. Every ancestor segment is tappable and pops the stack back to that ancestor; the root `PROJECTS` segment pops to the tab.
- Form: a `[ PARENT ]` field under status, a §16c.3 picker with `NONE` first and every active project except the project itself and its descendants, rows carrying the parent path as subtitle. Changing the parent is the move; children keep their `parent_id`, so the subtree follows without a write.
- Archive: a project is hidden when it or any ancestor is archived. Descendants keep their own status column, so unarchiving the parent restores them as they were. The `ARCHIVED` panel lists only projects whose own status is archived and whose parent is not hidden; opening one shows its children dim, and their `UNARCHIVE` is absent while an ancestor is archived. Tasks under a hidden project leave Home like an archived project's tasks do now.
- Delete cascades to the subtree in one transaction; the confirm modal reads `DELETE PROJECT AND N BELOW?` when N > 0.

### 39.19 Capture inside a project (user, 2026-09-02: "poder tener el component para crear drops dentro de ya un mismo proyecto")
- A project's detail carries the §39.6 capture bar pinned at its bottom, the same component and the same extras (link, image, more) as Home, with the target fixed to that project: submit files a project drop (`projectId` = the project, `goalId` null) and the row appears at the top of that project's DROPS panel. Text, links and images follow §39.6 and §39.10 unchanged.
- No target chip and no `target` extra: the project is the target and cannot be changed from here; filing under a goal stays a MOVE from the row. The bar clears and closes on submit per §39.12.
- The capture landing fires on the project's DROPS panel header glyph (§16b), since there is no nav bar under a pushed route.
- Hidden while the project is archived. On the unfolded display it obeys the §39.17 column.

### 39.20 AGENTS panel on Home (user, 2026-09-02, from a Herdr research mock)
The user's words: the agents panel goes at the top of Home because it is the most important thing; the Home title goes; the dotted square in the mock stays but has no known use.

- Home order becomes AGENTS, NEXT ACTION, PROJECTS, BLOCKED, DROPS, RECENT. The `TODAY_` title and its cursor are removed; the breadcrumb line `/ PERSONAL CONTROL PLANE` stays as the only header, with `SYS` on its right as today. The dotted square is not built: nothing was asked of it.
- Source is Herdr's socket API on nyx (`herdr agent list`, JSON). The phone reaches it over ssh on the tailnet: the app generates an ed25519 key on first use, and the user registers a host under §39.21's `[ HOSTS ]`, switches its `HERDR` integration on, and installs the public key on that host as a forced command, `command="herdr agent list",restrict`, so the key can do nothing else. No host is ever assumed (user ruling 2026-09-02: never connect to nyx or anywhere on its own): until some host has `HERDR` on the panel is blocked, one dim line `NO HOST · SET IN SYS` and no rows, no footer, and the app opens no connection. Every host with `HERDR` on is polled, concurrently; rows merge across hosts, and a host that fails contributes its own dim line while the others still render rows. Fetch on Home appearing and every 10 s while Home is visible and the app is foreground; never in the background. Dependency: `dartssh2`.
- Panel: header `AGENTS`, count of agents, `VIEW ALL >`. Column labels `AGENT`, `STATUS`, `WORK` in the §38.4 label style. One row per working or blocked agent, most recently changed first (`state_change_seq` desc), max 3: a 24px bordered mono glyph box (`C` claude, `X` codex), the agent name, a 6px status dot with the status word (accent for working, warning for blocked, `--fg-dim` for idle), and `terminal_title_stripped` as WORK, single line, ellipsised. Footer line `N idle · N blocked`, blocked count in warning color when non-zero. When no agent is working or blocked, the rows collapse to the footer alone.
- Unreachable host, no key installed or a protocol mismatch (`herdr status server` reports protocol 21 today): the panel shows one dim line with the reason, `nyx unreachable`, `key rejected`, `protocol N`, and keeps the last good snapshot's timestamp on the right, `12s ago`. It never blocks the rest of Home.
- `VIEW ALL` pushes an `AGENTS` route without the nav bar listing every agent, idle included, grouped by host and then by workspace id (the host level collapses when only one host has `HERDR` on), each row adding the pane id and the directory basename as the subtitle. Read only in this section: no prompt, no keys, no focus from the phone.

### 39.21 Keys (user, 2026-09-02: "un apartado donde administrar las keys, crearlas y que se almacenen ahí mismo y luego yo personalmente puedo ir a mis hosts")
- Settings gains a `[ KEYS ]` block: one row per key, name over the fingerprint (`SHA256:…` truncated) in mono, `NEW +` on the block header. Tap a row for the key's detail: `[ NAME ]`, `[ TYPE ]` ed25519, `[ PUBLIC ]` as the full `ssh-ed25519 AAAA… name` line in a selectable mono field with a `COPY` action beside it, `[ USED BY ]` listing the hosts that reference it, and `DELETE` at the bottom with the §39.14-style confirm; a key in use by a host cannot be deleted until the host is repointed.
- New key: a form with `[ NAME ]` only, ed25519 always, comment = name. Generated on the device; the private key never leaves it and is never shown. Stored in a `keys` table (id, name, public_key, created_at) with the private key in `flutter_secure_storage` under the key id, so the row survives the data export-free world and the secret lives behind the Android keystore.
- Hosts: a `hosts` table (id, name, address, user, key_id) edited under a `[ HOSTS ]` block in the same style. A host is a machine, not a herdr endpoint (user, 2026-09-02: "a host can have (or not) some active integrations"): the host form carries an `[ INTEGRATIONS ]` block, one §16c.3 ON/OFF row per integration the app knows, `HERDR` being the only one today, persisted in `host_integrations` (host_id, kind). There is no global `[ HERDR ]` picker; §39.20's panel reads the set of hosts with `HERDR` on. The transport behind an integration is its own concern: today `HERDR` runs `herdr agent list` over ssh with the host's key, and a later backend that proxies herdr swaps the transport, not the host or the integration row, so nothing in the schema names ssh. Installing the public key on a host is the user's job by hand, as asked.
- SSH only. VNC does not authenticate with ssh keys: classic VNC auth is a password challenge and the TLS variants use X.509, so a key made here is useless to a VNC server directly. VNC benefits only when tunnelled through ssh, where the tunnel uses the host's key from this table. No VNC client is built.

### 39.22 The PROJECTS tab goes; the nav bar goes with it (user, 2026-09-02: "remove the 'projects' section in the home, just the tab")
- The bottom nav bar had two destinations, HOME and PROJECTS (§37). PROJECTS is removed. A bar with one destination is chrome that answers nothing, so the bar is removed too: Home fills the screen down to the capture bar.
- Home's PROJECTS panel stays exactly as §39.18 draws it. Its `VIEW ALL` (strip tap and the text action) pushes the projects list as a route with a back arrow, `PROJECTS` in the breadcrumb, the same `ALL PROJECTS` panel and the §39.14 `ARCHIVED N` panel under it. Nothing on that screen changes but the way in.
- Project detail's "go to the projects tab" moves (after delete, after the archive of an ancestor) become a pop to the route under it. There is no tab to land on.
- The §16b nav-icon glitch loses its icon. The autonomous tick fires the Home DROPS strip glitch instead, the `landing` controller that already exists; a capture's own arrival glitch on that strip stays and its extra fire on the nav icon goes. `navIndexProvider`, `NavGlitch`, `navDestinations` and the nav shell leave with the bar; §39.20's "polls only while Home is in front" reduces to "while Home is mounted and the app is foreground", since Home is now the root route and a pushed route covers it the way a tab never did.
- Deleted text: §37 "Two tabs: HOME, PROJECTS" and §38.8's nav accent rule no longer apply.

### 39.23 Text actions get real hit areas (user, 2026-09-02: "mejora la accesibilidad de los botones con acciones de tipo solo texto, a veces son difíciles de tocar, inspírate del mcp de appllama")
Appllama reference (2026-09-02, element families `text-links`, `others/Cancel Text Action`, `buttons-ctas`): the top-grossing apps put a text-only action in a full-height row slot, 44pt tall, with horizontal padding wider than the label, a pressed state, and a distinct disabled ink (Splice "Disabled Next Label", Healthi "Cancel Text Action" + "Save Text Action" on one 44pt row). The label is small; the hit is not.

- `PanelAffordance` and every text-only action built from it (`VIEW ALL`, `NEW +`, `SELECT`, `SYS`, `EDIT`, `ARCHIVE`, `UNARCHIVE`, `COPY`, `ADD`, counts with `onTap`) gets a hit box of the full height of the strip or row it sits on, and a width of the label plus `Spacing.md` on each side, never under `TapTargets.minHeight` wide. The label does not move: the padding eats into the gap between neighbouring actions, so the visual gap stays `Spacing.lg` while the hit boxes abut.
- The panel header strip grows from 27px to the row height, 36px (`Spacing` row `minHeight`, the token rows already use), so a strip action's hit is 36×≥44. Title, count and affordance stay vertically centred; body padding is unchanged. The breadcrumb row does the same: `SYS`, `EDIT`, `ARCHIVE` get the full row height, and the row is at least 36px.
- Pressed state: accent ink for the duration of the press, the way the §39.13 verbs already do. An action without `onTap` is a readout and is not painted as pressable.
- Nothing else about the type changes: `HotlineText.panelHeader`, tracking, uppercase, the 12px forward glyph.

### 39.24 The selection bar follows the user (user, 2026-09-02: "cuando mantengo presionado para seleccionar múltiples el tool de borrar, mover, cancelar, etc debería de seguirme")
Amends §39.13's "No text blocks, no bottom bar; the capture bar stays where it is and is inert while the mode is on". The strip scrolls away with the panel and the verbs with it. Appllama reference (2026-09-02, `selected-states/Square Checkboxes`): checkbox lists across the library keep their actions in a sticky bottom bar (Zest "Sticky Bottom Actions", ReciMe "Sticky Next Button", Innertune "Sticky Bottom CTA"), never on a scrolling header.

- While §39.13 selection mode is on, the capture bar's slot holds the selection bar instead: `×` (cancel) on the left, `N SELECTED` next to it, `Icons.arrow_forward` (move) and `Icons.delete_outline` (delete) on the right, the same glyphs, sizes, inks and disabled rule as §39.13/§39.15. Same height as the capture bar so nothing under it jumps. The capture bar is not drawn while the mode is on; it comes back when the mode ends.
- The panel header strip returns to its normal state in the mode: title and count, `SELECT` hidden. It no longer carries the verbs or the count of checked rows; the bar does.
- Home DROPS and a project's DROPS panel both get this: the bar takes the slot of whichever capture bar that screen pins.
- Everything else in §39.13 stands: checkboxes, tap toggles, the move picker, the delete confirmation, `×`/back/finishing leaves the mode, no selection survives a navigation.

### 39.25 Fresh drops (user, 2026-09-02: "cuando acabo de escribir un drop estos pueden estar en un 'state' temporal de 'fresh', o sea que las que acabo de escribir sin abandonar la pantalla deberían de tener un resaltado mínimo que me permita que cuando mantengo presionado sobre uno de esos todos ellos [queden] automáticamente seleccionados, si lo hago sobre otro que no pertenezca entonces el special state se va, o se va también cuando abandone la pantalla así sin más")
- A drop captured from a screen's capture bar is *fresh* on that screen until the user leaves it. Fresh is UI state, not a column: it lives in memory per scope (Home, a project), never in the database, never survives a restart.
- Highlight, minimal: the row's age value (`now`, `1m`) is painted accent instead of `--fg-dim`. Nothing else on the row changes: no glyph, no background, no border.
- Long-press on a fresh row enters §39.13 selection mode with every fresh row of that panel checked, in one gesture. Long-press on a row that is not fresh clears the fresh set and enters the mode with only that row, as today.
- The fresh set clears when the user leaves the screen: a pushed route (project, quick view, settings, projects list), the back gesture, or the app leaving the foreground. It also clears when a batch removes every fresh row (move, delete). Cancelling the mode with `×` does not clear it: nothing happened.
- `SELECT` (§39.15) ignores freshness: it enters with nothing checked. A tap on a fresh row outside the mode opens the quick view as always.
- Home DROPS and a project's DROPS both get this; the capture bar of each screen feeds its own set.

### 39.26 Correction to §39.22: the PROJECTS panel leaves Home, the tab stays (user, 2026-09-03: "por qué diablos la sección de projects no se ha quitado?")
- §39.22 read the user's words backwards. The request was: remove the PROJECTS panel from Home, keep only the tab. §39.22 is void where it conflicts with this section; §39.23, §39.24 and §39.25 stand.
- The bottom nav bar returns as §37 and §38.8 had it: HOME and PROJECTS, nav accent rule, the §16b nav-icon glitch on the autonomous tick and on a capture's arrival. §39.20's polling gate is again "while Home is in front and the app is foreground".
- Home's panel order is AGENTS, NEXT ACTION, DROPS. No PROJECTS panel, no `VIEW ALL`, no `NEW +` on Home. A project is reached through the tab; a new project is created from the PROJECTS tab's `NEW +` as §39.18 already draws it.
- The PROJECTS tab is the §39.18 list with the §39.14 `ARCHIVED N` panel under it, as before §39.22: no breadcrumb back arrow, no pushed route. Project detail's "go to the projects tab" moves (after delete, after the archive of an ancestor) are tab switches again.
- A tab switch is leaving the screen: it clears the §39.24 selection and the §39.25 fresh state of the tab left, the same as a route push. Coming back to the tab starts clean.
- Version bumps to 1.0.0+18.

### 39.27 Fresh drops are pruned by removal, never by absence (user, 2026-09-03: "la parte de los 'fresh' es inestable, no todos los que creé en una secuencia de golpe han sido resaltados")
- Defect in v17: the capture bar adds the id to the fresh set when the write returns, the panel rebuilds on that change before the drops stream has delivered the row, reads the id as "not in the list" and prunes it a frame later. Whether the stream wins that race decides whether the row lights up, so a fast sequence lights some rows and not others.
- Rule: a fresh id leaves the set only when the panel has shown it and the list then stops containing it. An id the list has not shown yet is never pruned; the panel keeps the set of ids it has rendered and prunes the fresh set (and the selection, the same way) against the ids that were rendered and are now gone.
- Regression test: add an id to the fresh set before the drops stream emits the row, pump a frame, the id is still fresh; the row then arrives and is drawn fresh; a batch that removes it clears it.

### 39.28 The host form never hides its way out (user, 2026-09-03: "estoy agregando el host pero salí y no se guardó una mierda")
- Defect in v18: the host form needs name, address, user and a key. Until all four are set the `CREATE HOST` bar is not drawn at all, an empty box stands in its place. The `[ KEY ]` picker does not preselect anything, and a picker with one entry reads as already chosen, so the user fills the three fields, switches `HERDR` on, sees no action, backs out, and the back gesture drops the draft without a word. The "bar hidden until valid" convention is fine on the key and project forms, where the only requirement is the one field on the screen; on a form whose requirement is a tap on a picker row it hides the requirement.
- `[ KEY ]` preselects the only key when exactly one exists and the form is a new host. With two or more, nothing is preselected. Editing a host keeps the host's own key. No keys at all: the picker body is one dim line, `NO KEYS · NEW + IN SYS`, and the bar reads `KEY MISSING` (below).
- The action bar is always drawn on the host form. Invalid: the bar is dimmed (fill `--fg-dim`, label `--bg`), the label names the first missing part in field order, `NAME MISSING`, `ADDRESS MISSING`, `USER MISSING`, `KEY MISSING`, and a tap does nothing. Valid: `CREATE HOST` / `SAVE` as today. The label updates on every keystroke and picker tap.
- Leaving a dirty host form with the back arrow or the back gesture asks `DISCARD HOST?` with the §39.14 confirm, `DISCARD` as the confirm label. Dirty means: new host with any field typed, any key picked by the user (a key the form preselected is not a pick), or any integration on; existing host with any value changed from what was loaded. A clean form leaves without asking. After a save or a delete the form pops without asking. Host form only: the key and project forms keep their silent back.
- Regression tests: one key, open the new-host form, the key row is the accent block and the bar reads `NAME MISSING`; fill name, address, user, the bar reads `CREATE HOST`; tap it, the host row is on Settings with `HERDR` in its state. Two keys, nothing preselected, all three fields filled, the bar reads `KEY MISSING` and a tap saves nothing. Dirty form, back, `DISCARD HOST?` sheet, cancel keeps the form and its values, confirm pops with no row saved.
- Version bumps to 1.0.0+19.

### 39.29 A host has a port; the reason line says when the name did not resolve (user, 2026-09-03: "probé la ip y no funciona, en nyx el puerto ssh es el 357")
- Defect in v19: the transport connects to port 22 always and the `hosts` table has no port. nyx's sshd listens on 357 and its 22 is a tarpit, so nyx reads `nyx unreachable` whatever the address says, and so will every host not on 22.
- `hosts` gains `port`, integer, default 22, schema 7 → 8 with the column added under that default so existing rows keep working. `Host` carries it; the §39.21 transport connects to it. The row in `[ HOSTS ]` reads `user@address` when the port is 22 and `user@address:port` otherwise.
- Host form: a `[ PORT ]` field between `[ ADDRESS ]` and `[ USER ]`, numeric keyboard, `22` prefilled on a new host, the host's own value on edit. §39.28's bar order becomes NAME, ADDRESS, PORT, USER, KEY; an empty field or a value outside 1–65535 reads `PORT MISSING`. The port counts for §39.28's dirtiness like any field.
- Reason lines: `nyx unresolved` when the address does not resolve (the lookup failed before any socket opened); `nyx unreachable` stays for everything after a name, as §39.20 lists it. The underlying error is written to the debug log with the host name on every failure, so a handset report can be read without guessing.
- Regression tests: migration from 7 lands `port` = 22 on an existing host row; the form saves the typed port and the fetch is called with it; `abc` and `70000` read `PORT MISSING`, `357` reads `CREATE HOST`; the hosts row subtitle shows `:357` and hides `:22`; a fetch that throws the unresolved failure renders `nyx unresolved`.
- Version bumps to 1.0.0+20.

### 39.30 Agent rows carry the agent's own mark (user, 2026-09-03: "podríamos mejorarlo y usar los íconos oficiales supongo, podemos poner el nombre así sin más con '?' cuando no hay")
- Scoped exception to §3 and §10: a third-party mark is allowed only inside the §39.20 glyph box, to identify the product behind a pane. Nowhere else in the app, never in the launcher icon, never in the vendor's colour.
- The box keeps its 24px border. Inside it, the agent's official mark reduced to one colour (text primary, through the same tint path as the `hl-*` glyphs), fitted to a 16px square centred in the box. Files `assets/icons/agent-<kind>.svg`, `<kind>` being the `agent` string herdr reports (`claude`, `codex`, …), 24-unit viewBox, paths only, no fill colours baked in.
- Required marks: `claude`, `codex`. The artist adds other kinds herdr detects (`gemini`, `copilot`, `cursor`, `opencode`, `amp`, `cline`, `kimi`, `qwen`, `grok`, `devin`, `droid`, `hermes`, `kiro`, `kilo`, `maki`, `pi`, `qodercli`, `agy`) only where an official monochrome mark exists, eight files at most in this section; the rest fall back. Each mark is traced onto the 24 grid from the vendor's brand page or the Simple Icons path (CC0), never pasted with the vendor's own viewBox; the source of every file is listed in `design/production/agent-marks.md`.
- Fallback: a kind with no mark file keeps the bordered box with `?` in mono, as today. The letter glyphs `C` and `X` go.
- Name: the agent name stays plain text as herdr reports it, uppercased as today; `?` when the snapshot's `agent` is empty. Same rule on the §39.20 `VIEW ALL` route rows.
- Regression tests: a claude row renders `agent-claude.svg` and no `C`; an unknown kind renders `?`; an empty kind renders `?` in the box and `?` as the name.
- Version bumps with the build that ships it.

### 39.31 A blocked agent raises a status-bar alert with a one-tap answer (user, 2026-09-03: "quiero que me ayudes a que me llegue una notificación de alerta en el status bar cuando algo bloquea a mis agents, ¿okay? y que me de una forma fácil de decir si sí, no, etc")
- Amends §39.20's "never in the background": with `ALERTS` on, the app keeps watching its `HERDR` hosts while it is not in front. With it off, §39.20 stands unchanged and the app opens no connection in the background.
- Settings gains an `[ ALERTS ]` block under `[ HOSTS ]`: one row, `BLOCKED AGENTS`, with the app's toggle. Turning it on asks the OS for notification permission; refused, the toggle stays off and the row's subtitle reads `NOTIFICATIONS DENIED`. With no host on `HERDR` the row is dim, subtitle `NO HOST`, and the toggle does nothing. The setting persists across launches.
- Transport: the forced command on the host becomes `hotline-gate`, a script the host ships (nyx: NixOS config in the user's dotfiles, not this repo), dispatching on `SSH_ORIGINAL_COMMAND`. The app sends exactly these strings:
  - `agent list`: one `herdr agent list` JSON document, exit 0. The gate also accepts §39.20's old `herdr agent list`, so v20 keeps working against it; the app switches to the short form.
  - `agent watch`: the same JSON as one line at once, then one line each time the projection (`pane_id`, `agent`, `agent_status`, `state_change_seq`, `terminal_title_stripped`, `workspace_id`, `cwd`) changes, sampled every 2 s on the host; never exits on its own.
  - `agent read <pane>`: the last 8 lines of the pane's visible screen, plain text.
  - `agent keys <pane> <key>…`: forwarded to `herdr agent send-keys`. Pane must match `[A-Za-z0-9]+:[A-Za-z0-9]+`; keys limited to `enter`, `esc`, `up`, `down`, `tab` and single ASCII letters or digits.
  - Anything else: `denied` on stderr, exit 2. herdr's own non-zero exits pass through, so §39.29's `protocol ?` reading still applies.
- Watcher: an Android foreground service, started when `ALERTS` is on and some host has `HERDR` on, stopped the moment either stops being true; it outlives the activity being swiped away. Its persistent notification is silent and minimum importance: `HOTLINE` over `WATCHING N HOSTS`, or the host's §39.20 reason line uppercased (`NYX UNREACHABLE · RETRY 30S`) when a host is down. One ssh connection per host running `agent watch`, keepalive every 15 s, reconnect with backoff from 5 s doubling to 60 s. While the watcher runs, Home reads its snapshots and §39.20's own 10 s poll pauses, so the host sees one connection per phone. §39.29's debug line covers watcher failures too. Not restarted on boot in this section.
- Alert: when a snapshot shows a pane at `blocked` that the previous snapshot from that host did not (the first snapshot after the watcher service starts counts every blocked pane as new; a reconnect within one service life keeps the set, so a pane still blocked after a dropped link is not alerted again and an answered alert keeps its state line), one notification per pane, id derived from host and pane so a repeat updates in place, channel `Blocked agents` at high importance with the channel's default sound and vibration. Title `<AGENT> BLOCKED` with the agent name uppercased (`?` when empty); text `terminal_title_stripped`; the expanded form adds the `agent read` tail fetched on the same connection (on failure the text stays alone). The app dismisses it when the pane leaves `blocked` or disappears. One notification per blocked episode, never more.
- Actions: `YES`, `NO`, `OPEN`. `YES` and `NO` send keys through `agent keys` by agent kind: claude `enter` / `esc`; codex `y` / `n`; every other kind `enter` / `esc`. The builder verifies claude and codex against a live blocked pane before the gate and corrects both the code table and this line if they are wrong. After a tap the actions are replaced by `SENT · YES` (or `NO`) until the watcher sees the pane leave `blocked`, which clears the notification, or 10 s pass with no change, which brings the actions back. A gate error shows `FAILED · <reason>` with the actions back. `OPEN` launches the app on the §39.20 `AGENTS` route. Actions work with only the service alive, the activity gone.
- Alerts post whether or not the app is in front: the status bar is the ask.
- Not built here, waiting for the user's word: a typed reply from the notification (`REPLY`, free text), and restarting the watcher after a reboot.
- Regression tests: the blocked edge fires once per episode and on the first snapshot; ids are stable per host and pane; leaving `blocked` clears; the key table per kind; no watcher without the toggle or without a `HERDR` host; the list fetch sends `agent list`; a watch stream of one JSON per line parses into snapshots; the notification title and text builder, empty agent included.
- Version bumps with the build that ships it.

### 39.32 The host's screen inside the app, over the ssh tunnel (user, 2026-09-03: "quiero poder visualizar todo desde vnc client… claro, con ssh tunneling… I was already connecting to this host using AVNC, but AVNC has some limitations in my flow while I'm outside my house… that's why I'm talking to you right now about embed a VNC client in the app")
- Overrides §39.21's last line: a VNC client is built, pure Dart, no plugin. It never opens a VNC port itself: the RFB stream rides a `direct-tcpip` channel inside the host's ssh connection (§39.21 key, §39.29 port), target `127.0.0.1:5900` on the host. No new key, no new gate verb, nothing new listening on the host: wayvnc stays as it is. The one host-side fact is that `restrict` on the key line refuses channel opens, so the line gains `port-forwarding,permitopen="127.0.0.1:5900"` next to it (nyx: dotfiles `user.nix`, same rebuild as §39.31's gate).
- Integration: the host form's `[ INTEGRATIONS ]` gains a `VNC` row under `HERDR`, same ON/OFF row, kind `vnc` in `host_integrations`. The display is fixed to the host's `127.0.0.1:5900` in this section; a port field waits for the user's word.
- Way in: Home's AGENTS panel header gains `SCREEN >` beside `VIEW ALL >` when some host has `VNC` on, absent otherwise. One such host pushes straight; several open a picker sheet of host names. The `SCREEN` route has no nav bar and no capture bar; it is the only route that allows landscape, and §39.17's fit rule applies unfolded.
- Screen: breadcrumb `/ <HOST> SCREEN`, on its right the state, `CONNECTING`, `LIVE`, or a §39.20 reason line: `nyx unreachable`, `nyx unresolved`, `key rejected`, `tunnel refused` (the channel open was denied), `auth unsupported` (the server offers no `None` security), `stream closed`. A reason line comes with a `RETRY` text action; there is no reconnect loop. Below, black ground and the framebuffer scaled to fit the width. Gestures: tap moves the pointer there and left-clicks; long press right-clicks; long press then drag holds button 1 while moving; pinch zooms about the pinch centre; two-finger drag pans the zoomed view, and at fit, where nothing pans, sends wheel events, one button 4/5 press-release per 40 px. `KEYS` in the breadcrumb opens the soft keyboard: each typed character goes as an X keysym press and release (Latin-1 codepoints direct, others `0x01000000 + codepoint`), and a strip above the keyboard carries `CTRL`, `ALT`, `SUPER`, `ESC`, `TAB`, `←`, `↑`, `↓`, `→`, `ENTER`, `DONE`, the three modifiers first because they arm the key that follows and stay sticky for exactly one. Leaving the route closes the channel and the ssh connection.
- Protocol: RFB 3.8, accepting 3.3 and 3.7 servers by their own rules; security `None` only. `ClientInit` shared. `SetPixelFormat` 32 bpp, depth 24, little-endian, true colour, red shift 16 / green 8 / blue 0, which is Flutter's `bgra8888`, so rects land in the framebuffer without a swizzle. `SetEncodings` in preference order ZRLE (16), CopyRect (1), Raw (0), DesktopSize (-223). One non-incremental `FramebufferUpdateRequest` first, incremental after, the next sent as soon as the previous update is painted, at most 24 per second (wayvnc's cap on nyx). ZRLE: one zlib stream for the whole session (`ZLibDecoder().startChunkedConversion`), 64 px tiles, all subencodings (raw, solid, packed palette 2/4/16 colours, plain RLE, palette RLE), CPIXEL at 3 bytes as the spec reads it for this format. Bell, cut text and colour-map messages are read and dropped. Pub's `dart_rfb` is not used: Raw and CopyRect only, and it owns its socket.
- Rendering: one `Uint8List` framebuffer sized by `ServerInit` or `DesktopSize`, rects blitted in, and one image per update, never one per rect. The builder measures paint time per 1080p update on the emulator and writes it in the evidence README. Failures are written to the debug log as `hotline.vnc <host>: …`, §39.29's rule.
- Regression tests: the handshake against a scripted byte stream (version, security types, `ServerInit`) yields width, height and name and emits the exact client bytes; a security list without `None` maps to `auth unsupported`; a refused channel maps to `tunnel refused`; ZRLE vectors for every subencoding and a CopyRect land the expected pixels in the framebuffer; the pointer mapping from touch to framebuffer coordinates under fit and under zoom; key events for a letter, `ENTER`, `ESC` and a sticky `CTRL`; `SCREEN >` absent without a `vnc` host and present with one; disposing the route closes channel and client; `vnc` persists in `host_integrations` like `herdr`.
- Not built, waiting for the user's word: VNC password auth, a display port field, clipboard, cursor pseudo-encoding, more than one output.
- Version bumps with the build that ships it.

### 39.33 The pirate mascot: pixel sprites, splash animation, in-app states (user, 2026-09-03: "Recuerdas al búho? ya no será eso ahora será ese pirata, ojo, deben de ser sprites o animaciones… eso que te digo junto con las imágenes son el resultado a lograr")
- Overrides §39.8.1: the launcher mark is the pirate skeleton of `design/references/concept/hotline-mascot-v0.png`, the raven goes. §3 and §10's stroke rules do not apply to the mascot: it is pixel art and nothing else, no anti-aliasing anywhere in its path.
- Grid: one 48×48 cell per frame, the figure about 26 wide by 38 tall with its feet on row 44, three values only: transparent, text primary `#E8E8E3`, accent `#B7FF2A` (the app's tokens, not the reference's hexes). Source of truth is text grids in `design/sprites/mascot/<state>/<nn>.txt`, 48 lines of 48 characters, `.` transparent, `#` primary, `a` accent. `design/tools/sprites.py` (python3 + Pillow through nix) assembles `assets/sprites/mascot-<state>.png`, frames left to right at 1×, and writes `assets/sprites/mascot.json` as `{"cell": 48, "states": {"<state>": {"frames": N, "fps": F, "loop": bool}}}`. Nobody hand-edits the PNGs.
- States, from the reference's second row: `idle` 2 frames 2 fps (breath); `looking` 2 frames 2 fps (hand at the brow); `working` 4 frames 8 fps (walking, speed lines in primary); `success` 4 frames 6 fps (sword up, sparks in accent), once; `blocked` 2 frames 2 fps (`!` in accent, blinking); `alert` 2 frames 4 fps (sword up and `!`); `sleep` 3 frames 2 fps (`z Z` in accent rising). `splash`, from the first row: 7 frames, init, draw (sparks), raise, turn, back, front, ready, once at 6 fps; the last frame holds and `HOTLINE_` in the §38 word style appears under it.
- Rendering: PNG sheets drawn with `FilterQuality.none` at integer scales only, ×3 (144 px) in panels and ×4 (192 px) on empty states and the splash, never fractional, never bilinear. One `Sprite` widget in `lib/design/sprite.dart`: state name in, manifest read once, frames advanced on a `Ticker`, loops or holds the last frame, stops ticking when not visible.
- Placements (user ruling, 2026-09-03: "the mascot is primarily Hotline's identity, not an agent-status indicator"): the launcher icon, a static idle frame; the splash on cold start, the seven frames once ending on the idle pose with `HOTLINE_` under it, the one place the animation is prominent; the project detail's summary/icon position, a static idle frame; the AGENTS route as an empty-state or ambient element. Nothing on Home: no mascot on the AGENTS panel header, nothing around Capture in this section. The mascot is never bound to aggregate agent state. The state sheets ship as reusable assets and the `Sprite` widget accepts any of them, but no surface opts into `working`, `blocked`, `alert`, `success`, `looking` or `sleep` yet; each later surface asks for its state by name. Agent rows keep §39.30's vendor marks; the reference draws the skeleton there, but the row identifies the vendor.
- Character: one canonical base grid (`design/sprites/mascot/base.txt`) reconstructed by hand from the reference's top-left figure (`design/references/concept/hotline-mascot-base-crop.png`), never the generated pixels taken literally. Every frame of every state is a derivation of that base with the same silhouette and proportions: the same character turning, moving and reacting, the way the Ghostty mascot does, not a set of independent illustrations.
- Launcher icon: the `idle` first frame at exactly ×16 on §39.8's ground, centred, safe zone respected, adaptive foreground and background as §39.8; file names unchanged so nothing in `android/` moves.
- Not built: the reference's aux icon tiles (today's `hl-*` set stays; kinds that do not exist yet wait for their feature), sound.
- Ownership: artist `design/sprites/`, `design/tools/`, `assets/sprites/`, `assets/icon/`; builder `lib/design/sprite.dart`, the splash route, the bindings. Regression tests: the manifest parses and every listed sheet exists with `frames × 48` width; frame index over elapsed time for a loop and a hold; integer scale choice from the available height; the state mapping table from snapshots, including the 3 s holds.
- Version bumps with the build that ships it.
