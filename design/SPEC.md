# DAZZLE

The contract. What the app is, what it looks like and what it does — in the present tense, as it stands. It is not a changelog: nothing here overrides anything else here, and where a decision replaced an earlier one only the survivor is written down. Git holds the order the decisions arrived in, the dates and the words they were asked in.

A section says what has to be true. `Struck:` paragraphs say what was considered and refused, and why — they are part of the contract, because the reason a thing is absent is worth as much as the reason a thing is there.

## What it is

### Dazzle is one person's control plane, and it runs on their phone

Local-first, single-user, mobile-first, Flutter. There is no account, no backend, no cloud, no sync and no websocket to a service. What the app knows is in a SQLite file in its own sandbox, and what it reaches out to, it reaches on a connection the user opened to a machine the user owns.

It answers a small number of questions and it answers them fast: what am I working toward, what is the next thing, what is stuck, where do I put this thought before it is gone — and then, because the work is on machines and not only in lists, what are my machines doing, what is the agent on that machine waiting for me to say, and what does the code look like right now. It is a real tool, not a gamified task manager and not a personal Jira.

The reference for the look is `design/references/concept/dazzle-concept-v0.png`. It is direction and not a pixel spec: its typography, alignment, icon and spacing inconsistencies are the concept's, not the app's.

### The qualities the surface has to keep

Dark and high-contrast. Dense but readable. Strong typography. A restrained tactical character. Hard-edged hierarchy. A subtle system and terminal influence. Custom iconography. Compact navigation. Functional composition — every panel is there because something is in it.

### The influences are a language, and never an asset

Nothing is copied: no logos, no icons, no layouts, no fonts, no textures, no SVGs. What transfers is grammar.

- **Watch Dogs 2, the DedSec surface.** Objective hierarchy, black and white contrast, strong section headers, unconventional icons, information density, deliberate irregular detail. Not hacker parody: no graffiti, no fake terminal jargon, no hex strings for decoration, no glitch everywhere.
- **Ghost Recon Breakpoint.** Tactical organisation of information, compact status, an objective/state/metadata hierarchy, modular panels, a utility-first HUD, a compact symbolic language.
- **Control.** Severe typography, institutional confidence, graphic simplicity, strong geometry, signage, black and white with one accent, restrained brutalism, structured blocks.
- **Real systems.** Avionics displays, tactical radios, industrial control panels, SCADA and HMI screens, emergency comms equipment, technical diagrams, equipment labelling, signal diagrams, wayfinding, instrumentation. These are what keep it from becoming fake sci-fi.

### Anti-slop

Forbidden by default: Lucide or Lucide-like icons, generic outline icon sets, glassmorphism, blue-purple and purple-pink gradients, pastel blobs, giant blurred lights, excessive glow, generic SaaS cards, huge radii, excessive pills, giant one-stat cards, fintech and Notion and Linear and crypto-dashboard aesthetics, floating action buttons and decorative floating panels, decorative charts, arbitrary futuristic numbers, meaningless HUD decoration.

The rule under all of it: an element that does not communicate hierarchy, state, interaction, identity or useful context is removed.

### Identity

Technical, controlled, direct, serious, personal, highly functional, slightly unconventional. Tactical without military cosplay, futuristic without sci-fi clutter.

The words it is built out of: signal, control, connection, routing, status, structure, intent, priority, acknowledgement, system, local, trusted.

**The app is distinctive with no logo, no accent and in monochrome.** The identity is carried by typography, geometry, composition, icon grammar, hierarchy and interaction, and it has to survive all three of those being taken away.

### The words on screen are concise and utilitarian

Good: TODAY, ACTIVE, BLOCKED, RECENT, NEXT ACTION, IN PROGRESS, SEARCH, PRIORITY, COMPLETED. Bad, and the reason this section exists: OPERATION BLACKFIRE, TACTICAL EXECUTION MATRIX, MISSION CRITICAL STRIKE, THREAT LEVEL DELTA.

### Every screen answers the same ten questions

1. Is the primary action visible in about a second? 2. Is every panel necessary? 3. Could a container be spacing instead? 4. Is anything on it decorative? 5. Does it look like a generic AI dashboard? 6. Does it work in monochrome? 7. Is it readable on a real phone? 8. Are the icons consistent? 9. Is the tactical influence credible? 10. Does it feel like Dazzle rather than a game-UI collage?

### The architecture is local, and the layers are one way

Flutter, an application layer, repositories, then SQLite through Drift. Ids are UUIDv7 from the first row written; nothing depends on an autoincrement.

```
lib/
  app/          the shell of the application, routing, startup
  application/  state and use cases, Riverpod
  data/         Drift database, tables, repositories
  design/       colors.dart typography.dart spacing.dart motion.dart tokens.dart components/ effects/ icons/
  features/     home/ projects/ tasks/ hosts/ ssh/ shell/ code/ screen/ agents/ plugins/ settings/
  platform/     the channels and clients that reach off the phone
  plugins/      the runtime plugins are loaded into
assets/ fonts/ icons/ textures/ sprites/ icon/ host/
```

The design system is the app's own, not default Material. Colours, typography, spacing, radii, borders, motion and icon sizing are all tokens. Icons are SVG through `flutter_svg`. A Material or Lucide glyph is never substituted for a house icon because it is faster; placeholders are allowed while isolated functionality is being built and are never what ships.

### The objective

A private, local, high-signal control surface for one person's projects, machines and attention. The target is not "a video game UI as an app". It is a real tool whose visual language absorbed tactical interfaces, industrial systems and strong game UI.

## The look

### The palette is neutral, and one colour means something

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
accent               #B7FF2A   (a less aggressive alternate: #A7D91E)
warning              #D6A34B
danger               #B84A4A
info                 avoid blue unless it is functional
```

The accent is sparse and the screens are overwhelmingly neutral. It marks what is active, what is progressing, what is selected and what the user is being asked about — never decoration, never a large coloured surface, never a glow.

### The type is three faces doing three jobs

The face in the concept image is unknown and is not treated as identifiable. Everything shipped is a real, legally usable font.

- **Display and headers:** Barlow Condensed. Condensed, strong, industrial, comfortable in uppercase. No distress texture on normal UI text; that is for rare branding moments only.
- **Body and long form:** IBM Plex Sans, and only for note bodies and descriptions.
- **Everything else:** IBM Plex Mono. Row titles, subtitles, values, labels, timestamps, ids, state words, small readouts.

The hierarchy: a rare condensed uppercase hero; screen titles 24–30 condensed; section headings 12–14 uppercase and tracked; item titles 15–17 medium; body 14–16; metadata 11–13 mono or condensed. It is read on a phone in a hand, and usability is never traded for HUD imitation.

### Geometry is an 8px grid and a 1px border

Spacing comes from 4, 8, 12, 16, 24, 32 and 40. Corners are 2 to 8, square is fine, and there are no large radii. Borders are 1px and are used actively to organise. Shadows are minimal — contrast between a border and a surface does the work instead. Panels are flat, compact and structured. Separators, grouping, alignment and typography are preferred over nesting one container inside another.

### The icon system is the app's own

No Lucide: not as a dependency, not as a reference, not as a placeholder, not as inspiration. The Dazzle vector system is geometric, angular, technical, compact and schematic, internally consistent, minimally rounded, recognisable at 16–24, and not a set of cyberpunk glyphs.

Its primitives: brackets, nodes, lines, routed paths, frames, signal waves, diamonds, triangles, crosses, squares, broken and open geometry, directional markers. The family covers navigation, the entities, and the states — done, pending, active, blocked, warning, failed — and grows into the future vocabulary of message, channel, priority, critical, acknowledged, encrypted, verified, device, sync, relay, vault and connection.

A new family is not drawn one glyph at a time. First an exploration sheet of twenty to thirty experiments from the primitives, then a grammar is picked, then the family is derived from it: a 24×24 base viewBox, a stroke around 1.5–2px equivalent, defined corner behaviour, fill rules, optical padding, a minimum size and an alignment grid, mostly square or angled terminals, a systematic mix of stroke and solid where it helps. Every icon has to look authored by one system.

The research is tactical HUD glyphs, avionics symbology, technical diagrams, telecom symbols, industrial labelling, map symbols, signal routing, radio interfaces, equipment status icons and geometric wayfinding. Games are visual research only; their SVGs and textures are never extracted.

**A glyph that skips the grammar is the one that reads as foreign.** The tell is always the same: a stock outline symbol standing in for a thing — a sheet of paper for machines, a cog for settings, a notched cross for extensions, three dots for a place. So no glyph reaches `assets/icons/` without an approved file in `design/production/icons/` and a row in that directory's index naming its meaning, its node class, its modifier and its minimum size. A closed outline is drawn only where the container is the subject — a rack unit, a bay of slots, a keycap, a control frame — and never as a traced picture of an object.

**No destination and no action borrows another's glyph.** A borrowed glyph is a claim the two things are the same thing, and the reader believes it.

**A plugin is drawn as a part that plugs into something.** Its own body, with one edge carrying a keyed tab squared off. The round knob a puzzle piece really has is a curve the grammar does not own, and the tab alone is enough: nothing else in the family has an edge that interrupts itself.

### Assets are sorted by what they are allowed to become

```
design/
  references/    external research, never shipped
  explorations/  icons/ layout/ typography/ textures/ — generated, not approved
  production/    icons/ textures/ branding/ — approved and Dazzle-owned
```

The app ships only assets whose licensing and provenance are safe.

### Texture is felt and not seen

Allowed, extremely restrained: subtle noise, a slight print or scanner texture, a fine grid, a faint scanline, a tiny signal distortion. Forbidden: giant glitch overlays, RGB split everywhere, grunge on normal text, unreadable surfaces, a CRT effect that costs legibility. Texture belongs to backgrounds, branding moments, transitions and empty states, and never sits on important text or on a control.

### Motion is quick, deterministic and sharp

100 to 220ms. Short opacity changes, short directional movement, a controlled panel reveal, a subtle signal pulse, interpolated progress, an occasional scan transition. No bouncy springs, no overshoot, no toy movement, no particles, no constant animation, no huge glitch transitions. Motion is there to communicate a change, a connection, new information, a state transition or hierarchy — and nothing else.

### Every section on every screen is a panel

1px border in `borderNormal`, radius 2, `surfacePrimary` fill, 8px of inner padding. The section header is a strip inside the panel, filled one step lighter than the panel, running the panel's full width with a rule under it: mono 11, uppercase, tracked, `textMuted`, with a right-side affordance in the same style — a count, `VIEW ALL >`, `1 >`, `ALL +`. Panels stack with 8px gaps. There are no bare section headers and no hairline-only separations between sections.

### Mono dominates, and the condensed face is for titles

Screen titles are Barlow Condensed with a trailing `_` cursor: `TODAY_`, `PROJECT_`. Everything else is IBM Plex Mono — row titles 13 at w500, row subtitles 11 in `textMuted`, values 11 right-aligned, labels 10 uppercase and tracked. IBM Plex Sans appears only in a long-form note body or description.

### Density is a 4px rhythm

Rows are content-driven on a 4px rhythm — 10 of padding, a 4 line gap, which lands around 40, 57 and 70 for one, two and three lines — and the row box is the tap target. Panels gap 8. Screen side padding is 16.

### A row has an anatomy

Left: a 14px glyph — a checkbox, a node, a warning — when the row is actionable. Middle: a title over a subtitle, both mono. Right: one value column, mono 11, right-aligned, carrying a percent, a duration, a time or a count. A progress bar is short and inline on the right, 48–64 wide and 2 tall, beside its percent, and never full-width under the row.

### A text action's label is small and its hit area is not

Every text-only action — `VIEW ALL`, `NEW +`, `SELECT`, `SYS`, `EDIT`, `ARCHIVE`, `UNARCHIVE`, `COPY`, `ADD`, a count that opens something — takes a hit box of the full height of the strip or row it sits on, and a width of its label plus a medium space on each side, never narrower than the minimum tap target. The label does not move: the padding eats into the gap between neighbouring actions, so the visual gap stays large while the hit boxes abut.

The panel header strip is a row height, 36, so a strip action's hit is 36 by at least 44. The title, the count and the affordance stay vertically centred and the body padding is unchanged. The breadcrumb row does the same and is at least 36 tall.

An action presses to accent ink for the duration of the press. An action with nothing behind it is a readout and is never painted as pressable.

### A toast is the one thing that floats, and it stacks

A toast is a panel the app raises over the bottom of the screen to say what just happened, when what happened leaves no mark the screen can show. It is drawn as any panel is — `surfacePrimary` ground, a hairline `borderNormal`, radius 2 — capped to the content column and inset at the screen edge, and it is the one surface that floats: it draws over whatever the screen has pinned down there, the capture bar, the selection bar, the parked shell bar, and none of them move to make room. It stops at the nav bar and never covers it.

A row is the verb that happened, in the panel-header style and `textMuted`; the subject beside it in mono 12 and `textSecondary`, clipped to one line; and the way back at the right, in the accent. The accent is on that one word. The ground stays a panel's ground, because a filled accent bar across the screen is the large coloured surface the palette forbids.

**Toasts stack rather than replace each other.** Every live one is a row in the one panel, ruled between as any row group is, newest at the bottom where the thumb already is. Three rows are shown. A fourth folds the older ones away behind the panel's own header strip, which reads `+N MORE` and is tapped to open the stack and tapped again to fold it. Six rows is the whole stack, and the oldest leaves when a seventh arrives.

**A toast with a verb on it holds thirty seconds, and one with nothing to tap holds four.** Each row runs its own clock and leaves on its own. The long hold costs nothing, because a toast is never the only way back to what it undoes: the thing it reverses is still on the screen behind it, and the row that did it is still the way to do it again.

**A field taking focus takes the whole stack with it.** The form's scrim covers everything outside the form, and a notice dimmed under a scrim, carrying a verb nobody can reach, is worse than no notice at all; so the stack empties when the keyboard comes up rather than waiting underneath it.

Rows arrive as a short rise and a fade over 140ms and leave the same way. Nothing pulses, nothing counts its seconds down on screen, and a row already up does not move when another lands under it.

**A toast is raised for what the user cannot see, and never for what the screen already shows.** An action whose result is the row under the finger says so on that row. A toast that only confirms is the app talking over a screen that has already answered.

**Struck:** `DONE · UNDO` as a filled accent bar standing in the capture bar's place. The interpunct read as two buttons where there was one, it painted the loudest surface in the app for the rarest tap on the screen, and it took capture off Home for thirty seconds to say what one line of text says.

### The header of a screen says where it is

A breadcrumb line above the title, mono 10 in `textMuted`, then the title with its cursor. There is no clock and no date anywhere in the app: the system status bar already draws the time, and a date line is noise. That generalises — the app never repeats information the system UI already displays.

### Glitch is an event, never a state

Every effect is triggered by a real change or by a scheduled tick, is over in under 400ms, and is deterministic: the same input seeds the same frames. No infinite loops, no random jitter on idle text, no RGB split. The palette for all of it is `text.primary`, `text.muted` and the accent. The system's reduce-motion flag disables everything here except opacity fades.

**Icon glitch.** Five frames at 45ms, the fifth clean. It fires when the entity the icon stands for changes state, when a nav tab becomes active, and when a capture lands. A capture landing fires on the capture panel's own target glyph as well as on the HOME nav icon, because with the keyboard up the nav bar is covered and the glyph under the thumb is the only landing the user can see. When the entity leaves its list — a done toggle — the row is held in place for the glitch while the write goes out immediately.

**Text decode.** Screen titles and section headers resolve on entry: two to four characters cycle through a small mono set — `/ \ | - _ ▪ ▫ ◆` — for 120–200ms and then lock, left to right. On screen entry and on a data refresh only, never on scroll.

**Scan reveal.** A 1px accent line sweeps a panel top to bottom over 220ms while its content fades in. A scanline texture at 4% or less is allowed during the sweep only.

**Signal pulse.** A live or active indicator pulses once every four seconds — 80ms up, 200ms down — rather than breathing continuously. A progress bar snaps then settles: 90% of the delta in 60ms, the rest eased over 160ms, with the diamond head marker flashing accent for one frame.

**Autonomous ticks.** Every 20 to 40 seconds, seeded per screen, exactly one small thing happens so the tool reads as running rather than idle: a mono readout re-decodes, one metadata value flickers to muted and back, the active nav icon takes a two-frame slice, or the live dot pulses. Never two at once, never on text the user is reading — an input field, the row under a touch — and paused while scrolling or typing.

**Transitions.** A tab switch is a 140ms fade with a single one-frame displacement on the incoming screen title. A push is a 220ms fade with a 2% slide, plus a scan reveal on the primary panel.

Still forbidden: constant flicker, glitch on body text, screen-wide displacement, particle noise, anything that delays input readiness, anything over 400ms.

### The glitch is made of blocks, not slices

The look is the cover of Public Memory's *Wuthering Drum* (`design/references/glitch/wuthering-drum-cover.jpg`), and it is the target for every glitch in the app, moving or frozen.

- **Blocks.** A displaced region is a rectangle with its own height (from a sixty-fourth to a quarter of the glyph) and its own width (rarely the full width; most span an eighth to a half), shifted sideways by a thirty-second to a sixth of the glyph's width. Blocks may overlap.
- **Mosh.** One or two blocks are copies of a *different* region of the same glyph rather than shifted originals, so a piece of the shape appears where it does not belong.
- **Fragments.** Two or three small blocks detach fully and sit in the empty space beside the shape.
- **Per-block tone.** Each block shifts luminance one step up or down — a light block over dark ground, a dark block over light. The accent frame stays the single colour event.
- **Grain.** The static supplies the grain behind everything; the glitch adds none of its own.

Each frame is a new random block set and the last frame is the clean glyph. Blocks and fragments stay inside the widget's box, and they paint over an intact base rather than cutting holes in it. A screen-level event may use the same language at panel scale. The glitch has to read as a deliberate corruption of a clean shape, so at least 70% of the un-glitched shape stays intact.

**Struck:** the nodes-only signal frame, where an icon was replaced by its routes-hidden variant for one frame. On a 20px glyph it left none of the shape.

### The background is animated static

The one exception to glitch never being a state. The source is the alpha-only tile `noise-fine.png`, animated by jumping the tile's offset to a new random position each frame. The pixels are never regenerated, it is never procedural, and it is never a GIF or a video.

Eight frames a second, on a `Timer.periodic` and never a `Ticker` — a `Ticker` asks for a frame every vsync, and the build that used one idled at about 49fps. The low rate is what makes it read as static instead of as smooth drift; 8 to 12 is the allowed range. Opacity stays at the texture table's 4%: static is felt, not seen, and if a screenshot makes it obvious it is too strong.

It lives on the scaffold background only — never on a panel, a row, a sheet or text. It pauses, drawn once and unmoving, when the app is not in the foreground, when reduce-motion is set, and when the device is saving battery or is thermally stressed; battery saver and a `PowerManager` thermal status of moderate or worse arrive as one `throttle` platform stream.

The cost is a budget and not a hope: the background sits under its own `RepaintBoundary`, a tick rebuilds nothing above it, and the tile is drawn as a GPU-tiled `ImageShader` over one rect. Measured on the emulator, release, idle on HOME: 16.5% CPU at ~49fps before, 5.3% at 8fps after, 0% while throttled. The grain paint itself is about 0.2% of that and the rest is the emulator's own per-frame floor.

### What the Watch Dogs surface actually contributes

**A real boot log.** A cold start shows the work it is doing — opening the database, running migrations, counting what is in it, loading fonts, naming the device — in mono 12, `textMuted`, with status tokens in accent. Lines appear at 40ms each as a floor, because a 120ms roll read as a flicker, and the whole thing is capped at 600ms and then hard-cuts to Home with no fade. It never blocks past the cap: if the app is ready earlier the remaining lines still roll at the floor cadence, and if it is ready later the log waits on the real step and the cap flushes whatever is left. The Android 12 splash exit animation is removed so the log is not composited under a fade. Reduce-motion skips it, and a warm start never shows it.

**A solid action bar.** The primary action on a surface is a full-width flat block filled with accent, its text in the background colour, mono and uppercase, with no border and no radius past 2. It is the capture submit when the field has text, the recommended row in a triage sheet, and a destructive confirm — which takes a state colour instead of the accent. Never navigation.

**A selected row is a block.** In a picker or an action sheet the focused or recommended row takes a solid accent block with inverted text and a `// ` prefix in mono. Everything else stays text on the ground. The tab bar keeps its accent text and top rule.

**Text smear.** The screen title on a tab change takes one or two frames of block displacement and settles, under 120ms.

**A dither field.** Empty states and the boot background use an ordered-dither dot field — Bayer 4×4, 1px dots, `textMuted` at 12% — instead of blank space. Static, never animated. It complements the noise tile rather than replacing it.

**A dot spinner.** The loading indicator is a 3×3 grid of 2px squares with one lit at a time, clockwise, 80ms a step. It appears only when a wait passes 200ms.

**Bracket labels.** A detail screen's field labels take the `[ LABEL ]` mono form for the key facts — `[ OBJECTIVE ]`, `[ BLOCKED BY ]`, `[ EFFORT ]`. Section headers keep the tracked uppercase form; brackets are for inline facts.

**A build string.** The version and short build id, in mono, at the bottom of SYS and nowhere else.

**Struck:** magenta and cyan pixel art, the spray-paint logo, glow, the light-grey bottom strip, and any motion longer than the limits above.

### The mascot is a pirate skeleton, and it is pixel art

The icon grammar's stroke rules do not apply to it: it is pixel art and nothing else, with no anti-aliasing anywhere in its path.

**The grid is one 48×48 cell per frame**, the figure about 26 wide by 38 tall with its feet on row 44, in three values only: transparent, text primary and accent. The source of truth is text grids at `design/sprites/mascot/<state>/<nn>.txt` — 48 lines of 48 characters, `.` for transparent, `#` for primary, `a` for accent. `design/tools/sprites.py` assembles `assets/sprites/mascot-<state>.png` with the frames left to right at 1×, and writes `assets/sprites/mascot.json` as the cell size and, per state, its frame count, its rate and whether it loops. **Nobody hand-edits the PNGs.**

**One canonical base grid** (`design/sprites/mascot/base.txt`) is reconstructed by hand from the reference, never taken literally from generated pixels. Every frame of every state is a derivation of that base with the same silhouette and the same proportions: the same character turning, moving and reacting, and not a set of independent illustrations.

The states: `idle`, two frames at 2fps, a breath; `looking`, two at 2fps, a hand at the brow; `working`, four at 8fps, walking with speed lines in primary; `success`, four at 6fps once, the sword up with sparks in accent; `blocked`, two at 2fps, a `!` in accent blinking; `alert`, two at 4fps, the sword up and a `!`; `sleep`, three at 2fps, `z Z` in accent rising. And `splash`: seven frames — init, draw, raise, turn, back, front, ready — once at 6fps, the last frame holding.

**It is drawn with `FilterQuality.none` at integer scales only.** ×2 in a project's summary card, ×4 on an empty state and on the splash. Never fractional, never bilinear. One `Sprite` widget takes a state name, reads the manifest once, advances frames on a `Ticker`, loops or holds the last frame, and stops ticking when it is not visible.

**The mascot is Dazzle's identity, not an agent-status indicator**, and it is never bound to aggregate agent state. It appears as a static idle frame in the launcher icon and in a project detail's icon slot; as the seven splash frames on a cold start, ending on the idle pose, which is the one place the animation is prominent; and as the idle loop at ×4 with `DAZZLE_` under it on the agents route's empty state, shown when no host is set or when every host answered with zero agents. A failing host is not empty: its reason line stays and the mascot does not appear. Nothing of it is on Home.

The other state sheets ship as reusable assets and the widget accepts any of them, but a surface opts into a state by name, and none has yet.

### The launcher icon is the mascot's idle frame, and it is not a badge

The idle first frame, centred on a flat dark ground, as the adaptive foreground and background. **The figure's bounding box fits inside a 58dp box centred on the 108dp canvas**, which clears every launcher mask shape with 4dp to spare inside the 66dp safe zone. Per density the scale is the largest integer that meets that: ×1 at mdpi, ×2 at hdpi and xhdpi, ×4 at xxhdpi, ×5 at xxxhdpi. Nearest-neighbour only, one render per density from the source grid, and never a resample of another density's PNG. Nothing is clipped by the circle, squircle or rounded-square masks, and the monochrome layer is the foreground's own alpha. The splash carries no wordmark.

**Struck:** a tactical patch — a raven carrying a rifle on an olive shield with a crosshair and grain. It reads as a badge.

**Struck:** the raven alone, glitched or standing, in hard-edged flat line art. The mascot replaced it.

## Home

### Four tabs, and the bar is glyph over label

`HOME`, `PROJECTS`, `HOSTS`, `SSH`. Each tab is a house glyph over a mono 9 label, accent on the active one, with a thin top rule segment over it. No floating centre button, no pill container, no glow.

**Every tab owns its glyph rather than borrowing one.** A destination is a place, and a glyph shared with an action says the place is that action. `HOME` is a house the roof is carried down into, open on the right, with the local endpoint inside it — a roof over a detached baseline was drawn first and reads as two objects rather than a place. `HOSTS` is two stacked rack units carrying a system node each — machines, not a page of text. `SSH` is a prompt caret with the cursor block inline after it, because what is behind that tab is a terminal and nothing about a terminal is an abstract coupling. `TOOLS` is a bay of docked slots holding unlike modules, which is what a destination filled by plugin pages is.

**Struck:** an `ACTIVITY` tab and a `SEARCH` tab. Activity events keep being written and nothing draws them; search, if it returns, returns as a field on Projects rather than as a place to go.

### Home is the agents first, then the next thing, then the work

The panels, in order: `AGENTS`, because what the machines are doing is the most important thing on the screen; `NEXT ACTION`, present only when an item is actually marked next and absent otherwise; and `DROPS`, unfiled items newest first with bundles adjacent. Panels a plugin contributes stack in with the rest.

There is no suggestion fallback under `NEXT ACTION` — a panel that guesses at the next thing reads as a mock, and the one thing this screen must not be is a mock.

**Home has no screen title.** The breadcrumb line is the whole header, with `SYS` as its right-hand action. `TODAY_` and its cursor are gone: the panel under the crumb already says what the screen is.

**Struck:** a `PROJECTS` panel on Home, and with it a `VIEW ALL` and a `NEW +` there. A project is reached through its tab, and a new one is made from that tab's own `NEW +`.

**Struck:** a `BLOCKED` panel and a `RECENT` panel on Home. Blocking is reached from an item's quick view and the reason still renders in warning on the row; it is not a section.

**Leaving a screen is leaving it.** A tab switch clears the selection and the fresh set of the tab being left, exactly as a route push does, and coming back starts clean.

### The capture bar is a panel, pinned above the nav

Header strip `CAPTURE / QUICK ADD`, then the field line with a mono placeholder and the accent target glyph on the right. It is always visible on Home. Submitting creates a drop; it never submits empty text. The form closes itself the moment the item is in.

### The toolbar beside the keyboard is icons, and it holds text and links

One toolbar widget, shared by the capture bar and the item quick view. It is a 44px strip pinned directly above the keyboard, full width, in the panel-strip surface with a hairline on top. It exists only while a text field has focus and it leaves with the keyboard.

**Icons only — no labels and no captions.** Material Icons outlined at 22px, 44px of hit each, ink in `--fg-dim`, accent while the verb is active. One glyph per verb and no glyph used for two: link, image, more, back, target, next, block, pair, move, done. A long-press on any of them shows a one-word tooltip.

**The default row is `link`, `image`, `+`, and nothing else is visible.** Text goes in the field; links and images attach as chips. That is the whole capture path. `+` swaps the row in place over a 120ms cross-fade with no change in height, for the extras — on the capture bar, `target` alone; in the quick view, `next`, `block`, `pair`, `move`, `done`, or `move` alone while the item is a drop. A `←` at the left of the extras row returns to the default, and the row snaps back to the default after the keyboard closes.

**The link glyph never opens a form.** If the clipboard holds a URL it attaches as a chip with no prompt. If it does not, the focused field switches to URL mode — `https://` as the placeholder, the URL keyboard, the glyph lit — and submitting attaches the chip and returns the field to its title. Never a second field, never a sheet, never a dialog.

**The image glyph opens the system gallery picker**, gallery only and never the camera. The picked file is copied into the app support directory under `attachments/<uuid>.<ext>` and recorded as an attachment row.

Chips render in a single row directly above the toolbar, 28px, as `[ host ] ×` or a 28px square thumbnail with its `×`. They belong to the field and not to the body. On the capture bar the chosen target shows as the first chip, and the target resets after each submit.

