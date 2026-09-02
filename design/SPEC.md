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
- A DROPS panel header (Home and project) gains a `SELECT` text action on the right, next to the count, tracked uppercase like `NEW +`. Tap enters §39.13 selection mode with nothing checked; the contextual bar appears with `0 SELECTED`, arrow and trash disabled at `--fg-dim` until the first check. Long-press keeps working as before. `SELECT` is hidden while the panel is empty and while selection mode is active.