**A scrim focuses the form.** While the capture field or a quick-view title edit has focus, `#000` at 60% covers everything outside the form — the field, its chips, the toolbar and the keyboard stay clear. It fades in with the keyboard over 120ms and a tap on it drops focus and closes the keyboard. It is the only thing that changes in the background; there is no blur.

**Struck:** the target as a `→ DROPS` text block, and a toolbar row between the header strip and the field. There is one toolbar and it lives above the keyboard.

### The empty Home names what is off

Home with no plugin card on it and no input bar draws one panel, `[ PLUGINS ]`, in place of the cards. Drops and Projects ship off on a fresh installation, so this is the first Home a new phone shows, and it answers the question that Home is asking rather than pointing at a settings screen.

The panel is one row per installed plugin that is off, bundled or not, in catalog order. The row is the plugin's name over what turning it on puts on the phone, derived from the plugin's own declared contributions and never written per plugin: a widget that can sit on Home is `<TITLE> CARD`, a widget that takes the input bar is `<TITLE> BAR`, a page pinned to the nav bar by default is `<TITLE> TAB`, any other page is `<TITLE> PAGE`, joined by middle dots. Drops reads `DROPS CARD · CAPTURE BAR`, Projects reads `PROJECTS TAB · NEXT ACTION CARD`, Agent schedules reads `AGENT SCHEDULES PAGE`. The row's value is `OFF`, muted, and a tap on the row opens plugin management, which is where a plugin is turned on. `MANAGE PLUGINS` stays as the panel's text action under the rows.

With nothing left to turn on, because every installed plugin is already on and none of them puts anything on Home, the panel is the one line `ADD HOME CARDS, AN INPUT BAR, AND TOOL PAGES.` over the same action. A plugin whose contributions are none of the four kinds is not listed, because there is nothing the row could promise. Home does not turn anything on itself, and Drops and Projects stay off by default.

## Drops and projects

### There is one item type, and where it sits is what it is called

- **Project.** Name, description, `objective` (one line), status — active, paused or archived — and a priority of four steps. Progress is done items over all items in the project; zero items is 0%. A project may have a parent project.
- **Goal.** Id, `projectId`, title, `createdAt`, `order`. Progress is done items over all items under it. A project has zero or more goals. The project's `objective` is the one-line statement of what it is for and is not a goal.
- **Task.** The single item type. Title, `projectId` nullable, `goalId` nullable, `bundleId` nullable, `done`, `blockedReason` (non-null means blocked), `isNext` (at most one is true across the whole database, enforced in the repository), the same four-step priority a project carries, an optional effort. There is no status enum and there is no "doing".
- **Note.** Belongs to a project.
- **Attachment.** Id, `item_id`, `kind` of `url` or `image`, `value` — a URL, or a path relative to the app support directory — and `created_at`. An item has zero or more.
- **ActivityEvent.** Written in the same transaction as every mutation it records.

Where an item sits is derived and never stored: no project means a **drop** on Home, a project with no goal means a drop inside that project, and a goal means an item under that goal.

**Items sharing a non-null `bundleId` travel together.** Moving one moves all of them, they render adjacent in every list, and the quick view lists the mates under `[ WITH ]`. Pairing is symmetric; unpairing clears the id on that one item only. There is no bundle entity and a bundle has no name.

The vocabulary on screen: headers say `DROPS` — unfiled on Home, goal-less inside a project — and `GOALS` for the per-goal panels. The word "task" and the word "idea" appear in no header; rows are rows.

**Struck:** the word `LOOSE` for an unfiled item, a `processed` state on one, and an Inbox for them to sit in. A drop is filed or it is not, and that is readable from where it is.

### Everything the user can see can be created, edited and deleted

**A project** is made from `NEW +` in the `PROJECTS` panel header on the Projects tab, which opens a full-screen form on a pushed route with no nav bar: name, description, objective, status, parent. The detail screen carries `EDIT` in its breadcrumb row and opens the same form prefilled. Delete is at the bottom of the edit form as a solid warning block that confirms in place — `DELETE PROJECT` becomes `CONFIRM DELETE` for three seconds. **Deleting a project un-files its items rather than deleting them**: they become Home drops.

**A goal** is made from `NEW +` in the `GOALS` area of a project, as a single-line editor inline at the top of a new panel that submits on enter. Long-pressing a goal's header strip offers rename and delete; deleting one drops its items back into the project's `DROPS`.

**An item** is edited in its quick view, and deleted there behind the same inline confirm.

### A row tap opens the item, and the item is the one modal in the app

The quick view is a bottom sheet in panel style. Its header strip is the item's location as a breadcrumb: `DROPS`, or `INFRA PERSONAL / DROPS`, or `INFRA PERSONAL / REDUCE SAAS`.

The body is a readout. The full title in mono 13, unclipped, tapped to edit in place — which raises the keyboard and its toolbar — and saved on blur or submit. Attachments follow: links as rows, mono 11, showing a label or the host, tapped to open in the browser and long-pressed to delete; images as a row of 56px squares, tapped for a full-screen viewer that is black, pinch-zoomed and dismissed with back, long-pressed to delete behind the same confirm. Then `[ WITH ]` when the item has mates, `[ BLOCKED BY ]` when it is blocked, and `[ EFFORT ]` when one is set.

The footer is one row of solid action blocks, and it is there for one-tap work when the keyboard is down: `DONE`/`UNDO`, `NEXT`/`UNSET`, `MOVE`, `PAIR`, `BLOCK`/`UNBLOCK`, and `DELETE` behind its inline confirm.

Done is also toggled without opening anything, by tapping the row's leading checkbox glyph — a 40px hit area — and the glitch and the row hold apply there too.

**Struck:** a separate action sheet on long-press. Long-press opens this same sheet. And this sheet is the only modal surface in the app; nothing else may be modal.

**Struck:** a `FieldPanel`, a `+ LINK` row and inline editors in the body. The body reads; the keyboard toolbar writes.

### Filing an item is picking a target, and pairing is picking an item

`MOVE` opens a target picker: `DROPS` first, then every active project as a header row with its goals indented one level under it, then the paused projects. Archived projects are absent. Picking a project files the item as that project's drop; picking a goal files it under the goal. A bundle moves whole.

`PAIR` opens a picker of items — drops and items under goals, open ones first, newest first, with the item itself and its current mates excluded — over a search field. Picking one joins the two bundles into their union. When the item is already in a bundle, `UNPAIR` stands where `PAIR` was.

### A drop has no state but done and how loud it is

A drop is text plus attachments. It carries `done` and its priority step, and nothing else: no next, no blocked, no pair. Those columns stay in the schema — the row becomes a task the moment it is filed — but no surface reads or writes them while the item is a drop.

Its quick view is the readout with `DONE` and `MOVE` on the footer, and nothing else: no state line, no `BLOCKED BY` panel. Its row on Home carries the checkbox and the dimming that done drives, and no other glyph. Nothing in the app is ever struck through.

**A goal is optional grouping and not a requirement for state.** A project's `DROPS` panel holds that project's items that have no goal, and they are tasks: the same checkbox, the same checked-and-muted done state, the same blocked line as an item under a goal, the full quick view, a place in the project's and Home's progress numbers, and the right to be `NEXT ACTION`. Filing a Home drop into a project or a goal turns it into a task, and only then do the remaining state blocks appear.

### A project detail is a hero over its panels

The screen title is the project name with its cursor — `INFRA PERSONAL_` — over the breadcrumb. The hero card under it carries a large project glyph, 32px in the signal-node grammar, with the description in mono 11 muted beside it; the name is not repeated inside the hero. A `STATUS` row appears only when the project is paused or archived. Then the objective panel, with the big percent in Barlow Condensed 28 in accent and `n OF m TASKS` in mono under it.

Under that: the `GOALS` panels, the project's `DROPS`, and the notes. An item that is blocked shows its reason in warning on the row, and the `isNext` one carries the accent arrow in the trailing column.

**Struck:** a diamond node on a project row, and a `>` on any panel with nothing to open.

### A project can sit inside a project

A project optionally belongs to another project, and projects form a tree of arbitrary depth. There is no subproject entity: a subproject is a project with a parent. Every project holds its own goals, items, drops and notes wherever it sits. The hierarchy is navigational and never explorer-like — the whole tree is never on screen at once.

`projects.parent_id` is nullable and references a project. The repository refuses a parent that is the project itself or any of its descendants, and the form never offers those rows, so the tree cannot be made to loop.

**A root is a project with no parent, and only roots are listed flat.** The projects list and the `ARCHIVED` panel under it show roots. A child is reached through its parent's detail and never from a flat list. The move picker stays flat — every active project, then its goals — but a child's row carries its parent path as the subtitle: `INFRA / HOMELAB`.

**A parent's number is its subtree's number.** Progress is done over all items of the project and every descendant, as one number; zero items in the subtree is 0%. The `n OF m TASKS` line under a parent's title counts the subtree too. `NEXT ACTION` and its priority ordering keep using an item's own project.

**A project's detail exposes its immediate children.** After the objective line and before the goals sits a `PROJECTS N` panel listing them as project rows — name, objective, subtree progress — each opening the child's detail as a pushed route on top of the parent's, with `NEW +` opening the project form with the parent preset. The panel is absent when a root has no children; a childless child shows it empty with `NEW +`, so the depth stays discoverable.

**The breadcrumb carries the path and never wraps.** `/ PROJECTS / INFRA / HOMELAB` for a child two deep. When the path does not fit beside the trailing verbs, the leading ancestors collapse to a single `…` and the immediate parent always survives. Every ancestor segment is tappable and pops the stack back to it; the leading `PROJECTS` segment pops to the list.

**A `[ PARENT ]` field under status is how a project moves.** The picker offers `NONE` first, then every active project except the project itself and its descendants, each row carrying its parent path as a subtitle. Changing the parent is the move; children keep their own `parent_id`, so the subtree follows without a write.

**A project is hidden when it or any ancestor is archived.** Descendants keep their own status column, so unarchiving the parent restores them exactly as they were. The `ARCHIVED` panel lists only projects whose own status is archived and whose parent is not hidden. Opening one draws its children dim, and their `UNARCHIVE` is absent while an ancestor is archived. Items under a hidden project leave Home the way an archived project's items do.

**Delete cascades to the subtree**, in one transaction, and the confirm reads `DELETE PROJECT AND N BELOW?` when there is anything below it.

### An objective is optional, and archiving is one tap

When a project has no objective its row — on Home, in the list, in a picker — shows the name on the title line and drops the small label line: no blank line, no dash, no placeholder. Its detail omits the objective panel entirely while the hero, the status row and the progress stay. The form keeps the field, blank.

Archive is an action and not a trip through the status field. The detail's breadcrumb row carries `ARCHIVE` beside `EDIT`, and `UNARCHIVE` when the project is already archived. Archiving asks once, in a panel-style modal — `ARCHIVE PROJECT?` with `CANCEL` and `ARCHIVE` — and unarchiving does not ask. Both keep every item filed where it is. An archived project leaves `NEXT ACTION` and leaves the move picker; the projects list gains an `ARCHIVED N` panel at its bottom, collapsed until its header is tapped, whose rows render dim and open the detail where `UNARCHIVE` lives.

The status field on the form still offers archived, and both paths write the same column.

### Holding a drop selects them all

Long-pressing a drop row enters selection mode with that row checked. There is no strip on the row and no menu on it, ever.

While the mode is on, every drop row in that panel carries a 20px mono checkbox at its left — `[ ]`, `[x]` in accent when checked — and a tap toggles the row instead of opening it. The long-press is not needed again.

**The panel's header strip becomes the contextual action bar**, the way a file manager or a mail client does it: `×` on the left to cancel, `N SELECTED` beside it, and on the right two icons only, a forward arrow for move and a bin for delete, 22px with 44px hits, ink `--fg-dim` and accent on press. No text blocks and no bottom bar; the capture bar stays where it is and is inert while the mode is on.

Move opens the target picker once and files every checked item. Delete opens a panel-style confirmation — `DELETE N DROPS?` with `CANCEL` and `DELETE`, the destructive one filled accent — and nothing is deleted before that second block. `×`, the back gesture, or finishing either action leaves the mode, and the selection never survives a navigation away from the panel.

A `DROPS` panel header also carries a `SELECT` text action on the right beside its count, in the tracked uppercase of `NEW +`. It enters the same mode with nothing checked: the bar reads `0 SELECTED` with both icons in the idle disabled ink until the first check — `--fg-dim` is brighter than that ink and would invert the state. `SELECT` is hidden while the panel is empty and while the mode is on.

Home's `DROPS` and a project's `DROPS` both have this. A row under a goal keeps its quick view.

**The selection bar stays where the thumb left it.** It is pinned to the bottom of the surface rather than riding the list, so scrolling through a long selection never takes the verbs off the screen.

### A slide sets how important a row is, and a numeral carries it

Every item row and every project row takes a horizontal slide. A slide right raises the row one step, a slide left lowers it one step, and the row snaps back to where it was either way. One gesture is one step, so the top is three slides up from the floor.

There are four steps and three of them are counted in Roman numerals. The numeral has a column of its own on the right of the title, in the kicker's mono at the kicker's size, right-aligned so `I` and `III` end on the same edge:

- **The floor only subtracts, and it has no numeral.** The title goes muted, the age and the checkbox go with it, and nothing whatever is added. A row parked here is the quietest thing in the panel, and it is the one step read by what is missing.
- `I` is the row exactly as it draws otherwise, in muted ink. It is where a captured item and a new project land.
- `II` is the same numeral one step brighter, in the secondary ink.
- `III` is accent.

**The numeral column is held whether a numeral is drawn or not**, so a row on the floor sits in the same grid as a row at the top and stepping one row moves no neighbour by a pixel.

**The glitch is progressive and it is on the numeral alone.** `I` and the floor are still. `II` tears every few seconds, lightly and in few blocks. `III` tears about twice as often and in more of them, so the top of the scale is the thing in the panel that will not hold still. The corruption is seeded off the row's own id, so two rows on the same step never tear in lockstep, and the glitch never leaves the numeral's box: it marks the rank and not the title. Reduce-motion freezes all of it, and the ramp still reads, because it was a numeral before it was an effect.

**Every step is the same type at the same size.** No step changes the title's size, its weight or its ink. The ramp is the numeral, the numeral's ink and the numeral's glitch, and the panel is a grid before it is a ranking.

Done still wins: a done row shows its numeral in the disabled ink and stops glitching, whatever its step, because the step says what is worth reading and a done row is not.

The row travels under the finger while the drag is on, capped short, and returns over 140ms. **A slide with nowhere to go does not move the row at all** — left at the floor, right at the top — so the end of the scale is felt instead of announced. The recogniser is horizontal only, so the list still scrolls under the same thumb, and the system's own edge gesture keeps the screen edge.

**A slide changes how a row reads and never where it sits.** Drops stay newest first and items under a goal keep their order. A project row is the exception and not a new rule: the projects list already sorts by priority under status, so a slid project does move in it.

The step is per item, and a bundle does not share it. Mates travel together when they are moved and are slid one at a time.

**The project form has no priority field.** The slide is the whole gesture, so a row is the only place priority is set, for a project exactly as for an item, and a picker would be a second way to say the same thing. The quick view has no priority block for the same reason, and the activity feed records the direction — `raised`, `lowered` — and never the step.

The slide is off while a panel is in selection mode, and the `NEXT ACTION` card does not take it: it is one card and not a list.

**Struck:** a numeral on the floor, a step that grows the type or thickens it, a glitch on anything but the numeral, a slide that cycles from the top back round to the floor, and a drag whose distance picks the step.

### A URL is painted in the field before it is a chip

While the user types in the capture field, any token the app already recognises as a URL is painted in the field itself: mono, `--fg-dim` ink on a `--panel-strip` ground spanning exactly the token, no underline and no icon. It says before submit that the token will file as a link. The token stays editable text — the highlight is a span, not a chip — and it changes nothing about what submit does.

### A URL typed inline becomes an attachment, and the title keeps its words

A URL typed inline is extracted on submit into an attachment row, and it is stripped from the title only when the title would otherwise be empty. Otherwise the title keeps the text exactly as it was typed.

### A project's detail captures into itself

A project's detail carries the capture bar pinned at its bottom: the same component and the same extras as Home's, with the target fixed to that project. Submitting files a project drop and the row appears at the top of that project's `DROPS`.

There is no target chip and no `target` extra, because the project is the target and cannot be changed from here; filing under a goal is a move from the row. The bar clears and closes on submit like Home's. The capture landing fires on the project's `DROPS` panel header glyph, since a pushed route has no nav bar under it. The bar is hidden while the project is archived.

### A drop just written is fresh, and a hold takes every fresh row

A drop captured from a screen's capture bar is *fresh* on that screen until the user leaves it. Fresh is interface state and not a column: it lives in memory per scope — Home, a project — never in the database, and never across a restart.

The highlight is minimal: the row's age value, `now` or `1m`, is painted accent instead of `--fg-dim`. Nothing else on the row changes — no glyph, no background, no border.

**Long-pressing a fresh row enters selection mode with every fresh row of that panel checked**, in one gesture. Long-pressing a row that is not fresh clears the fresh set and enters the mode with only that row. `SELECT` ignores freshness and enters with nothing checked, and a tap on a fresh row outside the mode opens its quick view as always.

The set clears when the user leaves the screen — a pushed route, the back gesture, a tab switch, the app leaving the foreground — and when a batch removes every fresh row. Cancelling the mode with `×` does not clear it, because nothing happened.

**A fresh id leaves the set only when it has been shown and then goes.** An id the list has not drawn yet is never pruned: the panel keeps the set of ids it has rendered and prunes both the fresh set and the selection against ids that were rendered and are now gone. Pruning by absence instead loses a race with the stream, and a fast run of captures then lights some rows and not others.

### A link opened in the quick view says what is at the other end of it

A drop whose text is a URL is the commonest thing on DROPS and the least legible: forty characters of path under a host, filed weeks ago, and the only way to remember why it was kept is to leave the app and load it. The quick view asks the page instead. Under `[ LINKS ]` the link is a card — the page's own picture, its title, the first of its words, and who wrote it when the page says — and the user reads the line they filed without leaving the phone.

Three conventions answer the question and they stack rather than compete, so all three are read and the first that has a field wins it. Open Graph is what a page publishes for anything that unfurls it. Twitter's card names are the same fields under other names, for pages that only ever shipped those. oEmbed is a JSON endpoint a page advertises for whoever wants the thing itself, and it is the only one that reports an author — which is what makes a card for a post say what the post said, since a post publishes no description at all. Under all three sits the title and description every HTML document has had since before any of them existed. The handle a page lists as its own account is not read as a site name: it is `@somewhere`, and the host is the better word.

Finding the endpoint is part of the oEmbed convention, so no list of sites is needed to find one. A short list of endpoints exists anyway, for the hosts that serve a page to a browser and its metadata to nobody: a host earns a line on it by failing the convention outright — serving its own discovery link and its Open Graph tags only sometimes, while its endpoint answers every time — and the line says where to ask, never how to read the answer. That is what keeps it from being a per-host rule table, which this app has already struck once: nothing on it changes how a host is parsed, and a host that keeps its promises never reaches it.

**Nothing leaves the phone until a drop is opened.** Filing a link sends no request, so a link captured on the underground costs nothing and a page learns the phone exists at the moment its link is read, not at the moment it is kept. The first few links on an item get a card and the rest keep the row they always had: a card is a request, and an item that is a wall of links is a list rather than a page. A URL typed into the text leaves no attachment behind, so the title is read for links too — the card is the same either way, and only a link the item actually holds can be long-pressed off it. A URL in the title that answers nothing draws nothing: it is legible where it stands, and that was already the rule.

Only the head of a page is read, and the read stops at the tag that closes it: everything the three conventions declare is above that line, and below it is the megabyte of script a site is free to ship. There is a ceiling in bytes for a page that closes its head late or never, and a timeout for a phone on a train, past which the card is not worth the wait. The request says it is this app and nothing else. A page that will not answer, answers with nothing, or answers with something that is not a document is not an error on screen: no card is drawn, and the link keeps the row it always had. Nothing waits for one either — the rows are there from the first frame and a card takes a row's place when it lands, so an item opened with no signal reads exactly as it did before any of this.

What came back is written to a file in the cache directory, not the database. A preview is a copy of somebody else's page — it goes stale, it can be reclaimed by the system without losing a word the user wrote, and it has no business travelling in the bundle that carries one phone to another. It is good for a week, the oldest goes once the file is full, and a page that answered with nothing is remembered as nothing for a few hours, so the link that will never have a card is not asked about on every open. Reopening an item draws its cards with no request at all.

Struck: fetching a link when it is filed. It would turn the capture bar into a thing that talks to the internet, put a request behind a drop written with no signal, and tell every page in a pasted list that this phone exists before the user has looked at one of them.

Struck: sending a crawler's name to get a crawler's page. It is a link preview that lies about who is asking, and the hosts that answer a crawler and not a browser are exactly the ones the endpoint list already covers.

Struck: reading the page inside the app. A card is the answer to *what is this*; the answer to *read it* is the browser, which is where the tap has always gone.

### A pasted link loses the campaign that was stamped on it

A URL reaches the phone through a share sheet or a copy button, and both of them write on it first. `utm_source`, `utm_medium`, `utm_campaign`, a `gclid` or an `fbclid` sixty characters long, the mail platform's `mc_eid`, the `si` a video or music share sheet stamps on an address that plays without it — none of it means anything to the page being opened, all of it says which campaign or which share produced the tap, and together it is why a pasted address fills three lines of a drop instead of one. The app cuts those fields out before the link is kept or handed over.

It happens where a URL is decided and nowhere else. Every address the app files or opens is read by one of two functions — the prose rule that promotes a bare host, and the explicit rule a terminal selection is tested against — and the second is the first's own parser, so the cut is written once, at the bottom of both. The capture bar's link line, the item sheet's, the clipboard the line is offered prefilled with, a URL painted inside a title, and the terminal's `OPEN` all get the same address.

A line that is committed keeps the clean address too. The token is painted where it stands and opened from where it stands, so a row reading `utm_source=newsletter` while the tap opened the address without it was the screen disagreeing with itself. The cut is made when the capture bar or the item sheet files the line, and never while it is being typed: text that rewrites itself under the cursor is worse than a long URL. Prose is left alone — a word counts as a link here only when it carries a scheme.

Families that number their fields are matched by their prefix, so `utm_` covers whichever one is invented next; the rest are named. Only the real query is read: a `?` after a `#` belongs to whatever routes on the fragment and is left alone. Everything that is not cut survives exactly as it was written — same order, same encoding, same empty values, and the `?` itself goes only when the last field in the query does. This removes fields; it does not rewrite a URL.

Struck: cutting the fields a page is entitled to read. An affiliate `tag` and a `ref` are a shop's accounting and somebody is paid for them, and a link that stops working is worse than a long one. A field is in the list only when the site receiving it does nothing the user asked for with it: a share id is not that, because the video opens on the id in the path and the field beside it only reports who passed the link on.

Struck: a per-host rule table. It is how a link cleaner ends up needing releases of its own, and the flat list answers the links a phone actually meets.

### A drop is finished where it lies

A stray drop is an item with no project, and until now the only ways it left HOME were MOVE, which invents a project for something that needed none, and DELETE, which throws away the text along with the fact that it was dealt with. Neither of those is what the user did: they read the line, they did the thing, and the line should be able to say so. Being finished is not a property of where an item was filed, so it is the one piece of state an unfiled item keeps.

The row carries the checkbox every other row carries. Same column, same forty-pixel target over the row's corner, same glitch on the glyph as the state turns over, and the same muted title afterwards. A finished drop stays on DROPS: the panel is the whole of the unfiled, done or not, and a row that vanished under the finger would take the undo with it and leave the user with nothing to aim at. The age stays in the value column, because a drop has no project and no goal to say where it is, and when it was written down is the only thing the column can hold. Finishing one raises a toast that names it and carries `UNDO` for thirty seconds; the checkbox is the other way back and it never expires.

The quick view names it on the footer of every item. `DONE` is the first block and takes the one filled accent surface in the row, `UNDO` when it is already done, and it draws for a filed task and a stray drop alike. The sheet's title dims with the state wherever it is opened from.

Nothing else follows it in. An item unfiled by MOVE keeps whatever `isNext` and `blockedReason` it had in the schema, so the row and the sheet suppress them rather than trusting the columns to be empty: no forward arrow, no blocked line under the title, no NEXT, PAIR or BLOCK on the footer. Done is the exception that was asked for, not a door the rest of the state walks through.

Struck: a `DONE` verb on the multi-select bar. Its verbs are the ones worth doing to a set — copy the text out, file them all under a project, delete them — and finishing things is done one at a time, by the row the eye is already on.

Struck: `done` in the toolbar extras behind `+`. That row exists for what cannot be reached while the keyboard is up, and the footer under the keyboard is exactly where DONE already is.

## Hosts and keys

### A key is made on the phone and never leaves it

A key row is the name over a truncated `SHA256:…` fingerprint in mono. A tap opens the key's detail — `[ NAME ]`, `[ TYPE ]` reading ed25519, `[ PUBLIC ]` as the full `ssh-ed25519 AAAA… name` line in a selectable mono field with `COPY` beside it, `[ USED BY ]` listing the hosts that reference it, and `DELETE` at the bottom behind a confirm.

A new key is a form with `[ NAME ]` and nothing else: ed25519 always, the comment being the name. It is generated on the device. **The private key never leaves the phone and is never shown** — the row lives in a `keys` table of id, name, public key and creation time, and the secret lives in the platform's secure storage under the key's id, behind the Android keystore.

**A key in use cannot be deleted until the host is repointed**, and the bar says so: it reads `USED BY N HOST(S)` where `DELETE` would be, rather than sitting there greyed and silent.

Installing a public key on a host is the user's own job, done by hand. The app never writes an `authorized_keys` anywhere.

### A host is a machine, not an integration

The `hosts` table is id, name, address, port, user and key id. A host is a machine that happens to run things; what the app is allowed to do there is a separate list.

The host form carries an `[ INTEGRATIONS ]` block, one ON/OFF picker row per integration the app knows about. **The transport behind an integration is the integration's own concern** — nothing in the schema names ssh — so a later backend that proxies one swaps the transport and leaves the host row and the integration row alone.

**No host is ever assumed.** The app connects to a machine because the user entered it and switched something on, and to nowhere else, ever.

### A host has a port, and the row says so when it is not 22

`hosts.port` is an integer defaulting to 22. A host row reads `user@address` when the port is 22 and `user@address:port` when it is not. The form has a `[ PORT ]` field between the address and the user, numeric keyboard, `22` prefilled on a new host.

Without it every machine whose sshd is not on 22 reads as unreachable no matter what its address says — and a machine whose 22 is a tarpit reads as unreachable while being perfectly up.

### The host form never hides its way out

The form needs a name, an address, a port, a user and a key. **The action bar is always drawn.** While the form is invalid the bar is dimmed and its label names the first missing part in field order — `NAME MISSING`, `ADDRESS MISSING`, `PORT MISSING`, `USER MISSING`, `KEY MISSING` — and a tap does nothing. A port that is empty or outside 1–65535 reads `PORT MISSING`. When the form is valid the bar reads `CREATE HOST` or `SAVE`. The label updates on every keystroke and every picker tap.

The convention of hiding a bar until the form is valid is fine where the only requirement is the field on the screen. It is not fine here, because one of the requirements is a tap on a picker row: hiding the bar hides the requirement, and the user fills everything they can see, finds no action, and leaves.

**`[ KEY ]` preselects the only key** when exactly one exists and the host is new. With two or more, nothing is preselected — a picker with one entry reads as already chosen, and a picker with several does not. Editing a host keeps that host's own key. With no keys at all the picker body is one dim line, `NO KEYS · NEW + IN SYS`, and the bar reads `KEY MISSING`.

**Leaving a dirty host form asks.** The back arrow or the back gesture raises `DISCARD HOST?` with `DISCARD` as its confirm. Dirty means a new host with any field typed, any key the user picked themselves — one the form preselected is not a pick — or any integration switched on; or an existing host with any value changed from what was loaded. A clean form leaves without asking, and a save or a delete pops without asking. This is the host form's rule alone: the key and project forms keep their silent back.

### A failure names the host, and names which kind of failure it was

`unresolved` is the address failing to resolve, before any socket opened. `unreachable` is everything after a name. The underlying error is written to the debug log with the host's name on every failure, so a report from a handset can be read without guessing.

### HOSTS is the tab for machines, and each machine is a panel

One panel per registered host, each with its own header strip carrying the host name and `EDIT` on the right, which pushes that host's form. The body is metadata rows: `ADDRESS` as `<address>:<port>`, `USER`, `KEY` naming the key, `INTEGRATIONS` as mono tokens of whatever is on or `NONE`, and a `STATE` row carrying the host's latest agent outcome when the agent integration is on — `3 agents · 1 blocked`, or the reason line in its colour. `ADD HOST` is the last text action after the panels, or the only thing there when no host is registered.

Under the host panels, a `KEYS` panel: a row per key, name over the shortened fingerprint, tapping into the key's detail, with `ADD KEY` as its last text action. **Hosts come first because they are what the tab is for.** Keys were listed first in SYS only because a host cannot be saved without one, and that rule now lives in the form.

Nothing on this tab edits in place. The form is the one editor. SYS keeps `[ STATIC ]`, `[ ALERTS ]` and `[ BUILD ]` and has no host or key block of its own.

### `LINK` says whether the machine answers at all

A metadata row above the shell row on each host panel. `—` before the first probe, `PROBING` while one is out, `<software> · <n> MS` when the machine answered — `OPENSSH_9.9 · 120 MS`, the software token taken off the identification string and uppercased — or the failure word in warning: `NO ROUTE`, `UNRESOLVED`, `REFUSED`, `NO BANNER`.

The probe is a TCP connection to the host's address and port that reads the identification line and hangs up, on a four-second deadline, with no key and no handshake. **It waits for the banner rather than settling for the connection**, because a port that accepts and then stalls is a tarpit and not a shell. It runs for every host when the tab comes to the front, at most once every thirty seconds per host, and on a tap of the row, which probes again whatever the age.

### A machine is verified before it is trusted, and a changed key is refused

Every ssh dial in the app — the shell, the screen's tunnel, the agent poll — verifies the remote's host key against one pinned on the host row and refuses when it does not match. The pin is a key type, a fingerprint in the OpenSSH `SHA256:<base64>` form and the time it was pinned. Those columns are nullable with no backfill: a host registered before the pin existed is unpinned and pins on its next connection. They say *host key* and not *ssh* on purpose — they identify the machine, not the thing running on it.

**Only a route the user is looking at may ask.** An unknown key pauses the dial and raises the confirm sheet — header `NEW HOST KEY`, the host name and `<address>:<port>`, the key type and the full fingerprint in mono, wrapped, then `REJECT` and a filled `TRUST`. That happens on a shell the user opened, on the screen route, and on `VERIFY`. The agent poll, the alert watcher and a reconnect never ask: they refuse an unpinned host and report `host key unverified`, which shows beside the host with `VERIFY` next to it.

**A changed key is refused everywhere, always, with no override on the connect path.** The line is `host key changed`, in warning. The only way past it is `[ HOST KEY ]` on the host form — the pinned type and fingerprint, when it was pinned, and `FORGET KEY` behind a `FORGET HOST KEY?` confirm, which drops the pin and lets the next connection pin whatever answers. A changed key is either a machine reinstalled or a machine in the middle, and the app cannot tell which; the user can.

### The deadline is on the machine, not on the user reading a fingerprint

The dial's timeout is armed at the connect and disarmed the moment the key arrives, so a sheet can stand open as long as the user needs. The transport's own deadline is set out of the way. The dial returns once the key has been answered for; authentication is never what it was waiting for.

A socket that opens and then says nothing is its own failure and not silence: that is a machine behind a tarpit, not a machine that is down.

### `VERIFY` is the whole report, in the row that was tapped

`VERIFYING` while a dial is out, and then the word it came back with when it failed — `NO ANSWER` for a socket that never presented a key, `NO ROUTE` for one that never opened, `KEY CHANGED` for a fingerprint that is not the pinned one, `NO KEY` for a host whose private key the keystore no longer holds, `FAILED` for the rest — in warning, standing until the next tap. A user who taps `REJECT` said no on purpose and gets `VERIFY` back, not a failure.

**Nothing is written only to the debug log.** A handset has no way to read one.

**A dial that came back clean is an answer.** A machine that presents the key the app already trusts refuses nothing and asks nothing, and the row takes that as the answer it dialled for: the affordance goes, whatever a background poll still says. The row's own dial outranks a poll it does not re-run.

**Saving a host dials it.** `CREATE HOST` and `SAVE` verify the machine themselves when the host has no pin, before the form is left, and raise the same sheet; the bar reads `VERIFYING` while that is out. Every failure leaves the host saved and unpinned with `VERIFY` on its panel — a machine that is not answering while a form is being filled in is not a reason to hold the user on the form.

**The pin travels with the host into the watcher.** A service that rebuilds a host without its pin dials with a verifier that has nobody to ask and refuses the machine on every tick. A pin that appears or changes is a different dial, so the loop already running under the old one is stopped rather than left refusing a machine the user has already stood in front of and trusted.

## Agents

### The panel at the top of Home says what the agents are doing

Header `AGENTS`, a count, `VIEW ALL >`. Column labels `AGENT`, `STATUS`, `WORK`. One row per working or blocked agent, most recently changed first, at most three: a 24px bordered mono glyph box, the agent's name, a 6px status dot with the status word — accent for working, warning for blocked, `--fg-dim` for idle — and the pane's stripped terminal title as the work, on one line, ellipsised. A footer line reads `N idle · N blocked`, the blocked count in warning when it is not zero. When nothing is working or blocked the rows collapse to that footer alone.

**The panel never assumes a host.** Until some host has the agent integration switched on, the panel is blocked: one dim line, `NO HOST · SET IN SYS`, no rows, no footer, and not a single connection opened. Every host with it on is polled concurrently, rows merge across hosts, and a host that fails contributes its own dim line while the others still draw rows.

A host that is unreachable, has no key installed, or answers a protocol the app does not speak shows one dim line with the reason — `nyx unreachable`, `key rejected`, `protocol N` — and keeps the last good snapshot's age on the right, `12s ago`. It never blocks the rest of Home.

`VIEW ALL` pushes an `AGENTS` route with no nav bar listing every agent, idle included, grouped by host and then by workspace — the host level collapsing when only one host has the integration on — each row adding the pane id and the directory's basename as a subtitle.

### Each agent is drawn as its own mark

A scoped exception to never shipping a third-party mark: one is allowed inside the panel's glyph box, to identify the product behind a pane. Nowhere else in the app, never in the launcher icon, never in the vendor's own colour.

The box keeps its 24px border. Inside it the agent's official mark is reduced to a single colour through the same tint path as the house glyphs and fitted to a 16px square centred in the box. The files are `assets/icons/agent-<kind>.svg`, the kind being the string the server reports, on a 24-unit viewBox, paths only, with no fill colours baked in. Each is traced onto that grid from the vendor's own brand page or from a CC0 path, never pasted with the vendor's viewBox, and the source of every file is listed in `design/production/agent-marks.md`.

**Struck:** a mark drawn for an agent there is no file for. A shape invented for a product is a claim about what that product looks like, and the names arrive off the wire — the night a new agent ships, the row nobody recognises is the one somebody is waiting on. The box carries the agent's own initial instead, in the muted grey that says the app is admitting it does not know this one: mechanical, the same every time, and visibly not a logo.

**Struck:** a question mark for an unplaceable name. It is the same box for every one of them, and a list with two unknown agents on it drew two identical boxes and told the reader nothing.

**Struck:** a colour per agent. It reads well enough on its own and it costs the thing the panel is for — the accent is the one colour here that is asking the user for something, and a row of six hues beside it is six things competing with the only one that means anything. The mark carries the identity and the name is written beside it.

The name itself stays plain text as the server reports it, uppercased.

### The pet is a glyph in the family and is bound to no surface

An agent drawn as a small hard-edged creature — angular ears, two diamond eyes, an open jaw — with a second file that closes the viewer's left eye to a bar of the same width, so the pair is a wink and not a redraw. Both live in the family, in the same stroke language as every other glyph, and neither references any vendor.

It is not the mark for an unplaceable agent: that box carries the agent's own initial, and one creature drawn for every unknown name is the identical-box problem the question mark was struck for. It is not the mascot either, which is pixel art and is Dazzle's identity rather than an agent's.

Nothing on any screen asks for it yet. The wink, when a surface does take it, is one autonomous tick and never a loop.

### A tap on an agent row lands in its pane

A row on the Home panel and a row on the `AGENTS` route open the shell sheet on the host the agent is on, in a tab attached to its pane. The nav moves to SSH under the sheet first: that is the tab the sheet belongs to, the parked bar and the session card are there when the sheet goes down, and Home's poll stops for the visit. The `AGENTS` route stays under the sheet, so leaving the shell returns to the list the agent was picked from.

**The tab is found before it is made.** A shell tab remembers the session and pane it was opened on, and a tap on an agent whose pane a tab of that host already holds activates that tab and opens nothing. Otherwise the app says that another terminal view will be detached and waits for `OPEN HERE`; cancel changes neither route nor tab state. Confirm opens a fresh tab whose pty command attaches that pane under its own session with a takeover flag. **The takeover transfers terminal ownership and never replaces or stops the agent.** The pane id and the session name are checked against the same shapes every other command checks before they are quoted into the line. At nine tabs the tap lands on the host's last active tab.

**The binding is tab state.** The session and pane pair survive reconnects and app restarts: a reconnect reruns the command already consented to, and a process restore reconstructs a plain attach to the recorded pane. A clean detach ends that command and closes the tab, so no tab remains claiming it still owns a pane.

### What the agents are, on the screens that are not HOME

The AGENTS panel answers this and answers it better: a row per agent, the work each one is on, the pane a tap away. What it cannot do is answer it from PROJECTS or from SSH, which are the tabs where the user is standing when they stop and wonder. HOSTS is not one of them: its host panel already carries the agent state with the same reason line and a `RETRY` beside it, and a bar over that panel would say the host is down twice, one line above the other, on a screen that is also carrying the parked shell and the nav bar. The shade answers it too, and answering it from inside the app by pulling the shade down over the app is the app admitting it has nothing on screen. So one line, on the strip above the nav bar that belongs to the app rather than to a tab, over the parked shell and under nothing. A route pushed over the shell carries no strip and should not: an open terminal and an open diff are outside the shell's scaffold, and the reader of one of them is already inside the thing a count would have sent them to.

`1 BLOCKED · 3 WORKING · 2 DONE · 5 IDLE`, in that order, blocked first for the reason the shade puts it first: it is the count about to cost the user something. The states at zero are left out rather than printed as zeroes. At the head of the line is a block in one colour, the colour of the state that most wants the user, and at the tail the word `AGENTS`, so that the line reads as a count of something and not as a sentence the app is saying about itself.

**It counts every state herdr classifies, which is one more than the shade counts.** The shade is answering whether anything is happening, and an agent at rest is not; a bar inside the app is read by somebody already holding the phone and deciding whether to go and look, and `5 IDLE` beside `1 WORKING` is the difference between a busy machine and one nobody is using. Both surfaces count over the hosts that answered this round and neither counts the agents a failure report carried along — that ride-along exists so a host blinking does not empty the panel, and counting it is counting work the app has lost sight of.

**A host that is down leads the line, and the counts follow it rather than being suppressed by it.** The shade drops its tally under a failure because the tally it could draw came off the host that stopped answering. Here the tally is taken over the hosts that did answer, so a machine that is down and a machine that is working are two true things at once and there is room on the line to say both. One failure is named; the rest are a count after it, `NYX UNREACHABLE +2`, because the bar is the place the user finds out that something is wrong and HOSTS is the place they find out which. The named one carries its host whatever the count beside it says: two of the six reason lines a failure can carry write their host into the words and the other four do not, and `KEY REJECTED +1` on a strip that shows one failure and counts the others is a line the reader cannot resolve anywhere else on the screen.

**Blocked outranks a host being down for the one colour.** A machine nobody can reach is the app failing to look. An agent stopped at a question is the user being waited on, and it is being waited on right now.

**The bar is not there when there is nothing to stand it up for.** Height is the scarce thing on this window — a parked shell is already taking a row of it — and a strip that stands up to report that there is nothing to report is the strip the reader stops seeing. Nothing blocked, nothing working, nothing finished and nobody down: no bar. Work that finished while nobody was watching is on the other side of that line, because it is the thing the phone is picked up to find out.

**A tap goes to the panel.** The count is not an answer: a blocked agent is answered in the pane it is blocked in, and the panel is the door to that pane.

**The feed is the panel's feed, which means the bar is only as live as the watcher.** With `[ ALERTS ]` on, the watcher is running and the bar is current on every screen that draws it. With alerts off, the feed runs while HOME is on screen and stops when it is not, so the bar is correctly absent rather than quietly stale — a line that says `3 WORKING` about an hour ago is worse than no line, and the app does not have a second source to keep it honest. Absent is a thing the bar has to do and not a thing that happens to it: a feed whose poll has stopped goes on handing out the last state it held, for as long as the app is open, so a count is never on its own evidence that anything is still counting. The bar asks whether something is dialling before it asks what the number is, and that question and the poll's own gate are one answer kept in one place rather than two readings of the same conditions.

Struck: the bar on HOME. The panel is there, saying all of this and the rows under it, and two answers to one question on one screen is one of them too many.

Struck: the bar on HOSTS. The host panel is there, with the reason line and `RETRY`, and the strip would stack a third row of chrome over a parked shell and the nav bar to repeat it.

Struck: the block at the head held at the size it was drawn. The phone's text scale is a curve that gives a small size most of the rise, so a fixed six pixels shrinks against its own line until it reads as dust on the bar. It is sized off the line's own face.

Struck: a row per host. That is the panel, and the panel is one tap away.

Struck: the same bar on iOS. There is no `ios/` directory in this repository to put it in, and the bar is Flutter widgets rather than a system surface, so the work is the target and not the feature.

### The app reaches a herdr server over its socket, and is told when something changes

herdr is a server and every session of it listens on a unix socket. A request is one line of JSON on that socket and the answer is one line back. The phone opens a channel straight to that socket inside the ssh connection it already holds — `direct-streamlocal@openssh.com`, the forward an ssh client opens for a socket on the far side — so no shell runs and no `herdr` process starts for anything a server can answer. What the app sends travels as JSON values: a pane id, a session name, a directory, a prompt, each one a string the server reads as a string, where a quote is a character rather than a word. The shapes are still checked before they go, because a pane id that is not a pane id is a bug wherever it ends up, but nothing the user ever typed is composed into a line for a shell to read.

A server answers one request per connection and then stops reading, and it resets the connection if the client half-closes, so a request opens a channel of its own and destroys it once the answer is in. That is the cheap side of the trade it replaces: a channel is a window and two packets, where a command was a shell, a `herdr` process, and this same socket opened from the far end.

Nothing is added to the host for this. The key the app installs is a plain `authorized_keys` line with no forced command and no `restrict` on it, and a line like that already opens channels — the terminal and the VNC stream ride ones of their own. A key that was narrowed by hand would have to allow forwarding, which is the same thing that line already has to allow for the shell to work at all.

**The list is an answer to an event, not to a clock.** A held channel per running session subscribes to panes and workspaces appearing, closing and exiting; a held channel per agent pane subscribes to that pane's own status changes, which is a subscription that must name a pane — the session-wide set carries a pane coming and going and never the moment an agent stops at a question, which is the moment the whole panel exists for. An event is a signal that something moved and never the new state: what it does is start a quarter second of quiet, after which one `agent.list` per session runs and the panel is drawn from the answer. A quarter second is there because one user action moves several panes, and a burst of events is one list rather than six. A machine where nothing is happening costs nothing at all, which is what a phone holding an idle connection over a mobile radio should cost.

**The roster is the one thing still asked for on a clock.** No socket method lists sessions, and the socket path of a session is what that listing carries, so the app has to have it before it can reach a server at all. `herdr session list --json` stays a command and runs every thirty seconds: a session starting or stopping is rare, nothing subscribes to it, and thirty seconds is the delay before a session that appeared has its panes watched.

**A session is a socket, not an environment variable.** Which session a pane lives in decides which socket the request is dialled on, so it never travels inside the request and a pane of one session can never be read on another's server. The pairing of a session and a pane is still what identifies an agent everywhere above this — two sessions on one host can both own a `w1:p1` — and it still travels with the snapshot across the watcher's isolate, into a notification's payload, onto the shell tab an attach opens.

**A session that stopped is not a host that went away.** A channel to a socket nobody is listening on is refused by the far end and that session is skipped for this round; every other failure to open one is the connection itself, and the panel says the host is unreachable rather than saying the host has no agents. The two are different errors on the wire and the app reads them apart, because an empty panel is the one wrong answer here: it looks exactly like a machine with nothing running on it.

**What is still a command is what no server can answer.** The attach is a TUI that owns a pty until the user detaches. A directory is resolved and tested by a shell before a workspace is created in it, because `~` is the shell's and a `workspace.create` given a directory that is not there says nothing about it. Model discovery reads files. Checkout discovery walks a tree. An image is uploaded on stdin. Each of these is a quoted script under `sh -c`, with every value that came from the user or the host quoted into it, exactly as before.

**A tab that came up over mosh keeps its commands.** Mosh carries a terminal and cannot forward a unix socket, so the pane listing a shell tab does for its own header goes on asking a shell. The AGENTS surface does not: it runs on the app's own ssh connection to the host and never on a tab's transport.

Struck: a runtime of the app's own, injected on the host and written in a native language, to make this faster and safer. The daemon it describes is herdr, which is already there and already speaks a protocol; the cost the phone was paying was a process per poll on the host and a wakeup per poll on the radio, and neither is a thing a second daemon removes. It would also be the app installing a binary on a machine whose owner installed a key for it, which is a larger permission than anything else in this document asks for, and every byte it parsed would be one more thing between the user's agents and the screen.

Narrowed to exactly what it rejected, and no further. What stays struck is the daemon and the injection: a host binary that is resident, that listens, that the app puts on a machine of its own accord, or that stands between these panes and this screen. A host binary does exist for plugins, and it is none of those things — it runs when it is called and is gone when it has answered, the user declares and installs it themselves, and nothing on this surface is served by it. The agent panel still reads its events off held channels and still asks for the roster on a thirty-second clock, because a process on the host was never what either of those was waiting on.

### A started agent is handed its prompt once it is ready for it, not once it is launched

Starting an agent and giving it the text are two requests, and the server answers the first as soon as the process is on the pane rather than when the agent is up. A pane with a process in it is not yet a named agent, and the prompt that follows a millisecond later is refused for exactly that — a send that had already made a workspace and started an agent, closing both and telling the user the spawn failed, every time, on a machine where nothing was wrong.

So the send waits between them, and the wait is the server's own: after a start that was accepted it asks the server to hold until the pane comes to rest, and prompts when that answer lands. A wait that expires is an agent taking longer than the window rather than a verdict, and the prompt goes anyway.

**A prompt refused because the agent is not ready is a moment, not an answer.** It is retried on the same terms as one the agent never read, inside the deadline the whole send is already under, and before each retry the pane is looked at: a trust dialog is answered the way the start's own refusal used to be answered, and anything else is waited out. What is never done is reporting the text as refused because the far side was still opening.

### The ongoing notification says what the agents are, not what the watcher is

The watcher has always posted a notification of its own: silent, at the bottom of the shade, there for as long as `[ ALERTS ]` is on, because Android will not hold a service's connections open without one. It said `WATCHING 2 HOSTS`. That is a line about the app. The phone comes out of a pocket to answer a different question — whether anything is waiting on the user — and the one surface the app has on screen without being opened was the one surface that did not answer it.

So the line is the tally. `1 BLOCKED · 3 WORKING`, across every host at once, blocked first because that is the count about to cost the user something. The states counted are the states that earn a row on the AGENTS panel and no others: one rule for both surfaces, and an agent at rest is the night going the way it was supposed to rather than news. With nothing active the host count has the line back, being the only thing left to say. A host that is down takes it ahead of either — a watcher that cannot reach a host is not a watcher reporting that the host is quiet, and the tally it could still draw is the last one it was told rather than the one that is true.

**A report that does not move the line does not repost it.** herdr sends a report whenever it has anything to say, and most of what it says is a terminal title three panes down; the tally over that is the same tally. The line the shade is currently showing is kept and compared, and the service posts only when they differ.

**The shape this idea takes on the other phone is out of reach, and saying which shape keeps it from reading as an oversight.** The same idea — a phone that says what the agents are doing without being opened — lands on iOS as a lock-screen Live Activity and the Dynamic Island above it. Neither is a status bar and neither is Android: the lock-screen card is ActivityKit, and this repository has no iOS target to build one in. The shade's ongoing notification is the surface of that shape that exists here, it was already being posted every time a report landed, and what it cost to make it say the right thing was the text.

**Its transport is the one the watcher already does better.** There, an agent POSTs to a hosted endpoint whose URL is itself the credential, and a vendor's push wakes the phone. Here the watcher holds herdr's own `agent watch` open per host over ssh, on a key the phone generated and a host fingerprint it pinned: the same liveness, with no third machine in the path, no bearer token left in a shell history, and a state that is herdr's reading of the pane rather than whatever each agent remembered to report about itself. What the push buys and this does not is a phone whose app is gone — the ongoing line is live only while the service is, which is the trade `[ ALERTS ]` already names on the row that turns it on.

Struck: a lock-screen card and a Dynamic Island. They are the same tally on a platform this does not build for, and the day it does they are a rendering of a line that already exists rather than a feature to be designed then.

Struck: an endpoint agents ping, and the pairing code and hosted key that go with it. It would be a second way for an agent to say what herdr is already asked, reachable by anyone holding a URL, and it would put a machine the user does not own between the phone and their own panes.

Struck: naming the agent in the tally. A blocked agent already raises the alert that names it and offers the answer; the ongoing line is the count, it is read at a glance from a lock screen, and a line that changes width every time an agent starts is a line that has to be read twice.

Struck: a `DONE` that lingers on the line for a while after the work ends, the way the surveyed client holds one for a minute and a half. `done` here is not an event: it is where an agent rests once the tab it finished in went unwatched, which from a phone is every tab. Counting it would mean counting the whole night.

### The app parks in a corner while there is something to watch

A phone that is watching agents is a phone the user is holding for something else. They go to the browser, to the terminal on the other side of the app switcher, to a message — and the panel they were reading is gone, replaced by a shade line that is one row of text and only there because a service is running. Android's own answer to a window that has to survive leaving the app is picture-in-picture, and what it parks in the corner is this activity's own surface. There is no second renderer, nothing to mirror and nothing to keep in step: the app is told the mode changed, and it draws something else.

**It has its own action in AGENTS.** The app does not turn leaving for another app into a picture-in-picture request. `PIP` sits beside `VIEW ALL` on the Home panel and at the head of the AGENTS route, with a glyph of a window and a tile in its corner so the word is not the only thing telling it apart from the navigation next to it. While the feed is live and an agent is working or blocked it is lit and opens the window directly. While there is a host and nothing to watch — every agent idle, or nothing dialling — it is drawn dim, in the disabled grey `[ ALERTS ]` uses for a toggle with no host, and does nothing, the way that toggle does nothing: an action that only exists in the minute it is useful is an action nobody learns, and the dim word is what says the window is there to be had once something is running. It is absent only where there is no window to open at all: a device without picture-in-picture, or a panel with no host.

**The window is the app still on screen, and the feed keeps counting for it.** Opening the window pauses the activity, and a gate that read any pause as the user leaving would close on the act of parking: the window would say `NOT WATCHING` before it had finished appearing, over a count it had stopped keeping. The Home poll's gate asks whether the app is on the screen — in front, or parked in the corner of something else — and not whether it is the app in front. Behind another app, or swiped away, the activity stops and the gate closes as before. The strip over the nav bar and the fresh drops keep the stricter reading, because for them the corner window is not the user coming back.

**What it counts is the hosts that answered.** A failure report carries the last agents its host was seen with, so that a host blinking does not empty the panel. An action enabled from those stale rows would offer a window over work the app has lost sight of, on a machine that may be off. The action asks which agents the app can currently see and not whether anything failed. A second host still answering with work on it keeps the action available while the first is down, and the window headline says the outage, which is the line the shade is showing anyway.

**And only while something is still counting them.** A feed whose poll has stopped does not forget: it goes on handing out the last state it held for as long as the app is open, so a tally is never on its own evidence that anything is being watched. The action asks whether anything is dialling before it asks what the count is, using the same live signal as the strip over the nav bar. With no live feed, the action is dim instead of opening a tile on a frozen count.

**It says what the shade says.** The headline is the ongoing notification's own line, from the same function: the count of what is blocked and what is working, or the failing host's reason when a host is down, or the host count when the night is quiet. Under it are the active agents, blocked first, each with the machine it is on, and a count of the ones that did not fit. Three surfaces drawing one answer, because a second way of phrasing it is a second thing to keep true.

**Nothing on the window is tappable.** A tap anywhere on a picture-in-picture window is the system's gesture for opening the app back up, and a target of the app's own underneath it takes that gesture away from the user. The window is read; the answer is given in the app, or on the alert that already carries it.

**Its type is not the app's type, because it is not being read from the hand.** Every size in this app was drawn against a 360dp screen at reading distance, where the hierarchy is carried by colour and by which column a thing sits in and the sizes can stay within a step of each other. None of that survives out here: the window is a couple of hundred points the system placed and may be shrinking further, it is at the edge of whatever the user actually went to, and it has no columns. Size is the only channel left, and what was drawn first stepped from a twenty-point display headline straight onto ten-point rows — a banner over fine print with nothing between them, which is most of why the window read as unfinished. It gets its own scale instead: three sizes a fifth apart, nine, eleven and thirteen, all of them mono, because the display face is condensed and condensed letterforms this small on a surface the compositor is downscaling lose the strokes that tell them apart. The muted grey goes with them. It is a four-to-one grey chosen for a screen held in the hand, and this is the one surface in the app read from across a room.

**Each agent is drawn as itself, and the one the app cannot place is drawn as its own initial.** A row that opens with the word `CLAUDE` is a row that has to be read before the reader knows whose it is, and the window exists to be answered at a glance. The mark is the one the panel already draws — the same file, the same single colour, the same bordered box — asked for at the size of the window's own line instead of the panel's twenty-four, which beside an eleven point name reads as a tile with a name after it rather than as a mark on a row. Where the bundle has no file the box carries the agent's first letter, in the muted grey that says the app is admitting it does not know this one. That replaces the question mark everywhere the box is drawn, panel included: a question mark is the same box for every unplaceable name, and a list with `aider` and `gemini` on it drew two of them side by side and told the reader nothing.

**When nothing is dialling it says so, and keeps the count under it labelled as the last thing heard.** The strip over the nav bar answers this by being absent and this window cannot: there is no call on this side that closes a picture-in-picture window, so once it is up it is up until the user comes back for it. If the watcher stops after the window opens, the headline goes to `NOT WATCHING`, the rows come off, and the tally moves underneath as `LAST SEEN`, which is the only phrasing here that is neither a lie nor an empty tile.

**It is one sentence to a reader, and it stops growing before the window does.** Read off the drawing it is half a dozen nodes of shouted fragments and a separator that comes out as `middle dot`, so it carries one label instead, built from the rows rather than from the text on them: it names every agent the app can see, the ones there was no height to draw included. The reader's text size is honoured and then held at a third over, because the window does not grow with it — the system owns that size and there is nothing here that can ask for more room. Past the clamp the type stops rising and rows come off instead, counted on the line under them the way anything past three already is, since a row taken off by the bottom edge is a row the reader does not know they are missing. How many fit is measured against the height the window was actually given, which is also the answer when the user drags it larger.

Struck: a mark drawn for an agent the app has no file for. A shape invented for `aider` is a claim about what `aider` looks like, and the names arrive off the wire — the night a new agent ships, the row nobody recognises is the one somebody is waiting on. The initial is the honest stand-in: it is mechanical, it is the same every time, and it is visibly not a logo.

Struck: a colour per agent. It reads well enough on its own and it costs the thing the window is for — the accent is the one colour here that is asking the user for something, and a row of six hues beside it is six things competing with the only one that means anything. The mark already carries the identity, and the name is written beside it wherever one is drawn.

Struck: how long each agent has been where it is, which is the thing a reader most wants off a window like this. There is nothing to draw it from: what comes over the wire is a sequence number that moves when a pane's state changes and not the moment it changed, and a clock started when the phone first saw the pane would be measuring the app's own attention rather than the agent's work. It waits on the field, not on the window.

Struck: a floating overlay drawn over other apps. It is the workaround for a platform with no such window, it costs a permission the user has to grant on a settings screen the app cannot open for them, and the system's window is better in every way that matters — it is placed and moved by the system, it survives the app switcher, and it asks for nothing.

Struck: actions in the window, which the system will host beside it. The answer to a blocked agent is `YES`, `NO` or a sentence, and the first two are already on the alert with the agent named; the third was never going to be typed into a tile.

Struck: the same window on iOS, where the system reserves it for video. There is no target here to build one in, and the question does not arise until there is.

### A notification platform is a sender's product and this app is both ends of the wire

BuzzKit, "the open source notification orchestration layer", AGPLv3, run hosted at its own site or, on a Cloudflare account and a guide its own page says is coming, self-hosted on the same code, was read against `[ ALERTS ]` because a feature list written by people who do only this is worth reading before deciding what is missing here. It is a backend and only a backend: there is no client of theirs to hold this app's surfaces against, and the reading below is of a feature list rather than of a screen. What it sells is the machinery between an event and a phone: subscriber and device management, segments by attribute and by event, workflows whose steps wait, wait for an event, branch, repeat and walk a list, sources that take other people's webhooks in, scheduling with subscriber-timezone sends and quiet hours and daily caps, topics and preferences applied to every send, automatic retries for temporary failures, delivery and open receipts per device, and a dashboard that says of each push whether it was sent, delivered or opened and why it failed, over a workspace that holds a tenant per customer, each with its own subscribers, topics and credentials. iOS push is what ships; Android over FCM, email, SMS, web push and in-app are named as connectors on the same core, and experiments on messages and on workflow steps are named after those. Its Swift SDK identifies a subscriber, registers for push, routes deep links and notification actions, draws a preferences view the app can drop in, holds the token lifecycle of a Live Activity across start, update and end, push-to-start included, and writes its events to disk before the network sees them so a phone with no route loses none.

**Almost none of it is a gap here, because the two things are not the same shape.** Every feature on that list answers a question this app does not have: a sender who does not own the device. Subscribers, segments, device tokens, provider keys, receipts and a dashboard all exist to say which phones and whether it arrived, and there is one phone, it belongs to the user, and it is the thing posting the notification. The app is not a sender. The watcher reads herdr over ssh on a key the phone generated and posts to its own shade: nothing leaves the device, there is no token to keep, no provider to fail, and no second machine to ask afterwards what happened. An audit that carried the list across would be building a delivery network to reach the notification bar of the process already drawing it.

**Preferences per kind are the piece of its model this will want, and not yet.** There is one row, `BLOCKED AGENTS`, on or off, and it governs the only alert there is, so the row is honest today. It stops being honest the moment there is a second kind: the day a routine that failed overnight or a host that went down earns a notification of its own, a user who wants one and not the other has only the switch that stops the watcher. What is worth copying is the small half of what BuzzKit does here — a choice per kind, with defaults the user can override — and not the channel half, there being one channel and it being the shade.

**Quiet hours are the one entry on its list this app has a live reason for and does not have.** The alert is posted at high importance with the channel's sound and its vibration, and it fires the moment a pane blocks, which for the phone this was built for is mostly at night — the reason to leave agents running is that the night passes without anybody sitting over them. BuzzKit files quiet hours and a daily cap under scheduling because a sender who wakes people at three in the morning stops being allowed to send. Here the same fact is sharper rather than softer, because what the alert reports is a machine waiting on one keystroke, and it will still be waiting at eight. Not built, waiting for the user's word: it is a change to how loud an alert they asked to be loud is, and that is theirs to ask for.

**Retries and receipts are already answered here, in the direction that applies.** A hosted sender retries because a push gateway refused it and wants a receipt because it cannot see the device. The watcher's temporary failure is the connection, and it already backs off from five seconds doubling to sixty and puts that on the line the shade is showing rather than keeping it. The answer an alert sends has the same shape one level down: the actions are replaced by `SENT · YES` until the watcher sees the pane leave `blocked`, a failed send puts `FAILED · <reason>` up with the actions back, and ten seconds without a change brings them back anyway. Posting is the delivery. There is no receipt to go looking for and nowhere to go looking.

**Its SDK writes an event down before trying to send it, and what does not carry across is the direction the news travels.** Its phone is where the event happens — a workout finished, a plan upgraded — so a phone with no route is holding the only copy of something, and a queue on disk is the difference between reporting it late and never. Here the event happens on the machine. A pane blocks on the far side of the tunnel and the phone finds out by being told; a phone with no route is not holding anything back, it is not being told, and there is no queue to keep because nothing was generated on this side to put in one. What the shape does owe the reader is to stop showing the last thing it heard as though it were still true, and it does: the outage takes the line, with the reason and the countdown on it, and the tally goes down with it rather than sitting in the shade looking live. The one queue this app could want runs the other way, and it is already refused one level down — an answer tapped while the route is gone comes back as a failure with the actions returned, not as a keystroke held for a pane that will have moved on by the time it lands.

**One thing it builds is the shape this app already has, and it is the one that stops using the network at the moment it matters.** A local notification there is a plan rather than a message: a silent push carries an id, the wall clock moment to fire, the words and the event names that cancel it, the device schedules the trigger itself and fires it "at the right wall clock moment with no network involved", and the plan is dropped the moment the app tracks a cancelling event, "offline included". The server is the fallback and it keys off a missing acknowledgement rather than a failure. Take the push off the front of that and what is left is what the watcher is: the decision on the phone, the firing on the phone, nothing in between to be down. It is worth writing down not as something to take but as the measure of the rest of the list — every other way that platform reaches a phone goes through a machine, and the one design they wrote that does not is the one where they had to give the phone the plan and get out of the way.

**Its workflow engine has one timer this app was measured against and should not have, and the reason is what an edge means here.** `waitFor` with `settleFor` and `resetOn` waits for quiet instead of for an event: the event starts a clock, any event on the reset list restarts it, and the step runs only once the clock has run out untouched. It is the right machine for a stream whose items are not worth a message one at a time — an app backgrounded, opened, backgrounded again — and the wrong one for this. A pane that entered `blocked` is a machine that stopped and asked a question; a pane that blocked, was answered and blocked again has asked a second one, and smoothing the two together is the app deciding for the user that the second question can wait. The set difference per host is the edge, and it is already what is written down. What a settling clock would defend against is a pane that chatters without anybody asking anything, which nothing has been seen to do — and if one ever is, the answer is at the sample rather than in a timer averaging it away.

**Its dedupe is the same guarantee one level down, which is where this one already lives.** Every event it takes carries an optional id unique per subscriber, a replay comes back as a duplicate and stores nothing, and a send takes an idempotency key. That is a protocol defending a sender against its own retries. Here the same property is a consequence of the shape rather than a field on the wire: the alert fires on the edge into the blocked set and not on the state, so a report that says what the last one said posts nothing, and the id a repeat would collide with is derived from the host and the pane precisely so that it updates in place instead of stacking.

**Of its workflow engine one shape is worth having and it is the escalation.** Waits, conditions and follow-ups are a general machine for a problem this app has exactly one instance of: a blocked agent that nobody answered. The alert fires once per episode by design, which is right — repeating it would be the app nagging about a pane the user has decided to leave — and it means a question asked at two and ignored looks identical at six to one that was never asked. A follow-up at a long interval, or a count of unanswered episodes on the ongoing line, would say the difference. Ranked first of what is merely unbuilt, and still unbuilt: it is a new notification, and the section that ruled the alert already keeps a typed reply and a watcher that comes back after a reboot on the list of things waiting on the user's word rather than on a survey.

**Live Activities are where it goes that this cannot follow, and for the reason already written down.** Its SDK monitors an activity's token across start, update and end and can have the system start one from a push. That is the same idea the ongoing line is — a phone that says what is happening without being opened — rendered on a surface ActivityKit owns, and this repository has no iOS target to build one in. Ranked first of what is platform-blocked, which is a different list from the one above: the rest of that list is Android work nobody has done, and this is not work at all until there is an `ios/` directory to do it in.

**What the iOS half would be, written down so the blocker reads as a precondition rather than as an excuse.** Two things have to exist before a line of it can be written, and only one of them is the repository's to fix: an `ios/` target beside `android/` and `linux/`, and a machine that can build it. After that it is a widget extension beside the Runner, sharing an app group so the process that holds the tunnel can hand it a line, drawing the same sentence the shade and the corner window draw, from the same function that writes both, with the blocked agents under it in the order they are already given. What arms it is the gate the window already has: an agent working or blocked on a host that answered.

**None of that is the hard part, because the watcher underneath it does not cross.** The line on Android is written by a service that holds the tunnel open with the app closed, and there is no counterpart: a backgrounded app loses the socket in seconds, and no background mode hands back a connection that lives for hours. An activity started on the way out would sit in the corner showing the last thing it was told, for as long as the user left it there, which is the exact failure the ongoing line exists to avoid — a surface reporting a state that stopped being true the moment the app went away. Both ways out of that are already ruled on here. Having a server push the updates puts a provider key and somebody else's machine between the phone and the user's own panes, which is the trade `[ ALERTS ]` refuses and the reason the tally is read over ssh in the first place. What is left is an activity honest about its own age: the line, and under it how long ago the phone last heard anything, going stale in the open instead of pretending. That is the decision the iOS half turns on, and it is worth having settled before the target exists, because it is also the decision about whether the target is worth adding.

Struck: sources, outbound webhooks, imports off a competitor, subscriber merge and aliasing, signed identity, and a dry run against a versioned workflow. They are the back office of a product that has customers: a way in for other people's events, a way out to other people's servers, a way off somebody else's platform, and a rehearsal before a send reaches a stranger. The events here arrive on one connection the user opened, the send is a line in their own shade, and the rehearsal is that they can read the code.

Struck: asking for the notification permission quietly and earning the real one later. It is an iOS affordance with no counterpart in the permission this actually asks for, and a refusal is already treated as an answer rather than as something to work around: the row goes back off and says the system refused it.

Struck: tenants. A workspace with a tenant per customer, each isolated behind one key, is the shape of a business that sends on behalf of other businesses. Here the workspace, the subscriber and the credential are one person, and the boundary has nothing on the far side of it to keep out.

Struck: subscribers, segments, device management and a dashboard over them. They are the sender's half of a product where the sender and the receiver are the same process, and every one of them would be a table with one row in it.

Struck: a provider key and a push service in the path. It is the same trade the ongoing line already refused for the same reason — it puts a machine the user does not own between the phone and their own panes, and it buys a phone whose app is gone, which is the trade the `[ ALERTS ]` row already names.

Struck: the other channels. Email and SMS are how a product reaches a customer who is not looking at it; the user of this one is holding the phone the agents are being watched from, and a message about a blocked pane that arrives anywhere other than the shade of the app that can answer it has made the answer harder to give.

Struck: experiments on messages. There is one reader, they know what the words mean, and the sample size is one.

Struck: taking its SDK. It is Swift, for a target that does not exist here, and what it wraps is the registration and token handling of a push transport this does not use.

### A watcher does not knock again on a credential the host has settled

The reconnect schedule is one backoff per host: five seconds after an outage, doubling to a minute, back to five the moment a connection carries a snapshot. It was applied to every way a dial can fail, without distinction. A key the host rejected got the same timer as a route that was not there.

**The line is drawn at the credential, and it is drawn because the knocking is not free.** The daemon on the far side counts failed authentications per source address, and under its own shipped defaults it answers everything from that address for the next hour before a key is looked at, for a day if the client keeps knocking. A watcher on a minute's timer is a client that keeps knocking. What it loses is not the watch: the shell and the screen dial the same daemon from the same phone, so a background loop nobody is looking at can lock the user out of the machine they were about to open a terminal on, and go on holding the lock open by retrying into it.

**The app's own two refusals sit on the same side of that line for a plainer reason.** A host key that was never pinned and a host key that changed are both answered by a person standing in front of a fingerprint on HOSTS. A loop cannot be the one to answer them, so a loop that retries them is asking a question with nobody in the room, every minute, for as long as the phone is on.

**Everything else costs the host nothing to be asked twice and can answer differently without anybody touching the phone.** A route that is not there comes back, a name starts resolving, a herdr too old to be understood is upgraded on the far side. Those keep the schedule they have.

**A line nobody is coming back from carries no countdown.** The shade reads `KEY REJECTED`, not `KEY REJECTED · RETRY 60S`. A countdown under a refusal the app has decided not to retry is the app promising a knock it is not going to make, and the reason on its own is the whole of what is true about that host.

**What starts the loop again is the user, and that is the right trigger.** The watcher rebuilds a host's loop when the row changes under it — a different address, user or key, a pin that appeared or changed — and when `[ ALERTS ]` goes off and on. Every one of those is the same act that could have fixed the credential, which is the only thing that makes another dial worth making.

Struck: a longer timer for a refused key, an hour or a day instead of a minute. It is the same knock with a longer fuse, and the penalty it lands in is measured from the last attempt, so a loop on a slow timer keeps the lockout alive rather than letting it expire.

Struck: a notification asking the user to go and fix the key. The ongoing line already names the host and says what it refused, HOSTS is where a credential is answered, and a second alert about a machine that is not going anywhere is a phone buzzing about the state it was in a minute ago.

## Shell

### A host's shell is the app's own terminal, and several at once

Every registered host offers it: ssh is what a host already is, so there is no integration toggle for it. The session is `shell` on the ssh channel with a pty of type `xterm-256color` at the view's columns and rows, and nothing else — no command, no `exec`, no environment beyond what the pty implies, no rc injection, no multiplexer attach, no wrapper. What sshd starts for the user is what runs.

The terminal is a vendored `xterm`, one `Terminal` per session, on a black ground in the mono face, the cursor a block in the accent, the foreground text primary, and the ANSI palette taken from the tokens for black, white and green with standard hues for the rest. Bytes in are the channel's stdout and stderr, bytes out are the terminal's, a resize sends a window change, and the scrollback is ten thousand lines.

Sessions outlive the route. A store per host keeps every session, its connection, its buffer and its state, so leaving the shell and coming back finds the tabs where they were, still running. A session ends by `×`, by the remote shell exiting, or with the process.

### The shell is a sheet over the screen it was opened from

It is presented as a modal sheet over the surface that opened it — the SSH tab, a host panel, a session card, a workspace, an agent row — and not as a page in front of it. The screen beneath stays in the tree under a `0x99000000` wash, lighter than a panel sheet's, so the tab still reads as the tab.

**The sheet stands flush under the status bar**, its foot at the screen's, so the terminal keeps every row a full page had. In place of a band or a shoulder, one rule on the sheet's own top edge — 36 × 2 px, centred, `textDisabled`, 5 px under the edge, drawn over the header's ground, with the hairline `borderNormal` along the edge itself. That rule is the only thing that says sheet, and it says it inside the row the header already holds, so it costs no rows either. It takes no touches: the header under it is what the finger grabs.

**A vertical drag that starts on the header row, or on the reason row under it, moves the sheet with the finger one to one**, the wash thinning with it, terminal and key bar and keyboard going along. Released past a third of the way down, or flung downward faster than 700 px/s, the sheet finishes its way down and the route pops; released short of that, or flung upward, it comes back. Under the finger the motion is linear; from a release it goes down from where the finger left it. The header's cells still take their taps. The terminal keeps its one-finger drag as the scroll and the key bar keeps its horizontal one; neither moves the sheet. Back still leaves, and the last tab closing still pops, both down the same slide.

Leaving by the drag is leaving by back: the session lives on, the tabs are where they were on the next open, and the cards on SSH are the way in again. Landscape is allowed.

**Struck:** X's parked state as a resting height for the sheet itself — one row at the bottom with the page behind it whole. One resting height. **Struck:** the sheet as an inset card held clear of the screen's edges on three sides. Columns cost more than the top ever did. **Struck:** a tap above the sheet to leave. What is left up there is the status bar strip, and the system takes that tap before the app sees it.

### The shell parks as a bar over the nav, and one tap is back in

One row, 36 px, over the nav bar and under all four tabs, drawn whenever any host has a session. Ground `surfacePrimary`, a hairline `borderNormal` along its top, capped to the content column as the nav bar is. Left to right: the session's state dot, `<HOST> <n>`, `+N` in the muted weight where N is every other tab on every other host, the shell's own title in `rowKicker` when it has named itself, and `TAP TO RESUME` in the accent at the right edge. The whole bar is the target, not the words.

The session it names is the tab last opened or brought forward, on the host it is on. Closing the named tab falls to whatever its host is on now, closing a host's last tab falls to another host that still has one, and the bar goes with the last session anywhere. A restored run parks on the tab that was on screen when the process died.

**The bar stands under the sheet rather than appearing when the sheet leaves.** Nothing animates it in or out: it is there before the drag starts and is already drawn where the sheet lands the instant the sheet is gone. A row sliding in under the nav while a sheet is going down is two things moving in the same 180 ms.

The cost is one row on the tabs, and only while a shell is running. The terminal refuses 24 px at the top because rows are what a terminal is; this spends 36 px on screens that scroll.

**Struck:** a drag up from the bar that raises the sheet under the finger. The route does not exist until the push, so the gesture would drive a controller it made mid-drag, and on a row this size the tap is already the whole target. **Struck:** a close cell beside the verb. Killing a shell belongs to the header row inside it, not to a 36 px bar the thumb passes over on its way to the nav. **Struck:** the bar showing through mid-drag as the place the shell is going — the sheet slides as a whole and its foot goes down with its head, so the screen's bottom row is sheet until the sheet has left.

### The header's host name opens a switcher over every host

The host name at the head of the header is a cell whenever there is somewhere to go — while a second host exists at all — marked with the `expand` glyph at `affordance` size in `textDisabled`, and a plain label otherwise, because a switcher over one host leads back to itself.

A tap opens a `SHELLS` panel sheet. At the top, every session on every open host, host by host, each row `<HOST> <n>` with the shell's title under it and its state dot at the left; the row the sheet is showing carries `ON SCREEN`. Under a rule, the header `TAKE OVER` and one row per host with no shell at all, in the host list's order, each `<HOST>` over `ssh, <user>` — the shape a host row has everywhere else — and no state dot, because there is no session to have a state. A host is on one list or the other: a host with a shell is never offered below, and a host whose last tab closed goes back down.

Picking a row on the host in front is a tab switch. Picking a row on another host hands the sheet that host: the sheet keeps its route and rebuilds under the new host's key, which runs the arriving host through the same path a fresh open takes. Picking a host under `TAKE OVER` opens its first shell the way a first visit does, prompt and all, and the unknown-key sheet names the host being dialled rather than the one left behind. **One route means one way out** — the drag that was there before the switch is the drag that is there after it, and it goes to the tab underneath.

**Struck:** a second row of host chips over the tab row. The tab row is already the widest thing in a 36 px header and the second host is the exception, not the rule.

### A tab says which shell it is and how it is doing

The header is one row of 44: the host name at the left, then the tab cells and a `+` inline, the active one underlined in the accent, then the mark that holds the state, then `×` at the right. The `+` opens a new session and makes it active, and is gone at nine. `×` closes the active session behind a `CLOSE SHELL <n>?` sheet while it is live, and at once when it has exited or failed. Numbers are not reused within a visit.

**A tab is named by the shell in it.** It takes the title its shell set, shortened for the room a tab has: the `user@host:` a login shell puts in front is dropped, a remainder that is one path is cut to its last segment, and what is left is drawn in the shell's own case and cut off by the width of the cell. A shell that has not named itself keeps its number. The number is still what the app calls it — the card, the switcher and the parked bar all read `NYX 2`, and a tab's key is its number.

**A tab carries its state**, the same dot the cards carry, in front of the word: a tab that dropped, gave up or exited is seen without being visited. It is the one thing on a tab that changes with nobody touching it.

**The tab in use is on the screen.** The strip scrolls, and a tab going active — by a tap, by being opened, or by the one beside it closing — is brought into view. A strip that scrolled the shell the user is typing in off its own edge is how a tab is lost.

### SSH is the tab for what is running

`ACTIVE SESSIONS` on top, one card per session across every host, in host order then tab order, drawn only while something is open: an empty shelf is worse than the list starting at the top. Under it the host list, each row `ssh, <user>` and never the address, counting its own sessions.

A card is a live miniature of its session's terminal on black, hairline bordered, repainted as output arrives but not more than twice a second, with the state dot in its top trailing corner and `<HOST> <n>` captioned under it over the shell's title. A tap opens that session.

**The card draws the bottom of the buffer, not all of it.** A whole viewport squeezed into a card puts every glyph at three points wide: a grey texture that says a shell printed something and nothing about what. The miniature draws its lines at a fixed readable size and keeps the last ones that fit, so what a card shows is the newest output and the prompt under it; the rest falls off the top, which is where a terminal keeps what has already been read. The blank rows after the last written line are dropped before the tail is taken, because a shell's viewport is mostly empty and a card anchored on its last row is a card of nothing — a blank line between two written ones is output and is kept. A line wider than the card is clipped by its edge, the way the terminal itself clips, because the size of the text is what makes it readable and nothing is scaled to fit a full line.

### A shell that exits clean takes its tab, and one that does not says why

**Exit 0 closes the tab.** The user typed `exit`, the tab holds nothing they asked to keep, and it goes the moment the code arrives — from the store, so it goes whether or not anybody is on the route. The last tab going takes the route with it, the same pop closing the last one by hand does, and that pop has one owner: the store's listener, which every way of losing the last tab passes through.

**Every other code is a sheet.** `SHELL <n> EXITED <code>`, one at a time, over the terminal the shell died in, with `CLOSE` and `KEEP` — `KEEP` filled, because the output under the sheet is the only place the shell wrote what went wrong. A connection that went away without a code reads `EXITED —`, the word the header already uses. A tab is announced once: the sheet is the moment it ended, and the header goes on saying it afterwards.

### The tabs survive a restart, because what is written down is the tab

An ssh channel dies with the process that held it; nothing on the phone can keep one warm across a launch, and a session that claimed to be the same shell would be lying about the state on the remote. What survives is the row: host, number, the remote identity it was on, and whether it was the tab on screen. A multiplexer on the far side is what makes the shell itself survive, and that is the remote's job.

**Startup dials them back.** The rows are read before the first frame and a tab is opened per row, on the host it was on and under the number it had, so the numbering carries on where it stopped rather than restarting at 1. The dials are not awaited — the boot log is on screen while they run — and the log carries `restore shells <n>`, since it reports real work. Each dial is unattended, so a host whose key was never pinned is refused here as it is on a reconnect, and a row whose host was deleted while the app was down is dropped rather than dialled.

The table follows the tab row: opening writes one and makes it active, closing takes it out, switching moves the flag, and a shell that exits clean takes its row with its tab. A tab left on a failed shell keeps its row — it is dialled again next launch, which is the thing the tabs were wanted back for.

### A new shell does not inherit the modes of the one that died

The session outliving its connection is the design, and the terminal goes with it: a tab keeps its buffer, its selection and its place in the scrollback across a network drop, so the shell that comes back writes under the output of the one that died instead of into a blank screen. That means the terminal object is the same one, and so is everything it holds — including the modes a program asked it for, and the program that turned them on is gone.

**One bit left set reads as a terminal that has died under the finger.** While the terminal still believes an application wants mouse input, a drag is forwarded to the shell as a wheel report and the buffer stays where it is, and a tap is answered by the terminal rather than by whatever it landed on. The shell that came back asked for none of it and ignores all of it, so nothing scrolls, nothing under the thumb answers, and the screen says nothing about why.

**A new shell is given a terminal in the state a new terminal is in.** Above the reconnect mark, mouse reporting is turned off in each of the modes an application can ask for it, along with the encoding it reports in and bracketed paste. The alternate screen goes the same way, so the prompt lands over the scrollback the dead shell left rather than on a screen with nothing behind it; it is left only when the terminal is actually on it, because leaving it otherwise restores a cursor that was never saved.

**A pane is the exception, because the pane is the thing that survived.** Reattaching finds the same application still running on the far end, so the modes it set are still true of it and resetting them would be the lie. The reset belongs to a shell that is new, which is every reconnect that is not a pane.

### A dial holds a claim on its tab

What may write to a session is whatever holds its claim, and nothing else. Every dial takes the tab when it starts and writes state onto the session only while it still has it. A retry, the reconnect schedule and the tab closing each take the claim for themselves, which is what makes the dial they replaced go quiet: the one it holds is superseded from that moment and never becomes current again. A bare counter says the same thing in arithmetic, and arithmetic is the wrong shape — one session's number compares equal to another's, and a passing integer carries no trace of the tab it belongs to.

**A closed tab never dials.** Closing takes the claim away for good rather than for now; otherwise closing a tab in the window a reconnect spends shutting the dead connection down is undone by the dial that follows, which opens a connection against a tab that is gone from the list — a live shell on the far host with nothing left in the app to close it. **A dial that lands after it lost the tab closes what it opened**, so a retry never leaves two shells running against one host in one tab.

### A session lets go of what it owns, and tells only the views drawing it

A session owns three listenables the terminal view is handed rather than makes — the selection controller, the focus node and the scroll controller — and owning them is the point: they outlive the view so a tab switch keeps its selection, its caret and its place in the scrollback. **The furniture goes after the frame that removed the view, not before it**: dropping the tab is what makes the route rebuild without it, and until that runs a live `Scrollable` is still attached to the scroll controller. Retiring is once and for all — a retired session is not reopened, reactivated or written to, a second retire does nothing, and the terminal is left to go with it, its scrollback being the largest thing a tab holds.

**A session tells the views drawing it, and nothing else.** What a shell prints, what it calls itself, what state it is in, what its bar has armed and which clipboard its host turned out to have are all facts about one tab, and each is announced by that session. A key pressed with a modifier armed once announced itself to the whole store, and the store is watched by the card strip, the host rows and the parked bar: every keystroke of a `CTRL` chord repainted every thumbnail on the screen behind the sheet.

**The list tells the list.** Which tabs exist, which one a host is looking at, and which one is parked are facts about the set, so those stay with the store, and they are the only things it announces. A view that draws one tab listens to that tab; a host row watches every session it counts; nothing reads a session's state through a listener on the store. **A retired session announces nothing**, so nothing in flight when a tab closed can reach a listener that has gone.

### A failure keeps the words it failed with

The line says what happened; the detail says what the machine said. `key rejected` is the whole of what the header has room for and the whole of what most failures need. Underneath it is the transport's own sentence — the ssh error, the code the host answered with — and that is the one thing that tells the user which of the six ways a key can be refused this was. It is carried on the state, not dropped at the seam that worded the line. **An error nobody mapped is its own detail**: a throw the transport has no reason for reads as a closed stream, which says nothing, so its own words are kept and the one failure the app cannot name is the one whose text is always there.

**The reason row opens.** A tap shows the detail under it, wrapped, and a second tap puts it away; with no detail the row is not a button and does not answer a tap. What is open is copied by the cell beside it, because an error is something the user pastes somewhere else. A reconnect does not carry a detail forward: what is shown belongs to the failure on screen, and a tab that came back shows none.

**Closing a dead connection is a failure nobody needs told twice.** A dial that failed closes what it opened, and closing a socket the host reset fails with the reset; that close is awaited and its error dropped, so the log holds the one line the app wrote.

### One vocabulary says why it broke, wherever it broke

Every sentence a failure is worded with is written once — the five ssh lines, the two host key lines and the screen route's own four — and each carries whether it names the host it happened to. Two do, because a machine that did not answer is about a machine; the rest are about this connection and read the same wherever they are found, so a host handed to one of those is dropped rather than prefixed and no caller has to know which kind it is holding. The header's uppercase word is derived from the same constant, so the two forms of a shell's failure cannot say different things about it. Each failure type answers what it is and none of them says it in words: five mappings remain because there are five domains, and changing what `key rejected` reads as is one edit every layer follows. The one line with a value in it — `protocol N` — stays a function beside the vocabulary rather than a constant in it.

**Struck:** folding the host panel's verify words into that vocabulary. `NO ROUTE` and `NO ANSWER` look like the same facts abbreviated and they are not: the probe reports a machine, and it separates a socket that opens and stays silent from one that never opens — a tarpit against a dead host, which the reason lines deliberately do not distinguish. Two vocabularies, because there are two questions.

### The key bar is one row of 36, and it keeps its last cell

A bar at the bottom of the route, always drawn, above the IME when it is open, landscape included. Cells sized to their label plus 10 px each side, never narrower than 36, the hit area the full row height. `FIND` is at the head, then `CTRL`, `ALT`, `ESC`, `TAB`, the four arrows and `END` in the strip's marks and the strip's mono. The bar's keys go through the byte table — `ESC` `1b`, `TAB` `09`, arrows `1b 5b 41..44`, `END` `1b 5b 46`, Return `0d`, backspace `7f` — and `CTRL` turns the next letter into its control byte while `ALT` prefixes it with `1b`.

**The IME belongs to the terminal.** The view takes text input itself through a focus node the route owns, and the keyboard toggle focuses and unfocuses it. Because a modifier has to reach characters the IME types straight into the terminal, the armed set lives on the session and is applied where the terminal's output becomes bytes.

**`ATTACH` is pinned, not scrolled.** On the phone the cells are wider than the row, and the cell that puts a picture in the hands of what is running sat past the right edge of a row that looks like a whole row: the only way in for a picture was a horizontal drag nothing asked for. It sits on the other side of the rule beside the keyboard toggle, where it is always under the thumb.

**A row that goes on says so.** Whichever end of the scrolling half still has cells behind it is drawn over with a short fade into the bar's own surface, so a cell is cut by a gradient rather than by an edge that looks like the end of the row. A bar whose keys all fit fades at neither end, and the fades take no taps: the cell under one is pressed through it.

**Struck:** a `PASTE` cell. The phone's text clipboard reaches the terminal through the IME, and a bar that hides its own cells is not fixed by putting another cell on it. **Struck:** `SUPER` and `SHIFT` on this bar.

### A modifier is armed for one key, for a count, or until it is let go

A tap arms a modifier for exactly one key and then clears it: a soft keyboard cannot hold two keys at once, and that is the rule a modifier cell answers to by default. The chords that end a program are not one key, and a session at a REPL is not a count, so the cell has three answers and the gesture says which.

**A downward drag sets a count.** One drag arms the cell at two, another takes it to three, which is the cap; an upward drag walks it back down and past two disarms it. **A long press latches it**, and a tap on a latched cell lets it go — the same tap that arms an unlatched one. A downward drag on a latched cell does nothing, there being nothing above forever, and an upward drag releases it whole. No cell is added to a bar the phone already scrolls, and a user who never drags never sees a count.

**The label rolls to say so.** The cell reads `CTRL(x2)` for a count and `CTRL(∞)` for a latch, arriving on a 140 ms downward roll — the old word leaving through the floor, the new one coming in through the ceiling — in the same accent an armed modifier already draws in. A latch replaces a count, and releasing goes back to the bare word.

**The arming belongs to the session, not to a cell.** One session holds one arming: which modifiers, how many keys they survive, and whether they survive keys at all. `CTRL` and `ALT` armed together apply to the next keys, both of them; `CTRL` latched and `ALT` tapped on after it are both latched; tapping either takes that one off, and the arming ends when the last modifier does. Switching tabs switches it with the session, and a reconnect, a close and a dead shell drop it.

**One spender.** The armed set is spent where every byte passes — the store — and the bar does not clear it on the side, so the bar's own keys and the characters the IME types count the same. A count walks down as keys go; **a latch is spent by nothing**.

**Only a key spends it.** A terminal answers the program on its own behalf — where the cursor is, what it is, how big it is, where a finger touched — and those replies go out on a path of their own. Nothing armed applies to them and nothing armed is spent by them. Left to share the user's path, an `ALT` put an `ESC` in front of a cursor report and the program read the wrong answer, and an agent that asks where the cursor is left `CTRL(x2)` at one before a key was pressed.

### The terminal's type is pinched to size, and the size is kept

A two-finger pinch scales the type: spread to grow, close to shrink, live while the fingers are down, rounded to whole points and held between 8 and 24, with 13 the default. Columns and rows follow the size the way they follow a rotation — the view re-measures, the terminal resizes and the host is told — so a smaller face is more columns and rows, not more margin.

One size for every shell on every host, kept in the settings table and read on the next open. It is the user's reading distance, not a property of a host or a tab, so it is not per anything, and there is no row for it in SYS: the gesture is on the surface it changes and the change is visible while it happens, which is the whole of the feedback. One finger stays the terminal's — a drag scrolls the buffer and a long press selects — and the pinch is taken only once two fingers have moved past the tap slop. The phone's own font scale still applies on top.

### A press selects where the finger is, and takes the whole thing

**The press is resolved once, at pointer-down, as a cell.** A long press is reported half a second after the finger lands and a drag frames later still, so a pixel resolved when the callback arrives covers whatever text has risen into it in the meantime — ten rows of output during the hold is a ten-row error. A listener above the terminal takes the down and turns it into an anchor on the buffer's own line, which follows that line through the scrollback, and every later callback reads the anchor back. Only the moving end of a drag is still a live pixel, which is correct: that end is where the finger is now. One pointer at a time — a second finger is a pinch and must not move where the first one landed — and an anchor whose line has fallen out of the scrollback answers nothing rather than a stale row. The end a selection grip is not dragging is an anchor too.

**A row's index is where it is now.** Anything that moves rows — trimming the front of the scrollback, shifting a region, replacing the contents — moves their indices with them, and detaches only what is genuinely leaving. An anchor is only as good as the index it reads. A ring that drops items off the front by walking a start pointer and leaving the origin behind has every surviving line reporting the index it had before the trim, and a full-screen application trims on every layout change: the alternate screen keeps no scrollback, so each time the soft keyboard comes up, a line opens or the type is pinched, the error grows by those rows. A shift must not tear a line out of the buffer it is still in — a region shift writes each slot from the one beside it, so the line just adopted is still sitting in the next slot when that slot is written — and a reflow starts the list over at the first slot rather than rotating it through a stale pointer.

**The unit is the run, not the word.** A word rule breaks on `.`, `:`, `-` and `/`, which are the characters a URL, a path and `file.dart:42` are made of, so it can only ever hand back one segment. What is taken is the run of non-blank cells around the finger, less the punctuation the run only happens to end in. Prose words are space-delimited, so this is a superset of what a word rule gets right, and it takes `/home/luis/x.dart:42`, `git@github.com:o/r.git` and `github.com/o/r` whole with no per-shape regex zoo. **A scheme inside the run wins the run**, which pulls the link out of `url=https://x.dev/a`; off the link, the run is still the answer. **Trimming stops at the finger**: sentence marks come off the tail, a wrapper around the whole of it comes off both ends, and a bracket whose other half is not in the run comes off, but nothing is peeled past where the press landed, so a press on the `.` of `done.` keeps it. `(bar)` inside a URL is balanced and stays; `foo).` is not and goes. **A soft wrap is not a boundary** — the logical line is walked out in both directions before it is read. **A press on a gap still selects**, falling back to the single cell.

### A click names a row of the screen, not a row of the scrollback

A terminal holds two coordinate spaces and they are not the same one. The buffer is the scrollback and the screen in one list, and a cell in it names a row that follows its line for as long as the line is kept. The screen is the rows drawn right now, and its first row sits at the buffer's row less however deep the scrollback has grown. A pixel under a finger resolves into the buffer, because that is the space a selection lives in.

**What crosses the wire is the other one.** An application asked for mouse reporting because it draws a screen, and the screen is all it has: it keeps no scrollback and has no row to name outside the one it painted. A report carrying a buffer row puts every press as many rows below the finger as the scrollback is deep, and that distance grows with the session instead of staying wrong by a constant. So a press, a release and a wheel report take the cell the pixel falls in and then subtract the screen's first row, clamped to the screen; a selection, a long press and a drag keep the buffer's row untouched. On the alternate screen the two agree, a screen with nothing behind it being its own buffer, which is why a full-screen application is the last place the difference shows.

### The wheel under a full-screen application is one listener

A drag over a full-screen application is a scrollable being read, not a buffer being moved. An application that asks for mouse reporting keeps nothing to scroll into, so the view under it is frozen and a second scrollable is laid over it whose only purpose is to have a position that travels; a render object beneath listens to that position and turns each line of travel into a wheel report on the wire. **That single listener is the entire path**, and a finger moving a position nobody is listening to does nothing at all.

The framework hands a scrollable a new position whenever anything it depends on changes, detaching the old one and disposing it a microtask later, so the listener has to move across with it — registering on attach and unregistering on detach is not enough. What changes under a terminal is the theme and the screen, and neither is the shell's doing: the tokens are rebuilt from the system palette into a new theme object, which notifies the scrollables under it for the length of the transition, and a phone that folds moves the app between two screens with different pixel ratios. **The keyboard is when it is found, not what causes it** — the insets it moves are not among the things that scrollable depends on; what the keyboard does is take half the screen, which is the moment a reader reaches for the scroll and finds it already dead.

### A view off the live line says so and offers the way back

The terminal follows its output only while it is on the last line. Scrolled up it stays where the reader put it and the shell goes on printing underneath, which is right and is the whole problem: nothing says the shell has moved on, and the way back is a drag of unknown length through a scrollback ten thousand lines deep. A cell over the terminal's bottom trailing corner appears the moment there is anything below the fold and goes when there is not, and a tap on it lands on the last line, from where the shell scrolls itself again.

**A key is not a read.** Bytes from the bar go straight to the remote and never pass the view, so anything sent to the shell puts the view back on the last line first. **One thing floats over the terminal at a time**: while there is a selection the corner belongs to the copy cell, and the way back waits until the selection is let go.

### The selection asks a surface where the cells are

What the selection needs from the thing under it is named once: how tall a line is, how big a cell is, where a cell is on the screen, and which cell a point falls in. That is the whole of what the selection layer knows about the terminal, and whatever draws the buffer answers it. **A cell's offset is already in the layer's own coordinates** — the terminal is drawn inside an inset and the overlay is not, so the surface settles it and nothing on top adds a padding of its own. **No surface is not a wrong surface**: between a tab being swapped and its view being laid out there is nothing to ask, so the grips go off the screen and the `COPY` cell goes to the corner over the key bar, where a thumb already is.

The route is one job per file. The sheet and its drag, the header, the terminal and its theme, and the selection are four things, and the file that holds the route holds the route.

### A selected link opens from the terminal

The floating cell reads `COPY` and `CLEAR`, and between them, on a selection that is a link, `OPEN`. It is drawn only when the selection parses, so the cell says what the selection is: the verb appearing is the app agreeing that those cells are a URL, and a grip dragged one character too far takes it away again. `CLEAR` keeps the trailing edge, because it is the way out of the selection and the last thing a thumb should find by accident; `COPY` keeps the first, because it is the verb that is always there.

**The scheme is the whole test.** A selection is a link when it says `http` or `https` in front of an authority, and nothing else is promoted: `min.io/docs` off a wrapped paragraph, `/home/luis/x.dart:42`, `git@github.com:o/r.git` and `mailto:` are left as text. Nothing demands a dot in the host either — `http://localhost:3000` and `http://100.118.60.77:8080/` are what a dev server and a tailnet address actually print, and a terminal is where you meet them. This is the opposite trade to the capture field's prose rule, which promotes a bare host and refuses a dotless one, and both stand: a title is prose and a selection is what the user dragged a grip across. **Whitespace ends it** — two words are not a URL, and a range dragged over a hard-wrapped line carries the newline that says so, while a soft wrap does not, the buffer stitching a wrapped line back into one string.

**Opening spends the selection, unless nothing took it.** The highlight goes when the browser goes, the way it goes on a copy. A launch the device refused leaves the selection and its cell where they were, so the words are still there to copy instead. There is no second look at the buffer: the press that made the selection did the finding, and there is no scan of the screen for links and no underlining of what was never touched.

### The scrollback is searched from a line under the terminal

**`FIND` opens a line, not a page.** A tap raises a line between the terminal and the bar — a field, the count, a step either way and the way out — and a second tap takes it down, with no sheet either way. A shell has no key that searches its own scrollback, and ten thousand lines is not a thing a thumb reads through.

**What is typed is looked for and nothing is sent.** The line takes the keyboard off the terminal while it is up, so the characters land in the field; the buffer is read and the shell is not written to. The bar's keys still reach the shell, because a search is not a mode.

Every hit is marked and the one being read is marked apart, both as washes the text shows through — a block over a glyph hides the very word that was found. **A search starts on the newest hit**, because what is being looked for is almost always what just went past, and the steps walk back from there; past the oldest is the newest again. The hit being read is put on the screen, which is what makes the mark worth drawing. **A hit rides the line it was found on**: the marks are anchored, so output printed under an open search leaves them on their own lines, and a line that falls out of the scrollback takes its mark with it. A search stops at five hundred hits, the newest five hundred — past that the query is not a search, and marking every line of a buffer costs the frame that draws it. Closing takes the marks with it and leaves the view where it is, because the line that was found is the reason the search was made.

**Struck:** a jumper that walks the user's own turns. Half the panes could never be walked and the half that could was the half that did not need it: a scan reads whichever buffer the pane is showing, which is the whole history on a classic renderer and exactly one screen on a fullscreen one, and on a fullscreen renderer the turns above the top row are in no buffer the app holds. Nothing the app is allowed to do reaches them — writing scroll reports at the pane, reading the host's own session files, and a multiplexer's scrollback capture that scrolls the pane and refuses while the agent is working, which is when a phone is watching. A feature that is right on one renderer and quietly partial on the other is worse than no feature, because the user cannot see which one they got. A search is honest under either: a count of zero on a screen with no scrollback is an answer, where a jumper that steps three turns out of thirty is a claim.

### `ATTACH` puts a picture in the hands of whatever is running

The cell reads `ATTACH`, and `ATTACH!` while memory holds anything; the count is not on the bar. The sheet it opens is `[ ATTACH ]`: `PHOTOS` first, an action block that opens a multi-pick of the gallery and attaches every picture picked, in order; then a rule and `HELD`, the tiles of what the screen route is holding, or `NOTHING HELD`, a tap attaching one and `×` dropping it. **Photos are never held**: they go in and are forgotten.

**A `?` on the header strip, beside `CANCEL`.** A host is uploaded to, a clipboard is written and a keystroke is sent, and none of that is visible from a sheet of two verbs and a grid of thumbnails. `?` is a toggle and not a route — the sheet is the only surface the answer is on — and the copy is off until it is asked for, because a sheet that explains itself every time is a sheet whose explanation is scrolled past. Opening drops the copy in above `PHOTOS`, over its own rule, and the `?` goes accent while it is open; nothing else on the sheet moves and reading attaches nothing. Three things are said and no more: what `ATTACH` is for — a picture put in the hands of whatever is running in the shell, read off the clipboard rather than named at it; what `PHOTOS` does — the gallery, many at once, in the order picked, and the path typed at the cursor where the host has no clipboard tool; and what `HELD` is — the crops, kept for the app run, a tap to send and `×` to drop. It is the sheet's own body copy, so it is the Sans of an action sheet and not another tracked mono label.

**A clip lives for the app run and nowhere else.** It is not an attachment, it has no row, and it does not survive a launch. The file sits under a `clips` directory in the cache the system may take back on its own, and the app deletes that directory before the first frame, which is what makes "runtime only" true across a kill nobody saw. In memory the app holds the record and nothing else — id, file, pixel size, source, the host it was cut from, the moment — and no thumbnail: the tray draws the file at tray width, so the full picture is never decoded whole. The budget is eight clips and 24 MB, whichever binds first; a ninth, or one that crosses the ceiling, deletes the oldest until it fits, and dropping the last one takes the directory with it. A clip cut on one host may be attached on another, so a shell session is the wrong owner for it.

**The bytes go up on an exec channel, every time.** A second channel on the same ssh client, never the pty, whose bytes a pty would translate: `mkdir -p /tmp/dazzle && cat > /tmp/dazzle/<name>`, the file whole on stdin, exit 0. No sftp — a plain exec channel is what this app already opens and it works on a host with the subsystem off. They go up on every paste rather than once per host: `/tmp` is cleared by a reboot the app never hears about, and a path an agent is then told to read would be a lie. The file is left there; the host's own reboot is the cleanup.

**Pasting is the clipboard, on every host that has one.** Neither agent reads a picture off the terminal — both take it through the system clipboard and what the terminal sees is a key — and over ssh the agent runs on the host, so the clipboard that matters is the host's. The app writes it directly: upload, set the host's clipboard to the file as `image/png`, then one `0x16` into the pty, and both agents answer `[Image #1]`. Many at once is one upload, one copy and one `0x16` per picture, with 300 ms between them because the agent reads the clipboard on the keystroke and the next write has to wait for that read. The sheet reads `ATTACHING 2 OF 5` while it runs and `PASTED · 5` or `PATH · 5` at the end for a moment; a failure stops the run where it is and leaves its line on the sheet.

**Four clipboard backends, one per display server, all first class.** Wayland: `wl-copy --type image/png` under `setsid`, since the process that owns a Wayland selection must outlive the channel that started it. X11: `xclip -selection clipboard -t image/png`, likewise detached, or `xsel` when `xclip` is absent. macOS: `osascript` reading the file as a PNG pasteboard item, which is the only way to put a picture on the pasteboard from a shell. And none: the host has no display server and there is no clipboard to write. Windows hosts are not addressed; the probe reports them as none.

**The probe runs once per host per connection**, cached on the connection and re-run when it comes back, and one exec channel answers all of it: the system name; the runtime directory and the first Wayland socket in it; the X display and its authority; and which of the tools are on the path. An ssh exec channel inherits none of a desktop session's environment, so every one of those is read rather than assumed, and the pair the backend needs is carried on the command the paste runs. **Wayland is probed one step further**: a watch on the selection is run under a one-second timeout, and the timeout killing it is the data-control protocol being present while an immediate exit with the compositor's own complaint is it being absent. Listing the types is not the test — the tool exits 0 on an empty selection and 1 on "Nothing is copied", neither of which is about the protocol. That extension is the same one the agents' clipboard reader needs, so a compositor without it is a host with no clipboard as far as this feature is concerned, and is reported as such rather than being allowed to fail at the moment of a paste.

**The result is a fact about the host and is drawn as one.** The host panel carries a `CLIPBOARD` row while a shell is open on it — `WAYLAND`, `X11`, `MACOS` or `NONE` as mono tokens — and `NONE` carries its reason under it in `--fg-dim`: `no display server`, `no wl-copy`, `no xclip`, `compositor without data-control`. A host whose clipboard is missing a tool it could have is a host the user can fix, which is the point of saying which tool.

**Where there is no clipboard the app types the file's absolute path into the pty at the cursor, and a space after it.** This is not a lesser version of the feature: it is the documented way in for both agents, and on a headless host it is the only way in that exists. The tray says which of the two ran, `PASTED` or `PATH`, for a moment. **Neither failing types anything and neither leaves half a paste**: the upload must exit 0 before the clipboard command runs, and the clipboard command must exit 0 before the `0x16` goes in.

**The login shell behind an ssh session carries no desktop environment**, so an agent started in a tab found no Wayland display and fell back to an X11 socket it could not reach, while the picture was on the Wayland clipboard the whole time. The host's own login shell is where that is fixed: with no display set it discovers the first socket under the runtime directory and exports the runtime directory and **one** display — Wayland when a socket is found, X11 only otherwise. One and not both, because an agent's reader tries X11 first, and on a Wayland desktop the X11 clipboard is the bridge, which holds the selection only while an X11 window has focus. A multiplexer attached from the desktop never had the problem, which is why it went unseen.

**Struck:** forwarding the host's Wayland socket over a stream-local channel and speaking the clipboard protocol from Dart. It removes the dependency on one tool and buys nothing else — it cannot help X11, macOS or a headless host, and it puts a hand-written Wayland client in a phone app to save one `command -v`.

### A passphrase the host asks for is asked for on the phone

**The prompt was never the app's to fix alone.** A key agent asks for a passphrase on whichever tty it was last told about, through a pinentry that draws over whatever is running there: a full-screen application in a tab gets a curses box painted across it and the two fight for the same keys, and no terminal can stop that from its own side. So the host runs its own pinentry, which never touches the tty that asked — it puts a modal on the computer, a fullscreen terminal window on the graphical session or a reserved console otherwise, and at the same moment writes the request into every terminal that asked to be told. The first decision wins and the others withdraw. This app is one of those terminals, and what follows is the terminal's half.

**A shell marks its pty the moment it is up.** On the tab's own connection, an exec channel writes the pid of whatever holds the tab's pty into the pinentry's directory under the pty's name. The holder is the connection's own sshd session, which is the channel's parent, or the Mosh server the tab was started under, found by the tab's mark in its environment — a Mosh shell hangs off a server that let go of the ssh session that started it the moment it came up, so the channel's parent owns no pty then. The mark is a pid rather than a token because a mark whose holder has ended is stale by inspection and the pinentry drops it itself; the app never unmarks, not on close and not on a redial, which marks again on its own. A host without the pinentry gets a directory nobody reads, and the exec's failure is dropped unspoken either way.

**The request is a private OSC and the answer is a fifo.** One sequence carries what the agent said — mode, description, prompt, the error line of a failed try, its own labels for the two verbs — and another says the request was settled elsewhere. The terminal already parses OSC and hands the ones it does not know to the session, so nothing scans the byte stream. The answer goes on a second exec channel, `cat` into the fifo the id names, guarded so that a request already gone leaves the passphrase in no regular file. It travels on the channel's stdin and never on a command line; a bare newline is the cancel; an id outside `[a-f0-9]{16,32}` is not a request and nothing is run.

**The bell is the signal and the host is the source.** An OSC reaches a tab whole over ssh, but a Mosh shell's pty ends at a server that ships a screen and not a byte stream, and a sequence it does not know never leaves the host. So the pinentry rings the pty's bell after every sequence, request and withdrawal alike, and a tab that hears a bell — any bell, whoever rang it — asks the host what its pinentry holds open: one line per request, a request being open while its fifo stands. What comes back is the tab's request, and nothing coming back withdraws the one it had. Bells that land while the host is being asked fold into one more ask, so a program that beeps ten times costs one exec and not ten. The pinentry takes the fifo and its json down before it rings the withdrawal, so a tab that asks then finds nothing. Mosh rings once per frame it ships, so a request and its withdrawal inside one frame ring once; a tab holding a request therefore asks again every five seconds for exactly as long as it holds one, and takes the empty answer as the withdrawal. **One request is one fifo**, so an answer from one tab settles it on every tab of the host at once, and an answer that comes back on a connection that is no longer the tab's is dropped.

**The sheet reads `AUTHORIZATION REQUIRED`.** Under the header: which shell, what the agent said about the key in its own words, the error line in the danger colour when a try failed, an obscured field under the agent's prompt, then `CANCEL` and `UNLOCK`. A confirm carries no field and draws the agent's own labels on the two blocks; a message draws one. Return on the field is `UNLOCK`. One at a time, and on the shell route only: a request that lands while the user is on Home has the computer's modal, and is put up when the route is entered if it is still open then. Every tab lists what the pinentry holds open as it connects, after its mark, so a request made while a tab had no link is found rather than missed. The sheet goes up for the tab on screen when it holds one, else for the first live tab that does, and its `SHELL N` follows every tab of the host, since a tab taking a request is that tab's own news.

**Withdrawal is not cancel.** The withdrawal takes the sheet down with nothing sent — the computer answered, the agent gave up, or the host's own window ran out. Swiping the sheet away is the phone declining to be the one that answers: nothing is sent, the request stays open on the computer, and the sheet does not come back for that id. `CANCEL` is a decision and cancels everywhere. A connection that drops or a shell that exits takes the request with it, because the fifo it would be answered on is on the other side of a link that is gone.

### A passphrase ask grows old, and an answer that reached nobody says so

**The host never says how long it waits.** The pinentry holds a request for a window of its own and ignores the agent's own timeout, so nothing on the wire carries a deadline: the payload is the agent's words and the open listing says a request stands, never for how much longer. When the window runs out the fifo comes down and the same withdrawal an answer at the computer sends is rung, so from the phone's side an ask that expired and one settled at the computer are one event and always were. What the phone can know is its own clock, so it stamps an ask the moment it first hears it and counts up from there; it never counts down to a deadline it would be inventing, and it never says an ask is over on a count alone.

**An ask the phone has held five minutes stops presenting itself as certainly live.** The count is taken on the recheck that already keeps the ask alive, and one that keeps coming back past five minutes is drawn from then on as one the host's own window may have run out under: `MAY HAVE EXPIRED` in warning over the field, and the affirmative block loses its fill. Both blocks stay tappable — the host listed the request as open a moment ago, and refusing the answer on a local count would be the phone's guess overruling the host's own word. The id does not change as it ages, so the sheet stays where it is and the shade is not rung again. Five minutes is the pinentry's own default window, which the phone cannot read and does not claim is the one in force.

**An answer that reached nobody is not swallowed.** The passphrase is written into the fifo only while the fifo is there, so what that command comes back with is the verdict: a failure is proof the ask was already down, that nothing was written and that nothing is waiting on it. A command that never comes back says the same thing more quietly, and it is the commoner half — a pinentry that died without taking its fifo leaves one that still passes the guard, and the write into it waits on a reader that is never coming. So the answer is given five seconds to land, and a write still going when they run out is read as an ask that is gone. **The channel it was on is taken down with it**, because closing the channel is the only thing that ends a command blocked on something that will never arrive, and a dead request must not hold the connection and the passphrase written into it open for the life of the session. The phone says so instead of letting the user believe they unlocked anything: `AUTHORIZATION EXPIRED` over the shell it was typed on, that the host had taken the ask down so nothing reached it, and that the ask comes again if the key is still wanted. A channel that never came back at all is the link going, which already has the route's own word on it, and gets no second sheet.

### A passphrase the host asks for rings the shade

One notification per host, on a channel of its own — high importance, with the channel's own sound and vibration — so a blocked agent can be kept quiet and a key being asked for still heard. The title is `AUTHORIZATION REQUIRED` and the text is the host's name in capitals and what the agent said about the key, the prompt when it described nothing, the name alone when it said nothing at all. It reads the same in the shade as on the sheet.

**Up while any tab of the host holds the request, down the moment it is settled.** Two tabs that hear the same request are one notification; a request with another id replaces it in place and sounds once more, because it is another ask. Answered on the phone, answered on the computer, given up on by the agent, lost with the link, dropped by a redial or gone with its tab — each takes it down, and it comes down exactly once. The store is what knows all of that, so the store tells the shade. **A notification re-rung at five minutes would wake the phone to say the same thing less certainly than the first time**, so the shade is left where it is: age is something the reader sees when they come to answer, which is the sheet.

**The tap is the way to the sheet.** It opens that host's shell, taking the sheet over from another host's if one is up; the passphrase sheet is already standing there, and the sheet stays until the request is settled. A tap that starts the process is parked the way an alert's `OPEN` is and replayed once Home is on screen, on the host it named — a host deleted since opens nothing. There are no `YES`/`NO` here: a passphrase is typed, never tapped, and nothing has to work with the activity gone, because the tabs that hear the request live nowhere else.

**The ids keep out of the alerts' way.** An alert id is 1000 plus thirty bits of its host and pane; a passphrase id starts above that region and folds the host to twenty-nine bits, so the two never collide and both stay inside the signed 32-bit id Android takes. The payload names the host and nothing else: the sheet has the request.

### A shell that lost its network comes back on the pane it was on

A link that dies under a live shell puts the tab on six waits — one, two, five, ten, twenty, thirty seconds — and every dial goes back to the same tab, the same terminal and the same attach command against the same pane id, so the agent is where it was and `-- reconnected --` is the only new line between the dead shell's output and the new one's.

The end of that schedule is a tab waiting, not a tab that failed. The link is gone, the terminal still holds every byte the dead shell printed, the tab still carries the command it runs and the pane that command attaches to, and nothing is on a clock: sixty-eight seconds of schedule can run in a pocket, so a phone that was asleep comes back to a shell it can still have rather than to a dead tab. A waiting tab carries what its last dial hit rather than the drop that started the schedule, so the row under the header reads `rose unreachable` and `STOP` ends the tab on those same words. Only a closed stream and a machine that did not answer get there. A key the host refused, a shell it would not give and a host key that is not the one pinned are answers rather than accidents: they fail on the first dial and are never waited on or woken.

Two moments dial a waiting tab again, and it has no clock of its own. The app coming back in front, and a network arriving under it — the platform's default-network callback, so a handover straight from wifi to cell counts as an arrival even though the phone was never without a network, and nothing is replayed on subscribe. Either moment dials every waiting tab once as the first step of a fresh schedule, so a dial that misses waits two seconds and goes on rather than running the whole minute out again unwatched. A tab still inside its schedule has a timer already and is left to it. A tab that failed on an answer is not woken: a new network does not change what the host said.

Nothing dials while the user is looking at `AUTHORIZATION REQUIRED` or at an unknown host key. Answering what the host asked is the user's turn, and a reconnect underneath it would take the shell the question belongs to out from under the answer. The hold is a count, taken when a sheet goes up and released when it comes down however it comes down, so two sheets at once still leave one hold standing.

The middle of the header reads `WAITING`, muted, where `RECONNECTING 4/6` reads, with `STOP` beside it. There is no spinner: the app is not working, it is waiting, and a spinner would say the opposite of both.

### A shell tab owns a remote identity, not an SSH socket

Transport continuity and process continuity are separate layers. Mosh does not depend on tmux or herdr. Dazzle uses real Mosh over UDP when the host provides `mosh-server`; tmux and herdr only determine which remote process a later transport reaches.

**Mosh is the preferred transport, SSH is the fallback.** SSH authenticates the pinned host and starts `mosh-server`; terminal traffic then moves to the Mosh UDP channel. The tab writes `MOSH` in its header only after that channel has produced terminal output. Resume or a network change rehomes the existing Mosh channel instead of opening another login. A missing server, failed bootstrap, blocked UDP range, or first-output timeout cleans up the attempted server and continues over the already-authenticated SSH connection. An SSH tab retains the existing reconnect ladder, and a Mosh tab reaches the same one once its channel has stopped answering.

**Anything the server signed is contact, and a channel that has stopped sending it is given up on.** A packet that carries no new screen still proves the machine is there, so a shell that prints nothing for an hour is a shell that is fine. Silence is what the tab measures: it pokes a quiet channel with the size it already has, and a poke that goes unanswered reads `RECONNECTING`, three of them `DISCONNECTED`, with the channel left open under both because Mosh can come back on the session it already holds. Thirty seconds of unbroken silence ends that. The channel is dropped and the tab enters the same six waits an SSH tab gets, so the dial that lands comes back on Mosh, or on SSH where the host has nothing to start, and the tab has a `STOP` again rather than a word that nothing will ever change. What is counted is answers missed and never seconds passed: a process Android froze in a pocket thaws with every poke it owed due at once, and that is one gap in the link rather than one miss for each, so a phone coming back in front rehomes the channel it had — which clears the count — instead of throwing it away.

Every tab gets a validated random id. The id marks its `mosh-server`, so a process restore can remove only that tab's abandoned server before starting another. A live Mosh channel is not serialized: after Android kills Dazzle, the app establishes a new Mosh transport and then restores the remote process through the separate identity layer. Dazzle does not yet claim speculative local echo prediction; authoritative terminal state comes from the Mosh server.

**An ordinary tab is the host's ordinary login path.** Dazzle does not insert a multiplexer. The random tab id marks only its Mosh server; it is never handed to `tmux`, used for cwd lookup, or treated as remote process identity. A new tab and an app-restored tab both enter through the same login shell, so the host's own gateway or chooser remains authoritative. A transport reconnect or process restore opens a fresh shell and writes `-- reconnected --`; Dazzle makes no process-continuity claim for an ordinary tab.

**A herdr tab records herdr's identity and does not nest another multiplexer.** Its row stores the herdr session and pane id as a pair. A new Mosh or SSH transport reconstructs `herdr agent attach` from that validated pair, so the same agent pane returns. herdr remains the owner of the pane and its process. Closing the phone tab detaches and cleans up that tab's Mosh server; it does not kill the agent.

**Close is remote cleanup with a durable retry.** Closing a tab first hides and retires its row, then kills only the `mosh-server` carrying its exact marker. It never addresses a tmux server or session. A failed or interrupted cleanup leaves a tombstone that no restore can draw. The next successful connection to that host retries those exact markers and deletes each row only after cleanup succeeds. A dial that lands after its tab was closed follows the same path before closing its transport.

The shell tab table carries nullable `remote_session`, `herdr_session`, `herdr_pane`, and `retired_at`. Every new tab has a `remote_session` used only as its Mosh cleanup marker. A herdr tab adds a complete session/pane pair; partial pairs are refused. A row written by an older build has no identity. The v14-to-v15 migration leaves every new column null; it never invents one. New rows are written before their first network dial, so Android cannot leave a marked Mosh server whose identity never reached storage.

### The middle of the shell header is a mark, and the words are behind it

The middle of the header row never carries a word. `CONNECTING`, `RECONNECTING`, `DISCONNECTED`, `EXITED`, `MOSH`, the failure kind and a `STOP` beside them are not on it. While the shell is up the row is the host, the tabs, the diff mark and the close, and the middle of it is empty.

**One mark where the words were, and only while there is something to read.** `(i)` in the panel-header style, in warning, in one 44 cell of its own between the diff mark and `×`. The user's own notation, and a glyph the family draws: a circled `i` is not in Barlow Condensed and would come back from the system's fallback in somebody else's letterform. It stands only while the session is not live. A shell that is up has nothing the row needs to say, so the middle is empty and the host name keeps the whole 112 it had before any of this: a cell that is always there costs the name whether or not it is carrying anything, and the width was the user's complaint. The mark appears the moment the link does not hold, which is the moment a reader is looking for it.

**A tap opens the tab's readout.** The house panel sheet, titled `<HOST NAME> <n>` for the tab on screen. `STATE` carries the word the header used to carry — `LIVE`, `CONNECTING`, `RECONNECTING`, `RECONNECTING <n>/<m>` while a schedule is running, `EXITED <code>`, or `DISCONNECTED`, in warning unless the shell is live. `TRANSPORT` is `SSH` or `MOSH`, and `—` once there is no connection left to ask. While the session is dropped or waiting the sheet takes `STOP` under a rule, as a text action: giving up on a reconnect is still the one decision this route offers, and it is made here now. The sheet reads the session and not the tap that opened it, so a tab that comes back under it loses its `STOP` rather than leaving a control that would answer nothing.

The reason row under the header is untouched. A failure is still one short row in warning with the host's name in it, because why a shell is not there is worth a row and what a live shell is talking over is not.

### The detail under a machine that did not answer names the machine that was dialled

The reason row's detail is the app's own sentence when the failure is about reaching a machine, and the transport's sentence for everything else. `unreachable` and `unresolved` are the two lines that name a host, and their detail names the dial the same way: `<user>@<address>:<port>` as the host row has it, a middle dot, then the operating system's words for what happened, lowercased, `luis@100.64.0.253:2222 · connection refused`. A dial that ran out of time reads `no answer in 10s`, with the timeout the dial was given. Nothing from the socket's own report of itself is kept: the address and port it prints are the phone's end of a connection that never opened, and a reader sent to `port = 44354` goes looking for a service that was never dialled.

`key rejected`, `shell refused`, `stream closed` and the two host key lines keep the transport's sentence as it came, because for those the ssh error is the one thing that says which of the several ways this failure happens it was. A throw nobody mapped still keeps its own words. The row still opens on a tap, still copies what is open, and still carries nothing forward across a reconnect.

### A program that asks what the terminal is drawn in is answered

A program that paints a whole screen asks the terminal for its colours before it paints one: `10` for the foreground, `11` for the background, `12` for the cursor, each asked with a question mark, and a question can chain — every mark after the first asks for the next colour in turn. Each is answered `rgb:` and three channels, the eight bits of a colour written across the sixteen the format carries, and the answer ends the way the question did, a bell for a bell and a terminator for a terminator, because a program reading until a bell never sees an answer that finished any other way.

**What is answered is the palette the terminal is actually drawn in, and there is one of it.** The foreground, the ground and the cursor are the house terminal's, which is what the terminal is drawn in under every scheme the phone can put behind the rest of the app — the ANSI table and the grounds do not follow the system's colours — so the answer cannot go stale under a theme changing mid-session. The colours are given to the terminal when the session is made rather than pushed from the view, because a tab that is restored without being looked at is asked this question before anything of it has been drawn.

**Saying nothing is not neutral, and it is what put the block on the screen.** A program that asks and hears nothing assumes a palette of its own and paints its ground with it, so its panes come up filled with a dark that is not the terminal's: a rectangle edged exactly where that program's panes are, over a screen that is black everywhere the program left alone. A desktop emulator hides its own copy of this, because a cell whose ground is the one it was configured with is folded back into the default ground and drawn as that instead — the phone does no folding and draws what it was sent. The difference between the two screens is an answer given on one machine and withheld on the other.

**It leaves the way the terminal's other answers leave.** Nobody typed it, so it goes out on the report channel beside the device attributes and the cursor position, past the modifiers the shell arms for what the user types and untouched by them.

Struck: honouring the other half of the sequence — a program setting those colours, and putting them back. The terminal's ground is a surface of this app, drawn in the house's colours under the house's chrome, and a program that repaints it has themed the phone rather than its own screen. The sequences are left unhandled, as they were.

Struck: answering the same question about a numbered colour of the ANSI table. Nothing that runs here asks it, and a program that did would meet the silence this section describes with its own table, which is a colour being wrong rather than a surface being taken.

Struck: a list of terminal themes for the reader to choose from. The colours the remote paints with are not a taste the reader was expressing, and a picker makes them answer by hand, once per program, a question the program had already asked out loud.

Struck: reading the ground back off the screen — taking the colour the remote filled most of the pixels with as the terminal's own. It is a guess at the answer to a question that was asked plainly, it moves the ground under whatever the remote happens to be drawing, and it is wrong in exactly the case that matters, a program that fills the screen with something other than its ground.

## Screen

### The host's screen rides inside its own ssh connection

The VNC client is the app's own, pure Dart, no plugin. **It never opens a VNC port itself**: the RFB stream rides a `direct-tcpip` channel inside the host's ssh connection, targeting `127.0.0.1:5900` on the host. No new key, no new gate verb, nothing new listening on the far side — the host's VNC server stays exactly as it is. The one host-side fact is that a `restrict`ed key line refuses channel opens, so the line needs `port-forwarding,permitopen="127.0.0.1:5900"` beside it.

The integration is a `VNC` row in the host form's `[ INTEGRATIONS ]`, and the display is the host's own `127.0.0.1:5900`.

### The way in is the preview tile on the host's panel

When a host has the screen integration on, a tile sits under its metadata rows, the full width of the body, in the aspect of the last frame — 16:9 when there is none — on a black ground. **It draws the last frame seen on that host's screen, blurred just enough that the layout reads and the text does not**: the frame is stored 320px wide and drawn with a gaussian blur of sigma 2 at that size, and nothing more. `SCREEN >` sits over its bottom-right corner in the affordance style and the whole tile is the hit. With no frame yet the tile is black with `NO FRAME YET` centred in mono 11 muted, and is still tappable.

The frame is written when the screen route leaves and every thirty seconds while it is live, downscaled with area averaging, as a PNG at `screens/<host id>.png` in the app support directory — one file per host, replaced in place, deleted with the host. It survives restarts.

The tile is the only way to a host's screen. The agents panel and the agents route are about agents and nothing else.

### The screen route is the picture and a rail

Breadcrumb `/ <HOST> SCREEN`, alone while the session is live: there is no `LIVE` word, because a live picture says so. `CONNECTING` and the reason lines stand on its right when they have something to say, each with a `RETRY` text action; there is no reconnect loop here. Below it, black ground and the framebuffer scaled to fit the width. No nav bar and no capture bar, and it is the only route that allows landscape.

The reason lines are `unreachable`, `unresolved`, `key rejected`, `tunnel refused` when the channel open was denied, `auth unsupported` when the server offers nothing the client can do, and `stream closed`.

**Gestures.** A tap moves the pointer there and left-clicks. A long press right-clicks; a long press then a drag holds button 1 while moving. A pinch zooms about its own centre, and a two-finger drag pans the zoomed view — at fit, where there is nothing to pan, it sends wheel events instead, one button 4/5 press and release per 40px.

**The rail** is a vertical panel on the left edge of the picture, vertically centred, over it: three 44px toggles stacked, one for the soft keyboard, one for the key strip and one that arms crop mode, ink `--fg-dim` and accent while the thing it toggles is up. The keyboard toggle is a panel of key rules over a spacebar and the strip toggle is a single keycap carrying a caret: stacked one above the other, two drawings of a keyboard differing only in how many rules they hold are one drawing to the reader. The keyboard and the strip are independent — strip without keyboard, keyboard without strip, both, neither — and closing the keyboard by the system gesture or the IME's own hide leaves the strip where it was. It keeps the same edge in landscape.

**The rail hides on a drag to the left over it.** It slides off the edge and leaves an 8×44 handle at its vertical centre, `--fg-dim` fill with a 1dp keyline so it separates from a light picture behind it. The hidden rail keeps the footprint the shown rail had as its hit region, transparent except for the handle: a drag to the right starting anywhere in it, or a tap on it, brings it back. That region reaches past the system's own back-gesture edge zone, which would otherwise swallow a drag starting on the handle itself. Pointer drags starting inside that patch belong to the rail and to nothing else on the picture. It is shown on every route entry, the hidden state lives with the route and is not persisted, and there is no timed auto-hide.

### The key strip is two rows of six

Top row `ESC`, `TAB`, `SHIFT`, an empty cell, `↑`, `END`; bottom row `SUPER`, `CTRL`, `ALT`, `←`, `↓`, `→`, so the arrows form an inverted T in the last three columns. The columns share the width equally. The strip's own toggles are not repeated in it; the rail carries them. It sits above the keyboard when the keyboard is up and at the bottom edge when it is not.

`CTRL`, `ALT` and `SHIFT` are sticky and arm exactly one following key. `SUPER` draws the ⌘-like house glyph with no word beside it; the four arrows draw their own glyphs; everything else is a mono 11 tracked word.

**Struck:** `HOME`, `PGUP` and `PGDN`. The user does not use them.

**Struck:** an `ENTER` cell and a `DONE` cell. The keyboard's own return key is Return, and the rail closes what the rail opened.

### Typing is keysyms, and the IME's return key is a real Return

Each typed character goes as an X keysym press and release — Latin-1 codepoints direct, everything else as `0x01000000 + codepoint`. The hidden field takes a multiline input type with a newline action, so the IME shows its ↵ rather than a checkmark that sends nothing, and a `\n` in the field is one press and release of `XK_Return`, never text. The field resets itself after each character.

### A rectangle cut out of the picture is saved to the gallery or held for a shell

Armed, the picture stops taking pointer events for the host and takes a drag instead, which draws a rect over it in the accent and dims what falls outside; the rail's other toggles and the key strip are inert while it is armed. Releasing leaves the rect on screen with `SAVE` and `HOLD` under its lower edge, both in the accent, and a fresh drag anywhere replaces it. There is no `CANCEL`: a fresh drag replaces the box and the rail toggle leaves the mode. Crop mode disarms on either verb and on leaving the route.

Both verbs map the rect's corners through the same transform the pointer uses, so the cut is in host pixels under fit and under zoom alike, clamp them to the framebuffer, refuse a rect under 8 px on either side, copy the pixels out and encode them as a PNG. **Nothing is downscaled** — a crop of a terminal is read by an agent, and deflate over flat glyphs is small already.

`SAVE` writes the PNG to the phone's gallery under an album `Dazzle`, through MediaStore; Android 10 and later need no permission for the app's own media, and the manifest carries the legacy write permission capped at the API before it, asked for on the first save. `HOLD` puts it in memory for the app run, where the shell's `ATTACH` sheet can reach it. **Never both**: a saved crop is not held and a held one is not saved.

**The word for what happened goes in the breadcrumb's state slot**, the one `CONNECTING` and a reason line use while not live: for two seconds after the verb it reads `SAVED · 240×120`, `HELD · 240×120`, or `SAVE FAILED · <reason>` / `HOLD FAILED · <reason>`, in the panel header style, then the breadcrumb stands alone again. Nothing is drawn over the picture for it.

### The protocol is RFB 3.8, and the pixels arrive in Flutter's own order

Versions 3.3 and 3.7 are accepted by their own rules. `ClientInit` is shared. `SetPixelFormat` asks for 32bpp, depth 24, little-endian, true colour, with red at shift 16, green at 8 and blue at 0 — which is Flutter's `bgra8888`, so a rect lands in the framebuffer with no swizzle. `SetEncodings` is ZRLE, CopyRect, Raw, DesktopSize, in that order of preference. One non-incremental update request first, incremental after, the next sent as soon as the previous update is painted, at most twenty-four a second.

ZRLE uses one zlib stream for the whole session, 64px tiles and every subencoding — raw, solid, packed palette of 2, 4 and 16 colours, plain RLE, palette RLE — with CPIXEL at 3 bytes as the spec reads it for this format. Bell, cut text and colour-map messages are read and dropped.

There is one framebuffer, a `Uint8List` sized by `ServerInit` or by a desktop resize, with rects blitted into it and **one image produced per update, never one per rect**.

**Struck:** taking a published RFB package. It handles Raw and CopyRect only, and it owns its own socket — which is the one thing this client cannot allow, because the socket here is a channel inside somebody's ssh connection.

## Code

### A registered directory is a primitive of its own, beside the projects

A checkout is not a property of a machine the way an address and a port are: it outlives which machine holds it, and it is what the user actually works in. So there are two primitives with two homes. PROJECTS is the board and nothing else. CODE is every registered directory across every host, and it lives on HOSTS because a registered directory is a host thing the app owns and not a Projects thing. **They are siblings, not a hierarchy**: a workspace with no project is ordinary and a project with no workspace is ordinary.

**Struck:** a fifth destination in the nav. Four labels is what fits inside the content cap with the parked shell bar over it, and a switch that lives on the screen it switches costs no chrome at all.

**A workspace row is `<owner>/<repo>`** in `rowTitle` — the last two segments of the directory, which is what tells two checkouts of the same name apart — with the host name at the right edge in `rowKicker` `textMuted`. Under it, when the host has answered, the branch and the dirty count in the mono `rowSubtitle`: `main  +142 −38  4 files`, or `main` alone when clean. A host that has not answered yet draws the row without the line rather than a spinner per row. Grouping is by host and ordering is by name, one panel per host with its count on the strip, and a host with no registered directory draws no panel.

**Registration is a pick, never a typed path.** `ADD` asks which host first — a panel sheet of the registered hosts, skipped when there is only one — and then opens the picker, which asks the host for its own checkouts: one command walks the roots for git checkouts and returns them as a list, filtered by a field that matches anywhere in the path. `.git` is matched by name and not by type, so a superproject's submodules are in the list and so is a linked worktree, whose `.git` is a file. The sheet checks rows off and closes on `ADD n`, because a host is registered once and has thirty checkouts on it, not one; a path already registered is kept out of the list. A long press on a row offers `RE-POINT`, the same sheet in single mode, and `REMOVE`. A row in the picker is one line, the last two segments and nothing else — no label line, no directory line, no agent mark: a path answers for a directory.

**Discovery needs sshd and nothing else.** The picker and the CODE list are drawn for any host the app can dial. A multiplexer on the far side still gates SEND, the agent marks and the AGENTS panel, because starting a pane needs a running session; a host with sshd and nothing else gets the whole of the explorer and the diff and no SEND row.

**A workspace links to at most one project**, and a project holds any number of workspaces. The link is set from either end — the workspace's own `PROJECT` row, the project detail's `CODE` section — and cleared the same way. Deleting a project clears the column rather than removing the row. What the link buys is the send: choosing a target on an item whose project has exactly one workspace opens on that workspace preselected, and with more than one its host's rows come first. The kind and the model are still asked, because those belong to the send and not to the directory.

### Everything on the workspace is read back, not stored

State that can be asked for again is not state worth a table. The registered directory and its project link are the whole of what the database holds about a checkout; the branch, the upstream, the dirty count, the listing, the file, the hunks and the worktrees are asked of the host and kept for the life of the sheet.

**One warm connection, one composed command per action.** Commands run on a second channel of a connection the app already holds, so when a shell is open on the host the workspace pays one channel and no dial; when none is open the sheet dials its own and keeps it for the sheet's life. The budget is round trips: the branch, the upstream, the ahead-behind and the change list are **one** command composed on the host, the way discovery is one pipeline and not three hundred stats. A screen that asks twice for one glance is the bug, not the milliseconds. One listing is one command — the whole directory with its types, sizes and times, never a stat per row — sorted directories first, dotfiles shown and the checkout's own `.git` hidden.

The header reads the machine-readable status rather than the human output, so a host in another locale answers the same, and a detached head reads as the short sha. A directory that is not a checkout says so in one line and keeps its shell.

**Struck:** polling. The sheet refreshes on entry, on a pull, and when it comes back from the terminal. A phone in a pocket asking a laptop for its status every five seconds is a battery bug wearing a feature's clothes.

**Struck:** blame, staging, commit, push, and every other verb that writes. The workspace reads; what writes is the shell one tap away on the toolbar.

**Struck:** editing, creating, renaming and deleting a file. The shell is better at all four; an editor here is a second, worse editor with no undo.

### Worktrees are derived, never registered

The siblings come off the checkout on screen, each with its branch, and picking one re-points the sheet at that worktree on the connection it already holds — without registering it, without a route push, and with the tree and the tabs starting over, because they were another checkout's. The one on screen is marked. Registration is unaffected: a worktree the user registers on purpose is another ordinary row, and one they never register is still reachable through its main checkout.

### Both fold states are the feature, and neither is the fallback

The outer display is where this phone spends most of its day, so the explorer has to be whole there — not a cramped view of a layout that only works open. The folded path is written and tested first and the split is added over it, so the two-pane layout can never be the one that works and the single column the one that was left behind. **A feature that only earns its keep unfolded does not land.**

The content cap every other screen keeps is lifted for this screen and no other, and the scaffold's static and the nav bar keep their rules. A fold mid-session narrows to the drawer layout with the tabs and the tree as they were, and unfolding restores the split.

### CODE is a segment of HOSTS and belongs to the app

HOSTS carries `[ MACHINES ]  [ CODE ]` under its title, drawn the way the PROJECTS switch was. MACHINES is the host list exactly as it is, with `ADD HOST` under it. CODE is the workspace list: every registered directory, one panel per host, `ADD` on the strip, `RE-POINT` and `REMOVE` on a long press, the workspace's sheet coming up on a tap. The switch is remembered for the session and HOSTS opens on MACHINES after a cold start. PROJECTS is the board alone and carries no switch.

The registered directories are the app's own, alongside the hosts they sit on. CODE draws without the Projects plugin: with Projects off, HOSTS still lists, registers, re-points, removes and opens every workspace, and disabling Projects withdraws the PROJECTS tab and the project link on a workspace, not the workspace. Projects keeps leasing the workspaces service for the `CODE` section of a project's detail, which is the only place the link is made from the project's side.

### Colouring is the app's own, on a vendored grammar engine

Code is coloured by `packages/dazzle_highlight`, a pure-Dart copy of the highlight.js engine vendored whole, with the plugin hooks, the language detection and the renderers cut out and thirty-two grammars kept: dart, javascript, typescript, go, rust, python, c, cpp, java, kotlin, scala, bash, shell, yaml, ini, json, sql, nix, lua, markdown, dockerfile, makefile, css, scss, xml, protobuf, graphql, properties, diff, http, nginx and plaintext. The language is the extension's or, for `Dockerfile`, `Makefile` and `nginx.conf`, the name's; a file the app has no grammar for is drawn plain, and nothing is ever guessed from the content. C#, Swift and Objective-C ship no grammar and draw plain.

Six colours and the muted text: keyword, type, string, number, comment, annotation, with punctuation in the muted text and everything the grammar cannot place in the line's own colour. A grammar that gives up part way through a file gives the whole file back plain rather than a coloured head over an uncoloured tail.

The diff colours a line on its own and never across two, since the line above a hunk line may not be the line above it in the file; the one guess made is that a line whose first mark is `*`, or that closes a block comment it did not open, is a comment whole. The explorer colours the file whole, so a block comment or a string that runs over a line break is coloured to where it ends. Above sixteen kilobytes the colouring runs on another isolate and the file draws plain until it lands; below, it draws coloured at once.

### The explorer is a sidebar beside an editor, not a list that turns into a file

The explorer is laid out the way an IDE is: a sidebar on the left holding the tree, an editor on the right holding the open files under a row of tabs. Nothing swaps a list for a file and back: the file stays open in its tab while the tree is looked at, and the tree keeps its shape while the file is read.

Unfolded, both are on screen at once, the sidebar holding the share of the width it was left at and the editor the rest. Folded, the editor is the screen and the sidebar is a drawer over it from the left: `FILES` at the head of the tab row opens it, and picking a file, tapping the ground beside it, `BACK` or the system back closes it again. The drawer is open when the explorer comes up with nothing to read, so on a phone the first thing seen is still the tree, and the last tab closing opens it again. A fold or an unfold mid-session changes the widths and nothing else: the tabs, the drawer and the tree's open directories are the same widgets at every width.

The tree expands in place. The root is open when the screen opens; a tap on a directory opens it and draws its entries under it, one step further in per level, and a second tap closes it. A listing is one command, asked the first time its directory is opened and kept for the screen's life. The `[ TREE ]  [ CHANGED ]` switch, the letters, the counts and the rows for deleted files are as ruled under the checkout's marks.

Every file opened is a tab and stays one until it is closed. A tab carries the file's name, the checkout's letter in its colour when it has one, and `×`; the tab on screen is in the accent with the underline the shell's tabs carry, the rest in the muted text. A tap on a file already open goes to its tab rather than reading it again, and a tab holds its text, colours and marks for the screen's life, so switching costs the host nothing. Closing the tab on screen moves to the one beside it. The tab row scrolls sideways once it is fuller than the screen, and the tab on screen is scrolled into view. Under the tabs the editor is a panel titled by the open file's path, with the changed file's strip and the file under it; with no tab open it says `OPEN A FILE`.

Over both is the sheet's own toolbar, and the explorer draws no header of its own: what says which checkout this is belongs to the sheet that holds it, not to the tree inside. The system back closes the drawer when it is open over a file, and leaves the sheet otherwise.

### The explorer marks each file row with a Nerd Font glyph

Every directory and every file in the tree carries a glyph before its name, from the Symbols Nerd Font Mono the app already carries for a shell prompt rather than the Dazzle vector set. This is the one place the house vectors are stood down, and it is stood down for now and not for good: `languageOf` alone names close to thirty grammars, and the set is borrowed until the vectors catch up with it.

A directory carries an open or a closed folder. A file carries the glyph of the language it is coloured by — dart, javascript, typescript, go, rust, python, c, cpp, java, kotlin, scala, bash, yaml, json, sql, nix, lua, markdown, dockerfile, makefile, css, scss, xml and graphql each their own, ini and properties the one config mark between them — and a file coloured plain, or in protobuf, diff, http or nginx, carries the same mark as one the app does not recognise at all. The word standing where a directory's entries are still coming, or never came, is not a file and carries no glyph; it holds the empty slot anyway, so it stands where the entries it stands in for will. CHANGED carries the same file glyph against each path it lists, so both halves of the switch read alike.

The glyph sits in the muted text, at the size a row's glyph slot has always drawn at, indented with the row it marks. That size is the slot's and not the reader's: the borrowed glyph is a full em wide where the app's own icons are drawn to fit, so one that answered a larger text size would be cut off at the slot's edge instead of growing with the name beside it.

### The seam between the tree and the file is the user's to move

How wide the tree should be is a reading decision and not a layout constant: a checkout of long paths wants more of the screen, a file of long lines wants less, and which of those is true today is the user's to say and nobody else's. So the seam is a grip, and the grip is dragged. Beside the editor the grip is the gap between the two panes; over the editor it is the drawer's own right edge. A short hairline down the middle of it is what says it can be taken, and the panes follow the finger as it moves.

What is kept is the share of the width and not a count of points, so a seam left at a third of one screen is a third of the next. The sidebar keeps its own share and the drawer keeps another, because a pane the editor sits beside and a drawer that lies over the top of it are not the same width: a drawer as narrow as a sidebar hides the tree it is there to show, and a sidebar as wide as a drawer leaves nothing to read beside it. Neither is dragged to an end where the other is gone. The sidebar holds between a fifth and seven tenths of the width beside the editor, and the drawer between a half and nine tenths over it, the far end being what keeps the strip of the file in view that says it is still open underneath.

The share is written down when the finger lifts and not on every frame of the drag, and it is one share for every workspace on every host, since it is how the user reads and not a property of a checkout. It outlives the screen and the app: the explorer comes up at the width it was left at.

### The checkout's changes are marked where the file is, not only listed

The explorer's FILES panel carries `[ TREE ]  [ CHANGED ]` under its title, and CHANGED carries the count while there is one. TREE is the directory as it is, with the checkout's word on each row: a changed file carries its letter where its size was — `M`, `A`, `D`, `R`, `?`, `!` — in the warning for modified and renamed, the accent for added and untracked, danger for deleted and conflicted; a directory carries the count of changes under it, in the warning; a file deleted in a directory that is open is a row under it still, muted, with its `D`, and a tap on it opens its hunks in the diff sheet since there is nothing left to read. CHANGED is the workspace screen's list flat: every changed file by its path from the root, its letter, and its `+n −n`; a tap opens the file, or the diff for a file that is gone. Both follow REFRESH on the screen behind, and neither asks the host anything the screen behind did not.

The viewer has a gutter: the line's number in the muted text, and between the number and the line a bar three pixels wide that is the accent down a line that is new, the warning down a line that replaced one or more, and a thin line of danger along the top of the line that now sits where lines were taken out — on the last line, when they were the last. The marks are read off the file's own hunks against `HEAD`, asked for once when the file opens, alongside the colouring; a file the checkout has no word on has numbers and no marks, an untracked file is all new and gets none rather than a bar the length of the file, and a binary one is never diffed.

Under the editor's tabs, on a changed file, one line: `N CHANGES` in the letter's colour, or `UNTRACKED`, then three marks at the right of it — an arrow up and an arrow down that walk the changes and wrap at either end, and a plus over a minus that opens the diff sheet on this file. They are marks and not words: a glyph says what an arrow says, where three words in the mono take a third of a line that is one line tall, and each mark is a finger wide where a word is only as wide as it reads. Each carries `PREV`, `NEXT` or `DIFF` on its node, so a screen reader still has the verb. A run of neighbouring marked lines is one change and `N` counts those and not the lines: a block of forty new lines is one place in the file, so the walk stops once at the head of it rather than forty times inside it, and the count is the number of stops the walk has. Nothing in CODE writes to the checkout: status, listing, contents and hunks are the whole of what it asks, and nothing on the explorer or its sheet stages, discards, commits or edits.

### The workspace is a sheet that comes up on the tree, not a page in front of it

A tap on a workspace opens the explorer, and it opens it directly: one tap from the list to the tree, with no screen in between whose whole job was to offer a `BROWSE` row. The detail page is gone. What it held that is worth keeping was already somewhere else or belongs on the toolbar — the change list is the explorer's own CHANGED, the history is one step behind any file's diff, and the branch, the worktrees and the shell are the toolbar's three cells.

It is a sheet and not a screen, for the reason the terminal is: a checkout is looked at beside something else, and the thing behind it is why it was opened. It is the shell sheet's own shape and its own mechanics — parked at the bottom, as tall as the window under the status bar, a grip at the top edge that drags it down, and a scrim, a fling or the system back to leave — so the two modals of this app open, feel and close alike, and the code the terminal already had for that is the code this sheet uses rather than a second copy of it. One sheet per navigator: tapping the workspace that is already up brings that sheet back instead of stacking another.

The sheet holds the connection for its own life, one dial, and it says so while it is dialling: the toolbar is drawn at once with what it already knows, and the body says it is connecting under it. A dial that fails says why in one line with `RETRY` beside it, and the toolbar stays on the row so the shell is still reachable on a host whose checkout would not answer. Nothing under the sheet is asked for until the connection is up — a tree that asks while there is nobody to ask marks its own root as failed and then has to be told to try again.

The last row inside the sheet stops short of the phone's own gesture bar by the system's inset and the house gap over it. A sheet that runs to the bottom edge of the glass puts its last row under the bar that swipes it away.

### The sheet's toolbar says where this is, what it is on, and how to get a shell at it

Inside the sheet, under its grip and over the explorer, one row of the terminal header's height, bordered like it and holding four things between the screen edges.

The workspace's name at the left, in the panel header, elided rather than allowed to push the rest off the row. Then the branch, in the mono, with the tracking beside it when there is an upstream ahead or behind — the cell is the swapper: a tap opens a picker of every worktree of this checkout, each under its own branch, the one on screen marked, and a pick re-points the sheet at that worktree on the connection it already holds. Nothing is pushed and nothing is registered, and the tree, the tabs and the open directories start over, because they were another checkout's. A directory that is not a checkout draws the cell dimmed and answers nothing.

Then the shell, which opens the terminal's sheet on this host already standing in this directory, over this one — a shell at the checkout in one tap from the file being read, which is the whole point of putting it on the row. Leaving the terminal leaves the explorer where it was. Then `×`, which is what the terminal's header closes with.

`REFRESH` is not on the toolbar: what it refreshes is the tree and the marks, so it is the FILES panel's own affordance, beside the `[ TREE ]  [ CHANGED ]` switch it redraws.

### The diff is one viewer, reached from the terminal's header and from the workspace

The header over every terminal carries a version-control mark between the tab strip and the state word — a branch, in the house's own icons, because a row that already holds nine tabs cannot spend four letters on a word. A tap opens the diff on the repository the tab is standing in, so a shell that has just been worked in is one tap from what that work changed. Standing anywhere that is not a checkout, the mark is dimmed and answers nothing: a phone that says `NOT A CHECKOUT` after a tap has spent the tap saying what it already knew.

Which repository that is: the one the shell is standing in, and the app finds that out for itself. Every tab's shell is marked with a variable of its own as it is dialled, and the mark survives the `exec` into the login shell, so the host can be asked which of its processes this tab is. The tap asks — on a second channel of the connection the tab already holds, which the shell on the pty never sees — and reads that process's own working directory off the host. A `cd` typed a second ago is already in the answer, because the answer is the shell's directory and not a copy of it.

The topmost marked process is the tab's shell: everything it starts inherits the mark, and the directory a `vim` is standing in is not the directory the shell is standing in.

A tab that holds the multiplexer is asked of the multiplexer instead, and asked first. What such a tab runs is a client — one pane's attach, or the whole session — and a client stands where it was started for as long as it lives; the shell that has been walked around in belongs to the session on the host, and is no relation of anything this connection started. The same walk finds it: a marked process running the multiplexer names the session it is on, in its environment or on its own command line. A tab attached to one pane is asked for that pane; a tab holding a session is asked for the pane that session has focused, which is the pane the user is looking at. Either way what is taken is the pane shell's own directory and not the foreground program's, for the reason a `vim` is left out above.

The directory is then asked for its repository rather than read as one. The checkout it is inside is what the viewer opens, so a shell three directories deep opens the whole repository instead of a corner of it, and a shell inside no checkout at all is what leaves the mark dimmed.

Three things under it, in order, for a shell that cannot be found — a host that does not keep its processes where Linux keeps them, a tab dialled before it was marked, a connection that has dropped. The escape sequence a shell emits beside its prompt, `file://<host>/<path>`, for a host that has that configured; then the directory the tab was opened at; then the registered directories on that host, one opening straight away and several a pick. The cell is on the row whenever any of them can answer, and a live tab always can: a shell is always standing somewhere.

Struck: asking the user which directory a terminal is in. The terminal knows and the host knows, and a phone that has to be told is not offering much.

**The viewer is a sheet.** The app's modal shape — a panel parked at the bottom of the screen over a dimmed terminal — and not a screen of its own: what is behind it is the context the diff is being read against, and a diff read on a phone is read once and dismissed. It carries no `BACK` and no `REFRESH`. Out is the scrim or the phone's own back, which steps out of a file before it steps out of the sheet, and what is on it was read when it opened. The workspace's change list opens the same sheet at the file that was tapped. There is no second diff surface in the app.

**It is on the screen before the answer is.** The tap opens the sheet, not the round trip that fills it. The mark was lit by a checkout the app had already asked for, so there is nothing left to find out before the sheet can come up; what it does not have yet it says it does not have, `loading` where the subject goes and on the strip of every list, and it fills in underneath as the host answers. A modal that waits on a phone's radio before it draws is a tap that did nothing, and the user taps again.

**Both lists open folded.** `CHANGES` and `COMMITS` are a header strip each when the sheet comes up, each carrying its own count, and the sheet is only as tall as what is unfolded. A diff on a phone is read one file at a time, and two lists of rows over it are the wall between the user and the thing they opened. Unfolding one leaves the other where it is, and picking a file folds both again: which of the three is worth the screen is the user's to say, and the sheet says nothing about it until they have.

**Two panes.** A list beside the hunks, two fifths and the rest: folded with nothing picked the list is the screen, folded with a file picked the hunks are, unfolded both are drawn. One tree at every width, so unfolding the phone never throws away the commit the user had walked to.

**The list is `COMMITS` over `CHANGES`.** The commits are `git log` — the short sha, the subject, the author and how long ago — and the working tree sits above them as a row of its own, which is the row the viewer opens on. Tapping a commit points the whole screen at it: the `CHANGES` panel becomes that commit's files and the hunks become that commit's hunks. The working-tree row carries the dirty count, a commit row carries nothing, and whichever is the source is drawn in `accent`.

**The head line.** Over both panes: the subject of the commit on screen, or `WORKING TREE` when that is the source, then the branch, the short sha and `+n −n` across every file of the source. It is the line the eye lands on and it says what is being read.

**The hunks are coloured by syntax, under the diff's own two colours.** The ground and the glyph still say which side of a change a line is on; the syntax colours the text inside it and never the ground. The language comes from the file's extension and from nothing else, and a line is read on its own: a hunk is not a file, the lines above a line may not be the lines above it in the file, and a highlighter that carries a guess across a hunk boundary is a highlighter that lies. What it cannot place it leaves the colour the line already had, which is the colour the whole line used to be.

**History is read, in one round trip each.** `git log` for the list, `git show --numstat` and `--name-status` composed into one command for a commit's files, `git show` for every file's hunks at once and `git show -- <path>` for a file that answer was cut before reaching — all `--no-color`, all under the same `sh -c` budget the workspace already keeps, all on the connection the screen already holds. Nothing here writes, and nothing here checks anything out: reading a commit does not move `HEAD`, and the verbs still live in the shell.

Struck: a file tree in the viewer, and a way to open a commit's file at its full text. The explorer is one row away on the workspace screen and it already does both.

### The whole diff comes back at once, and the walk under it spends nothing

The viewer asked the host for one file's hunks every time a row was tapped. A commit of twenty files was twenty commands, which on a radio is twenty handshakes' worth of latency paid one at a time by the user walking the list — and the workspace was built on the opposite rule from its first command: what a machine on the other side of a phone's radio charges for is the round trip and not the bytes, so one user action is one command and a screen wanting three answers asks for them together. The viewer was the one surface that had not been written that way, and no amount of work on how the lines are drawn would have fixed a screen whose problem was that it was waiting.

So the hunks of everything that changed come back with the list. `git diff --no-color HEAD` for the working tree and `git show --first-parent --format=` for a commit: one command for the whole source, split by file on the way in and held for as long as that source is the source. A tap after that asks the host nothing and the file goes up in the frame the row was tapped in, which is the speed a list has to answer at to be walked at all.

**The cap is on the answer, not on the file.** Half a megabyte, taken with `head`, which counts bytes and will cut a line in half. What the cap was is carried back to the reader, so it knows the last file of a full answer is however much of one there was room for, and it drops that file rather than drawing a fraction of it as though it were the whole. A file the answer did not reach is then asked for by name on the command the viewer has always had — and so is an untracked file, which `diff` never names and which is read against nothing.

**The walk is under the lines.** `PREV` and `NEXT` step through the change list in the order it is drawn, `HUNK` goes to the next hunk header and wraps at the end of the file, and beside them the count says which of how many files is open. They sit below the hunks and not on the strip above them, because a file is read to its end and the way out of it has to still be under the thumb when it gets there. A step with nowhere to go is drawn dimmed rather than dropped: a row of verbs that changes width as it is used has to be read again every time it is used.

**Nothing wraps, so the rows are built as they are reached.** A wrapped line stops being the line that is in the file, which was already the rule, and it has a second consequence: every row is exactly one line box tall and the widest row is the longest line times one character's advance in a face that is monospaced. Both of those are arithmetic. A file used to be laid out entire and twice — once to be measured for a width, once to be drawn — before the first line of it appeared; now the rows on the screen are the rows that exist, the width is computed from the text rather than from the widgets, and the position of any line is a multiplication, which is what `HUNK` jumps by.

Struck: staging, now that the diff is cheap enough to redraw after one. The round trip was never what stood in the way — a workspace is read from the phone and changed from the shell, and a `git add -p` whose hunks are tapped instead of typed is a second and worse porcelain sitting one row from the real one.

### The numbers hold still while the line goes past the right edge

A phone is narrower than the lines people write, and the viewer answered that with a scroller around the whole pane — the browser's answer, and the wrong one on a screen this size. What leaves the screen first when the pane is dragged left is the lead: the number the line had before, the number it has now, and the marker between them. A reader who follows a long line to its end arrives with nothing left on screen to say whether they are reading what was there or what replaced it, and the way back to that is to drag the whole file right again.

**Only the text moves.** The lead is laid out where it always was and stays there; the text beside it is pushed left under a clip. The pane keeps one position, and the text of every row on screen reads it, so a drag repaints those lines and lays nothing out a second time — the same arithmetic that let the rows be built lazily in the first place. The ground behind an added or a removed line is painted across the row, lead included, so the colour that says which side the line is on never scrolls away either.

**Across and down are the same thumb.** The drag across is offered beside the list's drag down and the two are told apart by the direction the gesture started in, which is what the list does already with every other scroller in the app. The text stops where the longest line in the file ends: a pane that keeps going into empty space says the file does, and this one does not.

**A rail under the text admits the line goes on.** The scroller that used to say so is gone and a diff is one of the few places where how much is off the edge is worth knowing before deciding to go and read it. It is a hairline, it starts where the text starts rather than at the edge of the pane, and its thumb is as much of the rail as the pane is of the line. It is drawn only when there is somewhere to go.

**A tab is drawn as wide as it is counted.** The face draws one for a single advance and the pane was counting it as eight, which left a file indented with tabs both mismeasured and flattened — the shape that says what sits inside what, gone. Every tab is opened out to the next eight-column stop before anything else looks at the line, so the width, the marked run and the reader are all counting the same characters. Eight is git's own stop, and the count the pane had already committed to.

**Every file opens at the left margin.** Where a reader had got to in one file is not where the next one begins, and a file that opens in the middle of a line nobody has read is a worse offer than one that opens at its start.

Struck: shrinking the face until the longest line fits. A diff read at six points is not read, and the face is the app's own decision rather than a slider.

### The line says which of its words changed

A row painted green says the line is in the file now and a row painted red says it was, which for a line edited in one place leaves the reader comparing two nearly identical strings by eye to find the place. The viewer marks it instead: the run of the line that its partner does not have carries the row's own hue at a weight the ground does not, so the port number, the renamed call, the flipped flag reads at a glance and the rest of the line stays ordinary text.

**A pair is only a pair when the counts agree.** git hands over the removed lines and then the added ones and never says which replaced which. When the two blocks are the same length they are read in order, one against one. When they are not, nothing further is claimed — the rows keep their ground and no run is marked, because the alternative is pointing confidently at a line that was never the other one's version.

**A word is marked whole.** `port` against `ports` share three letters and marking the `s` alone is true and useless; the run is widened at both ends to the edges of the words it opens and closes inside. Two lines that share almost nothing are left alone for the same reason: whatever characters they have in common coincided rather than survived.

**The colours are two cuts of one line, not two coats.** The run that changed and the runs the highlighter found are decided separately and the line is cut at both, so a marked span keeps whatever colour its syntax gave it. The mark is a ground behind the text and never the text's own colour, which belongs to what the word is rather than to when it arrived.

Struck: pairing lines across a block by how alike they are. It finds the right partner more often than counting does and it is a guess either way; a rule the reader can hold — same many out, same many in — is worth more on a phone than a better average.

### A file says where its changes are before the thumb goes looking

A diff is mostly a file that did not change. The pane offered one way through that — the walk to the next hunk, which lands on a header and says nothing about how many headers there are, how far apart they sit, or whether the one being read is the first or the last. So a long file is a fling and a guess, and the guess is expensive: overshoot the hunk and the context that explained it is gone.

**The strip stands for the file, not for the view.** Down the right edge of the pane, as tall as the pane and as long as the file: every added line is a mark in the accent and every removed one a mark in the red, each at the share of the file it sits at. Neighbours of one kind are one mark, because forty removed lines in a row are one place to go and not forty, and a mark is never thinner than a thumb can be aimed at — a single changed line in four thousand is the case the strip exists for.

**What is on screen is a window on the strip.** The rows being drawn are lit across the strip's whole width, and that block moves as the pane moves. It is the only thing in the pane that says where in the file the reader is; the numbers say which lines, which is a different question once a file is long enough to need this.

**A touch on the strip is a jump, and holding it is a scrub.** What is touched arrives in the middle of the pane rather than at its top, so a mark landed on comes with the lines that led to it. The walk to the next hunk stays: it is the same movement without having to aim, and the strip is what makes it legible.

**A file with nowhere to go has no strip.** One that fits on the screen, and one with nothing added or removed, would both get a strip that only repeats what the eye already has, so the pane keeps the width for the text instead. The rail under the text stops where the text stops rather than running on beneath it.

Struck: drawing the file's own lines into the strip, the way a desktop editor does. At this width a line of code is a smear a few pixels long and the colour of whatever the highlighter decided, which is noise laid over the one signal the strip is for. The strip says where, and the pane says what.

### The hunk being read says so from the top of the pane

Git writes the two ranges and the enclosing symbol into every hunk header, and the pane draws it as a row like any other. A hunk of sixty lines then means that row leaves the screen long before the hunk does, and forty lines in there is nothing left saying which hunk this is, which function it is inside, or that the reader has not already crossed into the next one.

**The header of the hunk being read is held at the top of the pane.** It is the same row the pane would have drawn, on its own ground so the code passes underneath, and it is ruled off along its bottom edge. The rule is the difference between the two things the row can mean: inline it says a range begins here, held it says the reader is somewhere inside one that began above, and without it a hunk appears to start at whatever line happens to be under it. It appears the moment the top edge starts cutting the real row and not before: a header still on the screen has no need to be stood in for.

**The next header pushes the held one off.** As the following hunk arrives it takes the top of the pane by driving the one above it out, so there is never a header sitting on a header, and the changeover is a thing the eye can see rather than a swap between frames.

**The held header is the way back to where the hunk began.** A touch on it puts its own row back at the top, which is the reading the walk to the next hunk cannot offer: the walk only ever goes forward, and the question a reader forty lines deep actually has is what the lines above were.

**It travels with the text.** Pushed sideways the held header moves with the lines under it, for the same reason the numbers and the marker do not: it is part of the text of the file and not a label on the pane.

Struck: folding the context between hunks away behind a count. A diff arrives with three lines of context around each change, so there is nothing between hunks worth folding, and a fold would hide the one thing the reader came to the context for.

### A hunk header leads with what the lines are inside

Git writes a hunk header coordinates first and symbol last, which is the right
order for a terminal eighty columns wide and the wrong one for a phone. The
half that says what the reader is looking at — the class or the function the
hunk falls inside — is the half that goes off the right edge, and the half that
survives is a pair of ranges the gutter is already carrying line by line.

**The symbol comes first and the ranges follow it.** What is left on the screen
when the header runs out of width is then the part worth reading, and the
coordinates are a drag away for anyone who wants them. Nothing is dropped: a
header is reordered, not rewritten, and the ranges keep their own marks so it
is still visibly git's line and not the app's.

**A header git found no symbol for is left exactly as it came.** Small files,
and hunks at the top of a file, have nothing but their ranges, and a header of
nothing but coordinates is already leading with the only thing it has.

Struck: dropping the ranges once the symbol is there. They are how a diff is
matched to a file that has moved on since it was read, and the pane is not
entitled to decide that nobody will need them.

### A line is taken out of the diff by holding it

Everything the diff pane does is a movement. The walk goes to the next change,
the strip goes to a place in the file, the drag goes sideways, the held header
goes back to where the hunk began. What a reader wants a diff for and cannot
get from any of them is the line itself: a path, a symbol, the string an error
was raised with, on its way into the terminal in the panel behind the sheet.

**A long press takes hold of the line under it.** The line is marked down its
left edge and not across it: a diff row is drawn over four grounds, two of
which are the added and removed colours, and a wash over the row would either
lose to them or bury them. The mark is the accent at the one width the palette
allows the accent — a rule beside the line, not a surface.

**The bar under the pane becomes the verbs for the line held.** The walk gives
its place up to COPY and LET GO, and says which line is held, because the pane
is already full of the file and a bar that was showing movements has nothing to
say while the reader has stopped moving. It is the terminal's idiom: something
is taken hold of, a verb appears for it, and the verb spends the hold.

**A line that was removed is named as the old file's.** Its number is where it
sat before the change, and the line that replaced it carries that same number
after, so a reader holding one and then the other would be shown the same
number twice for two different lines. The removed one says `WAS LINE 1`. The
tense is the whole of the difference and it is the only part a reader needs:
one of those numbers can be typed into an editor and the other cannot.

**What is copied is the line the file has.** Not the line the pane drew: the
tabs are the file's tabs and not the columns they were opened out into, and a
hunk header goes to the clipboard in git's own order rather than the order the
pane reads it in. A line pasted into a terminal has to be the line, or the
copy was worse than no copy at all.

**Putting the file down lets go of it.** Walking back to the changes, opening
another file, closing the sheet — a hold belongs to the file it was taken in,
and outliving it would leave a verb on screen for a line nobody can see.

Struck: a confirmation that the copy happened. The hold ending is one answer
and it is the one the terminal already gives, and the phone gives another of
its own: the system draws a preview of what went to the clipboard. A third
notice for one action would be the app talking over both of them.

Struck: dragging the hold across several lines. Both axes of the pane are
already spoken for — down the file and across it — and a third gesture on top
of them would have to be disambiguated from both. The thing a reader reaches
into a diff on a phone to take out is one line.

### A jump keeps the place it took the reader from

The pane moves three ways the thumb never touched: a tap on the strip, the
walk to the next hunk, a touch on the held header. Each of them is one step,
and a step is the movement that can be wrong — a thumb aimed at a strip
sixteen pixels wide is aiming at a whole file, and the walk lands wherever
the next header happens to be. What it costs is the same every time: the
scroll that got the reader to where they were is spent, and a long file
gives it back only as a fling and a guess.

**Every movement the reader's thumb did not make keeps where it began.** One
place behind the pane and not a trail of them: the jump that is worth
undoing is the one just taken, and a history of jumps is a second thing to
navigate inside the thing being navigated.

**A scrub is one movement, however many jumps it arrives as, and it begins
where the finger landed.** Every frame of a drag down the strip is another
jump, and each one after the first begins where the frame before it left the
pane; kept per frame, the way back would point at the last place the scrub
passed through. It is owed to where the reader was sitting when they reached
for the strip, which is the offset under the finger the moment it touched
down and not the one the pane holds by the time a drag has been told apart
from a tap.

**The way back is offered as the line it goes to.** A cell in the corner of
the pane carrying the number the gutter had there, so it says where it lands
and not only that it lands somewhere. It is the number and not an arrow
because the terminal's way back has one destination and always the same one,
and this one points somewhere new every time it appears.

**It stands in the corner the strip is not in.** Bottom left: the pane's
right edge is the strip, and a cell over the bottom of it would take the
touches aimed at the end of the file.

**A jump that landed within a pane of where it began left nothing behind.**
The lines it came from are still on the screen, and offering a way back to
something the reader can already see is offering to move them for nothing.

**It is read from where the pane is, never set and never cleared.** A reader
who scrolls back by hand arrives without taking it, and it goes when they
get there because it is a reading of the distance and not a mark left behind
by the jump. Nothing about it can go stale, which is the property that lets
it live in a corner nobody is looking at.

**It rides back where the jump jumped.** The jump was asked for and its end
is recognised by whoever asked; the return has to be recognised as a return,
and a pane that arrives already somewhere else says nothing about where it
came from.

Struck: a stack of the jumps behind the last one. The pane would then carry
a history whose own shape has to be shown and moved through, and the reader
who wanted the previous four places has a scrollbar and a strip for exactly
that.

Struck: a mark the reader sets on a line by hand. It is a second kind of
place to keep, set by an action that has to be learned and cleared by
another, and the case it answers — go back to what I was reading — is
already answered by the jump that took them away from it.

## System

### SYS is a door on Home, not a destination in the nav

The nav has four labels and gains no fifth for settings. The door is a `SYS` breadcrumb action on Home, in the same slot and style as a project's `EDIT`, pushing a `SETTINGS` route with no nav bar under the crumb `DAZZLE / SYS`. Its blocks, top to bottom, are `[ STATIC ]`, `[ ALERTS ]`, `[ BUNDLE ]`, `[ THEME ]` and `[ BUILD ]`. Hosts and keys are not among them: they have a tab of their own, and the rule that a host needs a key lives in the host form.

**`[ STATIC ]`** is `ON` / `OFF` as a two-row picker with the block on the active one, persisted in a `settings` key-value table. OFF draws the noise tile once, unmoving, which is the same path the thermal throttle takes.

**`[ ALERTS ]`** is one row, `BLOCKED AGENTS`, with a toggle. Turning it on asks the OS for notification permission; refused, the toggle stays off and the subtitle reads `NOTIFICATIONS DENIED`. With no host on the agent integration the row is dim, subtitle `NO HOST`, and the toggle does nothing. The setting survives a launch. This row is the whole of what lets the app hold a connection open while it is not in front — with it off, the app opens nothing in the background, ever.

**`[ BUILD ]`** is the last line, mono 11 `--fg-dim`: `v<version> (<versionCode>) <short sha>`, the sha injected at build time and reading `dev` when it is absent.

### A bundle carries the phone to another phone

There is no backend of the app's own anywhere in this, so the transport is a file the user holds and the file is the whole of it: a second phone, or the same phone after a reset, comes up on the same hosts with the same keys. Every key row travels and, with it, the private key out of the keystore — the one thing that never leaves the phone, and the one thing without which the other phone cannot dial. Every host travels with all its columns: the pinned host key, so the second phone trusts what the first already verified instead of meeting the machine cold, and the VNC password, which is a host secret like the private key is. Every integration switch travels, and every registered directory with its label.

### A passphrase seals it, and the envelope says what it is

Private keys travel in the file, so the file is ciphertext. The passphrase goes through Argon2id — 64 MiB, three passes, one lane, a 16-byte random salt — to a 32-byte key, and the JSON payload goes under NaCl's secretbox, XSalsa20-Poly1305 with a 24-byte random nonce, under that key. **The envelope is JSON, so a curious `cat` says what it is**: a marker, a version, the KDF's name and parameters, salt, nonce and box in base64. On the way in the envelope's own parameters drive the derivation, so a later default does not orphan an older file; a memory parameter above 256 MiB is refused rather than obeyed.

A wrong passphrase is exactly what a tampered box is — the tag fails — and it is named `WRONG PASSPHRASE`, on the assumption that the user typed rather than that somebody edited. A file without the marker is `NOT A BUNDLE`; a version the app does not know is `NEWER BUNDLE`. The derivation runs off the UI isolate and the bar reads `SEALING` or `OPENING` for the second or two it takes.

**Nothing of the app's decides where the file lives.** `EXPORT` raises the system's create-document picker with a name of `dazzle-<date>.bundle` and `IMPORT` its open-document picker, the bytes going through the device channel. A picker dismissed is nothing happening, and there is no line for it. A platform without a picker — the desktop dev loop, the test harness — says `NO PICKER` and stops.

### The panel is on SYS, and an import says what it holds before it lands

`[ BUNDLE ]` sits between the alerts and the build stamp, because a phone's whole set leaving or arriving is a system act and not a row beside the hosts. It carries two text actions. `EXPORT` asks the passphrase twice on a sheet titled `EXPORT BUNDLE`, two obscured fields under `[ PASSPHRASE ]` and `[ AGAIN ]`, the bar naming what is missing the way the host form does — `PASSPHRASE MISSING`, `PASSPHRASES DIFFER` — and reading `SEAL` when nothing is. `IMPORT` opens the picker first, asks the passphrase once on `IMPORT BUNDLE`, and **only after the box opens** raises a confirm that counts what is in it — `2 HOSTS · 1 KEY · 5 PATHS` — with `IMPORT` filled in the accent, so the user sees what they are about to take before anything is written. The panel keeps the last outcome as a row: `EXPORTED 2 HOSTS · 1 KEY · 5 PATHS`, `IMPORTED …`, or the failure word in the danger colour.

### Import merges by id and deletes nothing

A row the phone already has under the same id is replaced by the bundle's; one it does not have is added; one the phone has and the bundle does not is left alone. A host's integrations become the bundle's set for that host. **A host whose key is neither in the bundle nor on the phone could never dial**, so the whole import is refused as `BUNDLE INCOMPLETE` rather than landing half. Private keys are written to the keystore first and then the rows in one transaction: a private key with no row is inert, while a row with no private key is a host that cannot dial. Running the same file in twice is the same phone as running it once.

### The bundle carries the whole phone

An application id is what Android calls an app, so a rename is a second app: its own sandbox, its own database file and none of the rows. The old app cannot be read from outside either — a release build carries no debuggable flag, so `run-as` is refused, and the platform's own backup has been inert for four major versions. The only door out of an app nobody can open is the door the app itself offers, and that door is the bundle.

**So the bundle is not a curated set, it is the phone.** Hosts, keys and paths are not the line: the rest is a user's work, and a bundle that leaves it behind is a bundle that loses it the first time an app is reinstalled under another name. Every table travels: projects, goals, tasks, links, attachments, notes, activity, settings, dispatches and shell tabs beside the four curated ones. A path carries its project id, because the project it points at is in the file with it and a link that would otherwise be dangling by definition is a link that resolves.

**The ten new tables travel as rows, not as domain objects.** The curated four are mapped by hand because they are assembled out of the keystore and three repositories and cannot be read off a table. The rest are read column for column and written back the same way, under the names sqlite knows them by. A migration that curates is a migration that loses: a repository would apply its own rules on the way in — the one `isNext` item, the reasons a delete is refused — and the phone that arrives would differ from the phone that left in ways nobody asked for. The dump is the whole row and the restore replaces by primary key, so running the same file in twice is still the same phone as running it once.

**An image attachment is a file, and the file goes too.** A row of kind `image` holds a path relative to the app support directory, which is inside the sandbox the new app does not have. The bytes ride in the bundle under that same relative path and are written back before the rows, so an attachment is never a row pointing at nothing. An image already on the phone is left as it is: the bytes are content, and the same relative path is the same picture.

**The envelope answers to both names.** A file sealed by the app under an older name opens under this one: the marker key is read as either `spectacle` or `dazzle` and written as `dazzle`. This is the whole point — the file a user has to import was written by the app they are leaving. A bundle that only the new app could have written would not have reached them.

**The panel counts what is in the file.** `2 HOSTS · 1 KEY · 5 PATHS` grows a tail for everything else — `· 312 ROWS`, and `· 4 IMAGES` when any ride along — on the outcome row and in the confirm before an import, so the user sees the size of what they are about to take.

## Theme

### One token read path carries every colour and text role

`DazzleTokens` is a theme extension holding every colour the app draws with — the palette, the syntax palette, the terminal palette, and the washes, grounds and scrims a screen used to reach for as a literal — and every text role. A component reaches it through its `BuildContext`, never through a constant directly. Geometry — spacing, radii, icon sizes, tap targets, bar sizes — is not a token: it does not move with the theme and stays the plain constants it always was.

`DazzleTokens.house` is the default, built from the same values the app has always shipped, so registering it changes nothing on screen. A different `DazzleTokens` instance is what makes a theme; nothing else does.

### No colour or text style lives outside the design layer

A feature reaches `context.tokens` for every colour and text role it draws with; it never reaches for the palette or text-role constants directly, and never writes a colour as a literal. A painter or a route with no `BuildContext` of its own takes the colour resolved by the widget that owns it, carried in as a plain field. Where nothing is meant to be painted, the app says so directly — a null colour, a `BorderSide.none` — rather than reaching for a transparent one.

### `[ THEME ]` lets the phone's own colour scheme replace the house palette

SETTINGS carries a `[ THEME ]` row with two states, HOUSE and SYSTEM. HOUSE is the default and is the fixed palette every other ruling in this document assumes. SYSTEM resolves a `DazzleTokens` instance from the platform's own colour scheme: Material You's tonal palette where the device offers one, a scheme seeded from the house accent and the platform's own light or dark brightness otherwise. Choosing SYSTEM never touches the syntax palette, the terminal's ANSI table or the diff grounds — those read code and diffs, not chrome, and stay the house's regardless of the row.

The running app rebuilds its theme the moment the row is written, on the same screen and on every other, the way `[ STATIC ]` already does. The status and navigation bar icon brightness follows the resolved theme's own brightness rather than a value fixed at house-dark.

## Plugins

### Plugins run on the phone through declared capabilities

Plugins contain Luau source and a `dazzle.plugin.toml` at the repository root. Dazzle bundles the compiler and interpreter. Scripts run in a worker isolate, in separate Lua states, and receive only the APIs their manifest declares and the user grants. Native libraries, arbitrary filesystem access, network access and shell execution are not script globals.

The API exposes named manual actions and dataset handles. A selected record is an invocation-scoped dataset binding, not a feature-specific runtime API. Reading it returns its key, text value and revision. Updating it produces a proposal shown with `APPLY` and `DISCARD`; the originating feature adapter checks that the record has not changed before applying it. The plugin engine does not name individual built-in features.

SYS has a `PLUGINS` panel containing the real built-in Drops and Projects plugins. They are bundled but disabled on a fresh installation. An existing installation adopts both as enabled once, preserving the features already in use; subsequent user choices survive upgrades and restarts. No example installer or demonstration action is exposed in the product. `ADD` accepts a public GitHub repository and a ref: a full commit SHA, a tag or a branch name. Dazzle fetches the root manifest and its declared files at that revision, then displays the release, manifest schema, required API version, dependencies and each requested capability before `INSTALL`. A revision's files and manifest are retained together with their digest and grants. Updating requires reviewing the new revision. Removing a repository plugin removes its registration; it leaves existing records and prior plugin files intact. Built-in plugins can be disabled, not removed from the application bundle.

### A plugin package can span several files

A repository plugin's manifest can declare extra Luau files alongside its entry, each a relative path inside the repository. A path outside the package, an absolute path, a duplicate or a path shadowing the entry is rejected before any network call, and the declared count and total size are bounded. Dazzle fetches every declared file at the pinned revision alongside the manifest and the entry, and retains them all together under the revision; the retained digest covers the manifest and every file, not the entry alone. The entry can `require` a declared file by its path without the `.luau` suffix. A required module resolves only inside the retained package: no filesystem access and no network access from `require`, and resolution rejects an undeclared path, a require cycle and runaway nesting depth. The multi-file format carries everything the UI-capable format does: a page or widget contribution and host capabilities declare the same way, alongside the extra files.

### A ref resolves to the commit it pins

The `ADD` and `UPDATE` ref field takes a full commit SHA, a tag or a branch name. Dazzle resolves a tag or branch name to its commit SHA through the public GitHub REST API before fetching anything, unauthenticated; a full SHA needs no resolution. The manifest and every declared file are then fetched and retained by that resolved SHA, never by the ref that named it, so a moving branch or a retagged release cannot change what an installed revision contains. `UPDATE` additionally offers the repository's latest revision with one tap: the tag of its latest published release, or its default branch when it has no releases. The offered revision is fetched and reviewed exactly like a manually entered one before `INSTALL` replaces the running revision.

### A manifest can list itself for the person installing it

A manifest can declare an author, a homepage, a license and a short summary, each optional and bounded. Dazzle shows every declared one in the review sheet before `INSTALL` and in the installed plugin's detail view; an undeclared one is omitted rather than shown empty. None of the four carries runtime meaning: they do not affect a plugin's capabilities, dependencies, compatibility or execution, and a manifest lacking all four remains as valid as one declaring all of them.

### A marketplace index lists installable plugins

An index is a `dazzle.index.toml` at the root of a public GitHub repository, fetched at a ref exactly like a plugin: a full commit SHA, a tag or a branch name, resolved through the same unauthenticated GitHub REST API before the index file itself is downloaded and size-bounded. The index root carries its own format version, separate from a manifest's; an index declaring anything but the version Dazzle understands rejects with a version mismatch instead of an unknown-field error. Its `[[plugins]]` entries each declare an id, a repository, a ref, and the same optional author and summary a manifest can declare; an unknown field or a duplicate id rejects the whole index. An entry is a pointer, not a package: none of its fields is trusted beyond shape until the plugin it names is itself fetched and reviewed through the existing install flow.

Settings PLUGINS gains SOURCES and BROWSE. SOURCES adds and removes an index by repository and ref; Dazzle ships no default source. BROWSE lists every entry across every added source, naming a source that failed to load separately from the entries that did. Selecting an entry opens the same review sheet `ADD` uses, with its repository and ref already filled in; an entry whose id matches an installed plugin opens that plugin's installed detail instead, offering `UPDATE`.

### A debug build can point plugin and index fetches at a local origin

A build define replaces the GitHub raw-content base for both plugin and index fetches with an arbitrary HTTP origin, letting an author serve a package from a local directory while developing it instead of publishing to GitHub first. The override reads only in a debug build; a release or profile build ignores it and always fetches from GitHub. Under the override a ref is used exactly as given, with no GitHub ref-to-commit resolution, since a local origin has no such API to resolve against; the served layout mirrors GitHub raw content's own, owner then repository then ref then path. `UPDATE`'s `USE LATEST` also has no such API to resolve a release or default branch against, so it refuses under the override instead of reaching GitHub.

### Manifests and dependencies have separate versions

`manifest_version` is the manifest format's integer version. `version` is the plugin's semantic release version. `dazzle_api` is its required API version range. Dazzle rejects unsupported manifest versions, unknown fields, unsupported capabilities and incompatible API ranges before running code. Retained incompatible revisions stay listed, disabled, with their original source and grants; they cannot execute until a compatible update is reviewed. The manifest's release version cannot change the meaning of its format.

`dependencies` maps plugin IDs to semantic version ranges. Activation requires all dependencies to be installed, enabled and compatible. Dependency cycles are rejected. A dependency cannot be disabled or removed while an enabled plugin requires it. Dependencies confer no permissions and expose no other plugin's Lua state.

Datasets and exported contracts have versions independent of the manifest, plugin release and host API. A dependency confers no data access. A consumer must declare a binding to an explicitly exported dataset or service and the user must grant its requested operations. Targets are `selection`, `self:name` or `plugin.id:name`; foreign targets require a declared dependency and matching exported contract. Permissions are reviewed for the entire revision, including dataset scope, not just operation names. Drops owns item records and their attachments. Projects owns project structure and goals, and declares its dependency and granted item APIs explicitly. Existing record identifiers, relationships, attachment paths and contents survive adoption without a destructive data conversion.

### Built-in features use the plugin lifecycle

Built-in plugins register their native UI contributions and typed host APIs through the same versioned catalog, dependency resolver and activation lifecycle as repository plugins. Native rendering and indexed queries remain native; scripts do not run during layout or scrolling. The host accepts native entry points only from its compiled-in module registry, never from downloaded source. Built-ins are trusted compiled code, not isolated interpreter guests. Neither the generic plugin registry nor the dataset authority contains branches naming the initial features.

Disabling a built-in withdraws its navigation, panels, capture targets and actions, cancels its subscriptions and revokes its API handles. A route or asynchronous callback retained from an earlier activation cannot continue using its data. Projects must be disabled before its required Drops provider. Data ownership and storage remain visible while disabled. Re-enabling restores the real feature and its existing records. Settings and the host/shell features remain usable when both initial plugins are disabled.

### Datasets belong to the host and survive their plugin

Each dataset has a stable identity tied to its plugin ID, source identity and logical dataset name, independent of the installed revision. New repository-plugin datasets use separate host-owned databases. Dataset names never become guest-selected filesystem paths. Every read, query, write and delete goes through a granted binding. Repository plugins receive no database handles, raw SQL or internal storage paths. A binding may grant fewer operations than an export permits; it cannot grant more. Cross-plugin writes are not exposed by the repository dataset contract. Built-in feature widgets use typed, revocable APIs; their datasets retain their existing host tables and attachment files. Isolation there is logical API ownership, not separate database files. Shared transactions preserve existing relationships and roll back native data mutations revoked before commit.

The first dataset format stores bounded UTF-8 keys and values with monotonically increasing record revisions. Writes and deletes require the expected revision; creation requires revision zero. Transactions enforce byte and record quotas together with each mutation. Queries are ordered and paginated, with bounded results. A schema mismatch stops access without resetting the database. Disabling, removing, updating or reinstalling a plugin does not delete its datasets. Reinstallation from another source does not inherit the original source's data.

Repository dataset accounting reports record counts, logical key/value bytes, database and journal file bytes, calls, denied operations and bytes transferred. Completed invocations persist usage counters; a crash can lose the in-progress invocation's telemetry, not an already committed record. Native accounting reports records, stored field bytes, attachment bytes, missing files, calls/events, rejected access, active subscriptions and awaited host time. Native counters flush in batches and on pause or disable; a crash may lose the current telemetry batch. Shared database pages, indexes and Flutter heap are not attributed per built-in. VM allocation and timings are reported separately from storage and shared process memory. Accounting does not claim exact battery attribution or an OS-process security boundary.

### Disable ends an activation without deleting records

`ENABLE` and `DISABLE` change execution, never data ownership. Disabling invalidates that activation's pending results, rejects queued work and releases its runtime before the operation completes. Re-enabling creates a fresh activation and cannot revive old handles or proposals. Dependency checks explain why a requested transition cannot proceed. Completed changes are not undone by disabling. Plugin state and retained dataset usage remain visible independently of whether code is running.

### Work and memory stay bounded

No runtime starts during capture or app startup. Manual invocation lazily starts one worker. A bounded cache keeps compiled plugins for repeated actions and frees every VM when the worker is disposed. Source crosses the isolate only on cache miss, and one native invocation carries a selected record and returns its proposal. No script runs during widget building or scrolling.

Dazzle caps source size, VM allocation, result size, pending requests and resident VMs. Execution checks a deadline and a safe-point count inside the interpreter; a Dart timeout alone is insufficient. These are cooperative execution limits, not a separate OS process or a hard real-time guarantee. Compilation runs off the UI isolate with bounded source input, but compiler allocations are outside the VM heap budget. Failed invocations discard their VM. Scripts cannot retain live Dart objects, authenticated connections or database handles. The runtime reports cold-load time, execution time and VM memory for profiling.

The dataset session's time budget starts at its first API call, not during compiler or FFI setup. It continues between calls and cannot be reset by catching an error. Call-count and elapsed-time failures are reported separately.

Plugin pages use versioned native UI constructors and a lower-level node and drawing interface. Luau owns page structure, transient state and event handlers. Dazzle validates bounded descriptions, preserves keyed native controls and renders scrolling and animation without invoking Lua per frame. Plugins can compose layouts rather than selecting a fixed screen template. Host operations are asynchronous effects behind declared, versioned capabilities; scripts receive neither SSH credentials nor arbitrary shell access.

### Plugin colour and layout follow the phone's active theme

A plugin's semantic colours — `accent`, `muted`, `background`, `surface`, `border`, `danger` — resolve against the same `DazzleTokens` a native screen reads, not a fixed palette, so a plugin page matches whatever look the phone is showing rather than the house look alone. A manifest opting into the newer UI API receives a `theme` table on its `mount` event, naming that same instance's brightness and colours as hex strings, for a script that wants to draw canvas content in step with it. A manifest that keeps the original UI API sees no `theme` table and no behaviour change.

The newer UI API adds house layout to the raw node vocabulary: a bordered panel with a header strip, a lighter grouping with no border, a three-column list row, a bordered status pill, and a bracketed label-and-value readout. Dazzle renders each with the same native widget a built-in screen uses, so a plugin page composes from the app's own look rather than approximating it node by node. Older manifests keep the constructors they already had; nothing already shipped is renamed or removed.

### Agent schedules are managed from a Luau plugin

Agent schedules is a standalone Luau package shipped with the app. It owns its interface and private preferences. A selected host owns schedules, execution and retained run history. Scheduling does not depend on the phone remaining online. The host side is a service the engine exposes and nothing else; setup is explicit, checks what the engine on that machine carries, and touches only the engine's own state. Existing host jobs and other plugins' datasets are not modified. Unsupported hosts show the missing capability instead of a simulated schedule.

The plugin manages one-shot and daily runs with an explicit timezone, repository directory, installed agent, prompt and timeout. It can inspect, pause and resume schedules, start a run on demand and read bounded run output. Occurrence identities prevent duplicate launches when a timer or connection retries. Failed and interrupted executions remain visible. The host uses the agent's existing authentication and permission configuration.

Disabling the plugin preserves preferences, schedules and history. Host-owned future runs are paused through the host API. An unreachable host leaves a visible pending pause until the host acknowledges it; the app never claims offline cancellation has completed. Already-running agents are not silently killed.

Struck: a host adapter of this plugin's own, written in Python and installed as a systemd user timer on Linux. It is a second artifact on the machine in a second language, put there for one plugin, and what a plugin has on a host is settled below as the engine and nothing else. Schedules reach a machine the way everything else does, through a service the engine exposes, and a machine whose engine does not carry that service reports the capability missing rather than simulating a schedule — which is the answer this section already gives an unsupported host.

What a schedule fires on while the phone is away is settled already, under Routines: a timer on the machine, put there when the thing is armed and taken off when it is disarmed, because a clock on a sleeping phone cannot buy a reliability it does not have. Striking the adapter does not touch that ruling — it changes what puts the timer there. The engine exits when it has answered, so it is not the thing waiting for three in the morning; it is the thing that arms what does. A timer set through a service of a binary the machine's owner already declared is a call the engine answers, not a second artifact the app left behind, and it comes off the same way it went on.

### A plugin's host side is a program the user installs, and the app never puts it there

There is one host artifact and it is one binary, the engine. A plugin that has work on a machine calls the engine and calls nothing else: what it can reach over there is a service the engine exposes, never a line a shell reads, and the app grows no second thing to install.

**It is not a daemon.** Nothing is resident and nothing listens. A call is an exec over the ssh connection the app already holds: the engine starts, reads its request, writes its answer and exits. That costs a process per call, which is what the quoted script under `sh -c` it replaces already costs, and it is why the engine is not offered as the answer to anything herdr's socket already answers. The agent panel keeps its held channels for events and its roster poll on a thirty-second clock, because no method lists sessions and a program on the host does not make one. A resident engine would be a second thing to keep alive on the machine, and the poll it could not remove would still be running beside it.

**The user installs it, and the phone finds it.** The engine is declared on the machine by its owner — a Nix module, `services.dazzle-engine`, being the shape the author of this document uses — and the app calls whatever is there. It never pushes a binary onto a host, never writes one over a shell, and never offers to. On a machine with no engine declared, a plugin that wanted one is told the capability is missing, the same answer an unsupported host already gives a schedule. A key installed for this app buys a shell on that machine and does not buy the right to leave software on it, and that distance is the whole reason this is the owner's declaration and not a step inside the app.

**A thing that can be installed has to be able to leave.** `teardown` is a call of the engine's own, beside `probe` and `version`, and it takes off what the engine put on the machine and says what it took off. A page of removal instructions for the user to follow by hand is not that: asking to be installed and having no answer to being asked to leave is asking for more than was said at the time of asking.

**The ceiling is the host's.** A plugin declares the capabilities it wants in its manifest and the phone grants them, exactly as it does for everything a plugin touches on this side. The host denies from its own side: `denyCapabilities` names capabilities the engine refuses whatever a manifest asked and whatever a phone granted, and `denyExec` names what `run` will not start. What executes is the intersection of the two, and where they disagree the deny wins. The phone is one device holding a grant; the host is the machine the work actually lands on, and its owner is the one who lives with what ran there.

**Luau on both sides, and only Luau.** A plugin is Luau in the app and Luau on the host: one language, one value representation, and a value that crosses between them is the same value rather than a translation somebody has to keep honest. The manifest carries `[runtime] kind` even though `luau` is the only value it accepts today, because that field is the seam — the day a second runtime is real it arrives as a value in a field that already exists, and not as a change to the format every installed manifest is read by.

### The engine's services are typed, and versioned from the first call

The engine answers named services, each carrying its version in its own name: the lifecycle calls `probe`, `version` and `teardown`, then `fs/1`, `run/1`, `git/1`, `schedule/1`, `kv/1` and `batch/1`. The number is on them from the first day rather than added on the day it first hurts. What the engine exposes is a public ABI with a plugin somebody else wrote on the far side of it, and a surface that gets versioned later is a surface that has already broken somebody once. `probe` says which services an engine has and at which version, so the phone asks a machine what is there instead of assuming its own build.

**A call says which owner it is made for.** The engine acts as one account on that machine and the identity travels with the request, so an engine reached on a machine several people use is not a way into another account's files. The owner is that account and nothing else. A plugin that keeps state on a host has a namespace of its own and it travels in the call's arguments, never in the owner field: one of the two is checked against the account the engine is running as, the other is a name a plugin chose, and a surface that let the second be written where the first is read would be asking the engine to verify a value it was handed.

**`run/1` cuts the output on the machine that produced it.** head, tail, grep and a limit are arguments to the call and are applied on the host, so what crosses the tunnel is what the plugin asked for and not a log the phone carries in full to discard the bulk of. The file is already over there, and a phone on a mobile radio pays for every byte twice, once to receive it and once to hold it.

**What ships first is the binary, the framing, the owner, the lifecycle, `fs`, `run` and `schedule`.** The first two are the ones the app already needs and today gets by quoting a script under `sh -c` with every value the user or the host supplied quoted into it. `schedule` is on that list because the section above leaves it nowhere else to be: a schedule has to fire while the phone is away, and the timer it arms and the agent it starts are work on a machine whose one host artifact is the engine. A scheduled run goes through the same supervisor `run` uses rather than a second one of its own, so a run started by a timer is watched, bounded and cancellable exactly like a run started by a person. The rest — `git/1`, `kv/1` and `batch/1` — are named here so the shape of the ABI is settled while it is cheap to settle, not because they exist: a service that is named and not built is absent from what `probe` answers, and a plugin asking for it is told so rather than finding out inside a call.

### A board of notes is a Luau plugin on the canvas every plugin already has

Board is a standalone Luau package shipped with the app, bundled and disabled until the user enables it. It owns one dataset holding its boards, the notes on them and the links between them. It declares no dependency, binds to no other plugin's dataset and asks for no host service: a board opens with every other plugin disabled, and disabling Board leaves its boards intact.

A board is a tall drawing surface the user taps. The toolbar holds one tool at a time and the tap means what that tool says: place a note, select one, move the selected note to the tap, link two notes, or erase a note and the links that touched it. The selected note's text is edited in a field beneath the surface and written back on save. That field is on the page whether or not a note is selected, so choosing one never moves the surface out from under the finger that is arranging it. A link is drawn between the two notes it joins and follows them when either moves.

The board is drawn before anything on it: a ground the width of the narrowest phone this app is built for, ruled across at a fixed interval, so an empty board is a surface with edges rather than the page's own background. A note breaks its text on the spaces between words and says with an ellipsis when there is more of it than the note shows.

A board is named when it is made and renamed from the list it is named in. The name it carries is the name the board says it has when it is open.

The surface scrolls under the finger natively and no script runs while it does. A tap is delivered in the surface's own coordinates rather than the viewport's, so what the user touched is where the note lands no matter how far the board has been scrolled.

Board is written against the drawing surface, the tap and the dataset API a repository plugin already has, and it adds no host surface of its own. Nothing it does is reserved to it. An author outside this repository can build a different surface — a map, a graph, a game — from the same primitive, and the app ships no board-shaped node that would decide on that author's behalf what a canvas is for.

A board holds as many notes and links as one drawing pass and one invocation's dataset transfer allow. Reaching that ceiling refuses the new note and says so on the board, rather than dropping notes from the drawing or accepting one it cannot store.

Repository plugins are an Android feature in this target; a future public iOS distribution needs its own distribution decision. WebAssembly is deferred on both sides, the phone's and the host's, and arbitrary background Lua execution on the phone is deferred with it.

## Routines

### A routine is armed on the phone and fires on the machine

Nothing of this is built yet. A routine is an ordered list of drops, a time of day, the machine it runs on, the directory it runs in, and which agent runs it. The phone composes it and the phone owns it: drops are already objects that live here, the registry of machines and keys and directories is already here, and the report is read here.

**Arming installs a timer on that machine. It does not set one on the phone.** An alarm that fires perfectly at three in the morning into a sleeping laptop accomplishes nothing, and that is the whole argument: the chance the work happens is bounded by the chance the machine is awake and reachable no matter which device holds the clock, so a phone-side timer cannot buy reliability, only spend it. What it would spend is a chain of grants that are individually revocable and none of them observable by the user — an exact-alarm permission that is denied by default and comes back denied after a restore, a standby bucket decided by a model on the device that no app can query, a vendor's battery killer that force-stops the package and takes its alarms with it, a radio the system has suspended, and a key nobody is there to unlock. A timer on the machine needs none of it, survives the phone being off or reflashed, and the flag that makes it persistent hands over the catch-up rule for free: a machine that was closed at three and opened at eight runs the missed slot as it wakes, and the user reviews a diff over coffee. Disarming removes the timer and the manifest with it.

**What the phone believes is armed is checked against the machine every time it answers.** A routine armed against a machine that has since been reimaged has to say so, loudly, on the screen where it claims to be armed. The alternative is the failure every scheduled-workflow system has shipped at least once: a schedule that was quietly switched off and a user who finds out weeks later by noticing nothing ever arrived.

**The run takes the tree away from the user before it starts.** A worktree of its own per run, or a refusal to start at all on a dirty checkout, recorded as a skipped run with that reason — an agent at four in the morning must never inherit whatever was half-written at midnight. It ends with a commit on a branch named for the routine and the day, never on the branch the user was on and never on main, so the morning question is a diff to read rather than a working tree to untangle. Nothing is pushed and no request is opened unless the user armed that in particular: pushing is outward-facing and the user was asleep. The morning artifact is that diff, step by step, on the viewer the app already has.

**A run that did not happen is what the phone is for.** Nothing on the executing side can report its own absence, and that is the failure every schedule has in common — no run, no error, nothing. The phone holds the time each armed routine is next expected, and a poll that asks for no permission and does not care whether it is a quarter hour late is enough to notice the time went by with no record against it. `DID NOT RUN` with the best reason available — machine unreachable, timer missing, skipped on a dirty tree — is the one thing a schedule cannot say for itself.

**Exit status is not the report.** A process that ended cleanly says the session started and stopped, not that the work was done; the states herdr already reports are the vocabulary instead, per step, alongside what the step actually changed. And a blocked agent is a suspended run rather than a failed one: the pane is still there, still alive, holding the question. The morning line says which drop is waiting and opens onto it, and the user answers the run in the middle of where it stopped. That is the one thing this shape has that none of the surveyed products do — every one of them hands back a finished artifact, and none of them lets anyone walk into last night's run while it is still standing.

**The time it was meant to fire goes into the prompt.** A run that starts at eight because the lid was shut at three is doing yesterday's instruction today, and only the prompt can decide whether that is still worth doing.

**Autonomy here has no sandbox, and the trade is the user's to make knowingly.** Every product that runs an agent unattended pairs it with something — a fresh clone in a cloud environment, a machine of its own, a network allowlist. A routine here is the user's real machine, real credentials, real network, an agent running without an approval gate, and nobody awake. The mitigations are the worktree, the refusal to push, a timeout on every step, and the fact that the user armed this particular list of drops themselves — which is weaker than what any of those products offer, and is stated here rather than left to be discovered. It follows that the drops are the instruction and nothing fetched at the moment of firing is: text that arrives from an issue, a log or a payload is quoted as material for the drop to consider, never as more of the drop.

Struck: an exact alarm on the phone, and the foreground service that would have to hold an ssh session open for the forty minutes an agent takes. The permissions are a policy problem, the vendors are a reliability problem, and both are moot once the timer is on the machine.

Struck: catching up on every slot that was missed. One run, for the most recent one, and the older ones recorded as skipped — which is what the persistent timer does, what the workflow tools settled on independently, and what the user actually wants at eight in the morning after a weekend away.

Struck: two runs of the same routine at once. If the last one is still going the next is skipped and says so. An agent on the same directory as another agent is not parallelism.

Struck: arming a routine that has never been run once. The button that runs it now exists so the user watches it work before trusting it to three in the morning, and a routine that has never completed a run is a routine nobody has evidence about.

## The source

### The code is read, not narrated

Everything this repository builds from — the Dart, the justfile, the Nix files, the Android glue, the Luau plugins — carries almost no comments. What a thing is called, what it takes and what it hands back is the code's own job; the reasoning that put it there is the commit that made the change and this document. A comment that restates a signature, names a field after its own name, gives a file or a section a heading, narrates the next four lines, or argues a decision the code has already settled is not written, and where one exists it is deleted rather than reworded.

What is written is short and rare: a line or two where the behaviour is not the obvious one — an order that matters, a bound that comes from outside the file, a case that reads like a mistake and is not. It sits on the thing it explains, in plain words, and never grows into a paragraph. Where the explanation needs a paragraph, the code is wrong shape and the paragraph is not the fix.

Directives to a tool are not comments in this sense. `// ignore:`, `// ignore_for_file:` and their kin are instructions the analyzer reads; a bare trailing `//` is how `dart format` is told to leave a hand-laid-out literal alone; and the line above a `just` recipe is the description `just --list` prints. All of them stay, and a recipe keeps exactly one such line, short enough to read as a whole sentence in that listing.

A `library;` directive whose only purpose was to carry a file's doc comment goes when the comment does.

The rule is the app's own source, not every file in the tree. Vendored code under `packages/` is somebody else's work kept close, and a change to one of those files belongs upstream. Generated files are the generator's.

Struck: moving the prose into `///` doc comments. The marker was never what made them too much.
