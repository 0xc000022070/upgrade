# STRIKED

The contract. What the app is, what it looks like and what it does — in the present tense, as it stands. It is not a changelog: nothing here overrides anything else here, and where a decision replaced an earlier one only the survivor is written down. Git holds the order the decisions arrived in, the dates and the words they were asked in.

A section says what has to be true. `Struck:` paragraphs say what was considered and refused, and why — they are part of the contract, because the reason a thing is absent is worth as much as the reason a thing is there.

## What it is

### Striked is one person's control plane, and it runs on their phone

Local-first, single-user, mobile-first, Flutter. There is no account, no backend, no cloud, no sync and no websocket to a service. What the app knows is in a SQLite file in its own sandbox, and what it reaches out to, it reaches on a connection the user opened to a machine the user owns.

It answers a small number of questions and it answers them fast: what am I working toward, what is the next thing, what is stuck, where do I put this thought before it is gone — and then, because the work is on machines and not only in lists, what are my machines doing, what is the agent on that machine waiting for me to say, and what does the code look like right now. It is a real tool, not a gamified task manager and not a personal Jira.

The reference for the look is `docs/images/striked-concept-v0.png`. It is direction and not a pixel spec: its typography, alignment, icon and spacing inconsistencies are the concept's, not the app's.

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

1. Is the primary action visible in about a second? 2. Is every panel necessary? 3. Could a container be spacing instead? 4. Is anything on it decorative? 5. Does it look like a generic AI dashboard? 6. Does it work in monochrome? 7. Is it readable on a real phone? 8. Are the icons consistent? 9. Is the tactical influence credible? 10. Does it feel like Striked rather than a game-UI collage?

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
  builtin_plugins/  the native plugins the app ships with
assets/ fonts/ icons/ textures/ sprites/ project_emblems/ plugin_emblems/
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

No Lucide: not as a dependency, not as a reference, not as a placeholder, not as inspiration. The Striked vector system is geometric, angular, technical, compact and schematic, internally consistent, minimally rounded, recognisable at 16–24, and not a set of cyberpunk glyphs.

Its primitives: brackets, nodes, lines, routed paths, frames, signal waves, diamonds, triangles, crosses, squares, broken and open geometry, directional markers. The family covers navigation, the entities, and the states — done, pending, active, blocked, warning, failed — and grows into the future vocabulary of message, channel, priority, critical, acknowledged, encrypted, verified, device, sync, relay, vault and connection.

A new family is not drawn one glyph at a time. First an exploration sheet of twenty to thirty experiments from the primitives, then a grammar is picked, then the family is derived from it: a 24×24 base viewBox, a stroke around 1.5–2px equivalent, defined corner behaviour, fill rules, optical padding, a minimum size and an alignment grid, mostly square or angled terminals, a systematic mix of stroke and solid where it helps. Every icon has to look authored by one system.

The research is tactical HUD glyphs, avionics symbology, technical diagrams, telecom symbols, industrial labelling, map symbols, signal routing, radio interfaces, equipment status icons and geometric wayfinding. Games are visual research only; their SVGs and textures are never extracted.

**A glyph that skips the grammar is the one that reads as foreign.** The tell is always the same: a stock outline symbol standing in for a thing — a sheet of paper for machines, a cog for settings, a notched cross for extensions, three dots for a place. So no glyph reaches `assets/icons/` without a row in `docs/icons.md` naming its meaning, its node class, its modifier and its minimum size. A closed outline is drawn only where the container is the subject — a rack unit, a bay of slots, a keycap, a control frame — and never as a traced picture of an object.

**No destination and no action borrows another's glyph.** A borrowed glyph is a claim the two things are the same thing, and the reader believes it.

**A plugin is drawn as a part that plugs into something.** Its own body, with one edge carrying a keyed tab squared off. The round knob a puzzle piece really has is a curve the grammar does not own, and the tab alone is enough: nothing else in the family has an edge that interrupts itself.

### Assets are sorted by what they are allowed to become

`assets/` holds only what is approved and Striked-owned, and it is the one copy: nothing is mirrored into it from elsewhere in the tree. Each family's index lives in `docs/` — `icons.md`, `textures.md`, `agent-marks.md` — because a markdown file under a bundled directory would ship in the app. External research and generated explorations are not kept in the tree; the history holds what was tried.

The app ships only assets whose licensing and provenance are safe.

### Texture is felt and not seen

Allowed, extremely restrained: subtle noise, a slight print or scanner texture, a fine grid, a faint scanline, a tiny signal distortion. Forbidden: giant glitch overlays, RGB split everywhere, grunge on normal text, unreadable surfaces, a CRT effect that costs legibility. Texture belongs to backgrounds, branding moments, transitions and empty states, and never sits on important text or on a control.

### Motion is quick, deterministic and sharp

100 to 220ms. Short opacity changes, short directional movement, a controlled panel reveal, a subtle signal pulse, interpolated progress, an occasional scan transition. No bouncy springs, no overshoot, no toy movement, no particles, no constant animation, no huge glitch transitions. Motion is there to communicate a change, a connection, new information, a state transition or hierarchy — and nothing else.

### Nothing moves where it cannot be seen

The dot spinner and the mascot run only while the app is in front and the part of the tree they sit in is showing. Behind another route, behind another app or under a locked screen they stop on the frame they had and go on from it on the way back. The terminal's cursor blink rests while the app is not in front and while the terminal does not hold the focus, and a route pushed over a terminal takes the focus with it. Each step of any of them is a frame the phone renders, and one nobody sees is battery for nothing.

### The app asks for sixty frames a second

The surface the app draws on tells the system its content runs at 60 Hz, and the system picks the display rate from that, only where the switch is seamless. Text and a terminal gain nothing past sixty, and on a 120 Hz panel every frame over it is paid for in battery. It is a hint and not a display mode: a mode would hold a variable-rate panel at sixty even when nothing moves, where the panel would otherwise drop far below it, and would stay the mode of whichever display the app started on when a foldable moves to the other one. The system can still go past sixty, for a touch or for another window that asks for more.

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

A toast is a strip the app raises over the top of the screen to say what just happened, when what happened leaves no mark the screen can show. It is the one surface that floats: it draws over whatever the screen has up there, the breadcrumb, the title and the first panel under them, and none of them move to make room. It starts under the status bar and never covers it.

**A strip is never drawn as a panel.** A panel is the screen's own furniture and a toast stands over it, so the two are never the same object or the float stops reading. A strip is `surfaceSecondary`, one step lighter than every panel beneath it, a hairline `borderNormal`, radius 2, and a 2px accent rule down its left edge. That rule is the only accent edge in the app and it is what says the strip is not furniture.

**A strip is narrower than the content column.** It takes the column's left edge and gives up the last 24 on the right, so the panel it covers stays visible down that side and the interruption can be seen. Nothing is dimmed and nothing is given a shadow; the contrast between a border and a surface does the work here as it does everywhere else.

**It is at the top because the bottom of the screen is where the work is.** The capture bar, the selection bar and the parked shell bar all live down there, under the thumb, and a notice standing over any of them is a notice standing in the way of the next thing the user came to do. The top of a screen is the part already given over to saying where you are, which is what a toast is for; the trade is that the way back is a reach rather than a thumb-tap, and a verb tapped once a week is the right thing to make the user reach for.

A strip is the verb that happened, in the panel-header style and `textMuted`; the subject beside it in mono 12 and `textSecondary`, clipped to one line; and the way back at the right, in the accent. The accent is on that one word and on the left edge, and nowhere else: a filled accent bar across the screen is the large coloured surface the palette forbids.

**Toasts stack rather than replace each other.** Every live one is its own strip, with 8 of background between them and 8 under the last, so the ground shows through at every seam and the stack never tiles into the panel it covers. Two are shown. A third folds the older ones away behind a strip of the same family, which reads `+N MORE` and is tapped to open the stack and tapped again to fold it. Six is the whole stack, and the oldest leaves when a seventh arrives.

**Newest is at the top, because a strip leaves on a clock the user did not set.** Each runs its own and the oldest goes first, so the oldest belongs at the bottom, where its leaving moves nothing above it. An arrival pushes the stack down instead — and an arrival is the user's own doing, a moment after the tap that caused it.

**A toast for something still going holds until it ends.** It carries a spinner before its verb and no clock, and the same strip turns into how it ended, which then takes the clock of its kind. Swiping it away is the only other way it leaves.

**A toast with a verb on it holds eight seconds, and one with nothing to tap holds four.** The hold is not free: a strip stands over the breadcrumb, the title and the top of the first panel, so every second it waits is a second of the screen's own head covered, and a second in which the next tap's toast arrives on top of this one rather than instead of it. Eight is long enough to read the line and reach the word, and short enough that two taps a few seconds apart do not meet on the screen. What lets it be that short is that a toast is never the only way back to what it undoes: the thing it reverses is still on the screen behind it, and the row that did it is still the way to do it again.

**A strip is swiped off either side, the way a notification is.** The clock is the app's guess at when the notice has been read and the swipe is the user saying so, and the user's answer wins: a strip flung off the side is gone at once and its clock is cancelled with it. Nothing is drawn behind it as it goes — no coloured ground, no bin glyph, no label — because there is nothing else the gesture could mean, and the strip sliding clear of the panels it was covering is the whole of the feedback. The stack closes over the gap across the same 140ms it would have taken had the clock run out.

**Swiping away a strip that carries a verb forfeits the verb**, and is not warned about or confirmed. It is the same forfeit as letting the clock run out, and it is affordable for the same reason: what the strip offered was a shortcut to something still reachable without it, so the cost of throwing it away is a second reach and not a loss.

**The `+N MORE` strip is not swiped.** It is a control and not a notice, it says nothing that could have been read, and a gesture that threw away a stack the user has not seen yet is the one version of this that takes something the user cannot get back by reaching. It is tapped, and what it was hiding is swiped one strip at a time once it is open.

**A field taking focus takes the whole stack with it.** The form's scrim covers everything outside the form, and a notice dimmed under a scrim, carrying a verb nobody can reach, is worse than no notice at all; so the stack empties when the keyboard comes up rather than waiting underneath it.

Strips arrive as a short drop and a fade over 140ms and leave the same way, and the stack closes over the gap a departing strip leaves across the same 140ms rather than snapping shut on it. Nothing pulses and nothing counts its seconds down on screen.

**A toast is raised for what the user cannot see, and never for what the screen already shows.** An action whose result is the row under the finger says so on that row. A toast that only confirms is the app talking over a screen that has already answered.

**Struck:** `DONE · UNDO` as a filled accent bar standing in the capture bar's place. The interpunct read as two buttons where there was one, it painted the loudest surface in the app for the rarest tap on the screen, and it took capture off Home for thirty seconds to say what one line of text says.

**Struck:** the stack over the bottom of the screen. Floating clear of the capture bar rather than replacing it fixed the theft of the field and not the covering of it: a drop marked done still put a panel across the bar the user had just typed into, for thirty seconds, and that is the strangest half-second in the app.

**Struck:** the thirty-second hold on a toast carrying a verb. It was set when a strip was made of the app's own furniture, and a notice that already looked like part of the screen could be argued to cost nothing standing there; one that deliberately covers the head of the screen cannot be left up for half a minute. The long hold was also what made the stack deep enough to be a complaint: taps a quarter of a minute apart were still meeting each other on the screen.

**Struck:** `+N MORE` opening the folded strips as a page or a modal. What is behind the fold is a handful of lines that are about to expire on their own, and a surface the user has to leave and come back from is the opposite of that. The same history is already kept twice, on DONE and on ACTIVITY, both of them reachable and neither of them expiring; a third copy of it, one that cannot be read later, is a screen with nothing on it. The fold unfolds in place.

**Struck:** the stack as one panel of ruled rows at the full width of the content column. Built out of the app's own furniture and laid at the panel grid's own width, it tiled with the panel underneath it: two hairlines meeting read as one rule, and at two rows the seam stopped reading at all, so the notice arrived looking like the screen's first panel and took a real one off the screen to do it. A floating surface cannot be made of the same material, at the same width, as the thing it floats over.

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

The look is the cover of Public Memory's *Wuthering Drum* (`docs/images/wuthering-drum-cover.jpg`), and it is the target for every glitch in the app, moving or frozen.

- **Blocks.** A displaced region is a rectangle with its own height (from a sixty-fourth to a quarter of the glyph) and its own width (rarely the full width; most span an eighth to a half), shifted sideways by a thirty-second to a sixth of the glyph's width. Blocks may overlap.
- **Mosh.** One or two blocks are copies of a *different* region of the same glyph rather than shifted originals, so a piece of the shape appears where it does not belong.
- **Fragments.** Two or three small blocks detach fully and sit in the empty space beside the shape.
- **Per-block tone.** Each block shifts luminance one step up or down — a light block over dark ground, a dark block over light. The accent frame stays the single colour event.
- **Grain.** The static supplies the grain behind everything; the glitch adds none of its own.

Each frame is a new random block set and the last frame is the clean glyph. Blocks and fragments stay inside the widget's box, and they paint over an intact base rather than cutting holes in it. A screen-level event may use the same language at panel scale. The glitch has to read as a deliberate corruption of a clean shape, so at least 70% of the un-glitched shape stays intact.

**The screens bubble tears harder.** Its own glyph is the one icon allowed past these limits, because it sits over whatever the user is doing and has to read as a live signal, not a decal. Eight frames at 45ms, the eighth clean; up to half of the glyph displaced in a frame; sideways shifts and fragment throws twice the ranges above; the accent lands on the third and sixth frames. Every other icon, the screens glyph in the list header included, keeps the five-frame glitch.

**Struck:** the nodes-only signal frame, where an icon was replaced by its routes-hidden variant for one frame. On a 20px glyph it left none of the shape.

### The background is a character field

The one exception to glitch never being a state, and the one place the app is allowed to compute a picture instead of loading one. The scaffold background is a grid of monospace characters shaded by a formula: no tile, no sheet, no GIF and no video. **The cell is one character advance wide and twice that tall**, measured off the shipped face rather than hardcoded — mono 11 in IBM Plex Mono is 6.6 by 13.2 logical pixels, which is 63 by 68 cells on a 412 by 892 surface.

**The shade of a cell becomes a character through one ramp**, fifteen glyphs ordered by their measured ink coverage in the shipped IBM Plex Mono and not by how heavy they look — `#` and `O` cover the cell to within three ten-thousandths of each other, and a ramp holding both spends a level on a step nobody can see. An ordered Bayer 8×8 dither spread over exactly one level is added before the shade is quantised, so a gradient trades a terrace edge for grain instead of for a second contour. Empty cells are not drawn at all.

**Three effects, and none of them is the mascot.** `lattice`, a sine sweep crossed with a value-noise blotch; `flow`, ribbons on the contours of an fBm field; `rings`, a perspective tunnel. They are abstract and they stay abstract: the mascot has fixed slots and never drifts through the background. Each holds for 40 seconds and the next takes over on a tick boundary, which at this opacity is not a transition anybody sees. Which one starts is the launch epoch modulo three, so two runs do not open the same way. Every effect drives its motion through one shared swell so the field breathes rather than scrolling at one rate forever, and a swelling rate is integrated over time and never multiplied by it — multiplying runs time backwards on the falling half and the field visibly rewinds.

Eight frames a second, on a `Timer.periodic` and never a `Ticker` — a `Ticker` asks for a frame every vsync, and the build that used one idled at about 49fps. The low rate is what makes it read as a field and not as smooth drift; 8 to 12 is the allowed range. The glyphs are `textMuted` at 6%: texture is felt, not seen, and if a screenshot makes it obvious it is too strong.

It lives on the scaffold background only — never on a panel, a row, a sheet or text. It pauses, drawn once and unmoving, when the app is not in the foreground, when reduce-motion is set, and when the device is saving battery or is thermally stressed; battery saver and a `PowerManager` thermal status of moderate or worse arrive as one `throttle` platform stream.

The cost is a budget and not a hope: the background sits under its own `RepaintBoundary`, a tick rebuilds nothing above it, the ramp is rasterised once into a glyph atlas for the life of the process, and a whole frame is one `drawRawAtlas` call — the same trick a terminal emulator uses, and the reason thousands of characters cost one draw. Measured on the emulator, release, idle on HOME: 127 frames in 15.5 seconds, which is 8.1 a second and is the field's own cadence — sitting on HOME, the app draws for the field and for nothing else. Parked from SYS the same screen goes quiet: eight frames while the navigation settled, then seven seconds without one.

### What the Watch Dogs surface actually contributes

**A real boot log.** A cold start shows the work it is doing — opening the database, running migrations, counting what is in it, loading fonts, naming the device — in mono 12, `textMuted`, with status tokens in accent. The log rolls in at most six beats of 40ms, because a 120ms roll read as a flicker; a longer log shows several lines a beat rather than taking more beats, so a step added to startup never adds time. The finished log holds for one beat, the glitch tears it, and it hard-cuts to Home with no fade. The whole thing is capped at 600ms and never blocks past the cap: if the app is ready later the log waits on the real step and the cap flushes whatever is left. Startup steps that do not depend on each other run at once, and the log still lists them in its fixed order. The Android 12 splash exit animation is removed so the log is not composited under a fade. Reduce-motion skips it, and a warm start never shows it.

**A solid action bar.** The primary action on a surface is a full-width flat block filled with accent, its text in the background colour, mono and uppercase, with no border and no radius past 2. It is the capture submit when the field has text, the recommended row in a triage sheet, and a destructive confirm — which takes a state colour instead of the accent. Never navigation.

**A selected row is a block.** In a picker or an action sheet the focused or recommended row takes a solid accent block with inverted text and a `// ` prefix in mono. Everything else stays text on the ground. The tab bar keeps its accent text and top rule.

**Text smear.** The screen title on a tab change takes one or two frames of block displacement and settles, under 120ms.

**A dither field.** Empty states and the boot background use an ordered-dither dot field — Bayer 4×4, 1px dots, `textMuted` at 12% — instead of blank space. Static, never animated. It is a dot lattice and not a character field, and the two never stack: a surface that carries the scaffold's character field does not also carry this.

**A dot spinner.** The loading indicator is a 3×3 grid of 2px squares with one lit at a time, clockwise, 80ms a step. It appears only when a wait passes 200ms.

**Bracket labels.** A detail screen's field labels take the `[ LABEL ]` mono form for the key facts — `[ OBJECTIVE ]`, `[ BLOCKED BY ]`, `[ EFFORT ]`. Section headers keep the tracked uppercase form; brackets are for inline facts.

**A build string.** The version and short build id, in mono, at the bottom of SYS and nowhere else.

**Struck:** magenta and cyan pixel art, the spray-paint logo, glow, the light-grey bottom strip, and any motion longer than the limits above.

### The mascot is a cat's head in braille, and it is a distance function

The icon grammar's stroke rules do not apply to it, and neither does the grid: it is drawn out of characters, like the background and like the scene the aesthetic comes from.

**The source of truth is a signed distance function in Dart**, not a picture. **There is no head under the ears.** Two swept blades lean in from opposite corners — the left near-vertical off a tip two dots wide, the right a long diagonal running down and to the left off a tip at the top-right corner — and they are welded to the mass and to each other by one smooth minimum, so the row where they converge is the widest row of the figure and no outline separates ear from skull. Below that weld the mass is two ellipsoids, a wide brow and a narrower chin set to its right, which is what makes the lower half lean the way the blades do. The face is not added, it is **cut, and cut clean through** — the holes are tunnels deeper than the mass is thick, so what reads as a gap is the ground behind the figure and not a shaded pocket in front of it. **There is no nose and no mouth**: a part added onto the face would have to clear a whole dot in every direction to survive the bake, and at thirty-four dots across it does not; a socket is no better, because the key light is dead on and reaches straight into one to relight the back of it. What is cut instead is a tall groove down the left, which leaves a cheek lobe standing free of the mass, and one socket low on the right. The whiskers are loose spheres well clear of the figure, two in the lower-left corner and two in the lower-right, because a whisker drawn as a stroke has to be a dot wide to survive the bake and then reads as a shelf under the face. The figure is asymmetric on purpose and the two sides are separate terms. It is authored in the view's own units, so the numbers in the formula are the numbers the frame is measured in, and scale is a pose and not a factor typed into thirty radii. Any pose, any size and any yaw is a different evaluation of the same formula, which is what makes a state sheet choreography instead of eight drawings.

**The figure is measured against the reference, not eyeballed against it.** The drawing this mascot answers to is a dot matrix, so it can be read back as one: threshold it, take the connected blobs' centroids, fit the origin and pitch that minimise the squared snap error, and it resolves to 34 by 38 dots at a third of a pixel. That is a target a render can be scored against — dots in common over dots in either — and the last three passes over the formula moved that score and not an opinion. A smooth distance field will read clean where the reference is torn, and that difference is accepted; what has to match is the silhouette.

**The medium is braille, not the ramp.** A braille cell is eight dots in two columns of four, and the pattern is the low byte of the code point. The grid stays one character per cell, so the runtime still blits one sprite per cell, while the figure is sampled eight times inside each of them. The dots come out square for free: the cell is drawn one wide by two tall, so two dots across and four down put the same pitch on both axes. A cell is on or off per dot, so the tone curve is steep — most of the lit surface solid, most of the shadow empty, and the grain left to the band between them where it reads as form — and the key light is dead on and high, because a raked light does not shade the underside of a dot figure, it deletes it: every downward-facing normal lands in that band at once and the jaw comes out of the bake as a torn edge. The shading term is flat for the same reason — mostly ambient, a little diffuse — and the turn still reads, because the light is rotated into the world and the kitten is what moves.

**Nothing marches on the phone.** `tool/bake_mascot.dart` sphere-traces the function offline — bounding-sphere entry, hemispheric ambient occlusion, a soft shadow, a rim term, 3×3 supersampling — and writes character grids to `assets/sprites/mascot/<state>.txt`. The runtime reads grids and blits them. A grid file is one header line of `cols rows frames fps loop|once`, then per frame a `@ x y` line for the accent cell or `@ -` for none, then `rows` lines of `cols` braille characters, so a bake opens in any editor as the picture it is. **Nobody hand-edits the grids**; the way to change the mascot is to change the formula.

**Detail is dots and dots are nearly free; what costs screen is cells.** The march runs at dot resolution and the pack folds eight dots into each character, so a grid carries four times the samples the ramp got out of the same column count. The rows set the scale — the projection's unit is half the field height — and because a cell is drawn two to one, a grid whose rows are half its columns is square on screen. **Every sheet is 17 columns by 10 rows**, which is 34 dots across by 40 down — the reference's own pitch, and taller than square on purpose, because the drawing is taller than it is wide. A denser grid was tried first and struck: at a hundred and ten dots across the figure fuses into solid ink and the dots stop being countable, which is the one thing the medium is for. The compact mark of the idle pose ships beside the states on the same grid, one frame instead of four; it is its own render of the same function and not a resample of a sheet. The bake-time passes run on dots and not on cells, so the sweep and the glitch land at the pitch the figure is drawn at.

Because the frames are cells and not pixels, there is no integer-scale rule and no `FilterQuality`: a size is a cell width, 7 on a full sheet and 4 for the compact mark, and a cell is twice as tall as it is wide. No slot fits the grid to its box: the grid is chosen for the figure, and the slot takes it at a fixed cell.

**No font carries this and none is asked.** Nothing bundled here has the braille block, and it does not need to: a dot's place in its cell is arithmetic, so the 255 drawn patterns generate themselves from the same numbers the bake packs with, as discs at 82% of their own pitch. The sheet is laid out sixteen by sixteen rather than in a row, because 255 cells side by side would be a texture wider than some GPUs will take.

**One accent cell, and it is earned.** Every character is `textPrimary`; a single accent cell — the four dots in the middle of its cell — sits high on the mass's right, proud of the surface by a hair so the march can reach it. Its position is one world point projected through the same camera and then raymarched back for visibility, so it tracks the yaw and disappears on its own when the figure swings in front of it. No frame hand-authors where the spark is, and no frame hand-authors that it is gone.

The states, all derived from yaw, vertical offset, light and one bake-time pass over the shade field: `idle`, four frames at 2fps, a yaw sway inside a tenth of a radian; `looking`, six at 4fps, a yaw sweep wide enough that the spark leaves and comes back; `working`, eight at 8fps, a tight sway under a bright band sweeping down the figure; `success`, five at 6fps once, the light rising from dim to full as the yaw settles square; `blocked`, four at 2fps, held at three-fifths light with the spark blinking; `alert`, four at 4fps, full light with block displacement on two of the four; `sleep`, three at 2fps, a third light, sunk slightly, no spark.

**The mascot is Striked's identity, not an agent-status indicator**, and it is never bound to aggregate agent state. It appears as a static frame in the launcher icon and in a project detail's icon slot, and nowhere else. Nothing of it is on Home, nothing of it opens the app, and the agents route's empty state carries host status and no figure.

The other state sheets ship as reusable assets and the widget accepts any of them, but a surface opts into a state by name, and none has yet.

**Struck:** the splash route, the ten-frame `splash` sheet and the 64 by 32 grid it was baked on. An app that opens on a held drawing is an app that is slower than it is. The handlers that parked a notification tap while the splash owned the screen stay, moved to boot: `AlertsHost` is the first route's own subtree now, and the flags it drains cover the window between the plugin answering and the first frame.

**Struck:** the cat with a head — a cranium, jowls and a chin welded into a skull with two cones standing on top of it, a nose bridge and a mouth cut into the face, and a hundred and ten dots across to draw it on. It had nothing to do with the drawing it was supposed to be. What replaced it is the drawing, measured: blades that converge instead of ears that stand, one mass instead of a head and a face, and a grid coarse enough that a reader can count the dots.

**Struck:** the symmetric cat, inherited whole from the skull it replaced — the fold of x, the matched pair of round ears with a pinna hollowed out of each, the capsule whiskers, and a face of sockets subtracted a little way into the mass. It was a head that happened to be a cat's.

**Struck:** the bare skull, and with it the ramp as the mascot's medium. A skull is not the name on the tin; the figure and the word should be the same joke.

**Struck:** the pirate skeleton — the hat, the sword, the bandana and the body under them — and with it the 48×48 pixel grids at `design/sprites/mascot/`, their assembler `design/tools/sprites.py`, and the sheet PNGs it wrote. A prop is a pose the formula cannot take, and eight sheets of props is eight drawings pretending to be one character.

### The launcher icon is the mascot's idle frame, and it is not a badge

The idle pose on a flat dark ground, as the adaptive foreground and background. **The figure's bounding box fits inside a 58dp box centred on the 108dp canvas**, which clears every launcher mask shape with 4dp to spare inside the 66dp safe zone.

**The icon is the dots, not a smooth render of the same formula.** `tool/bake_icon.dart` marches one 18 by 9 grid — 36 dots square, which is the most an icon can carry, since at xxhdpi the 58dp box is 174 pixels and 36 dots of it puts only five under each one; a finer grid is a grey smear — and then rasterises that grid, once per density, at the density's own resolution. **Never a resample of another density's PNG.** A dot's coverage of a pixel is an area and not a poll: a dot is a disc and a pixel is a square, and the area where those two overlap has a closed form, so the anti-aliasing is exact rather than sampled. The pixel-art no-anti-aliasing rule went with the pixel art.

The tool runs on the bare VM, where there is no text pipeline and no font to ask, and it needs neither: a dot's place in its cell is arithmetic, and the dots are drawn at the same 82% of their pitch the app's atlas draws them at, so the icon is the same mark and not a likeness of it.

Where the figure lands is solved and not computed from the grid: a cell with one dot lit puts it a quarter of the way in from that cell's own edge, so the drawn bounding box is not the cell box, and the only way to ask where the ink ends is to draw and look. It is solved at each density rather than once as a ratio, because the box is measured in whole pixels and rounding one at 432 is not rounding one at 108. Nothing is clipped by the circle, squircle or rounded-square masks, and the monochrome layer is the foreground's own alpha. The icon carries no wordmark.

**Struck:** the ramp drawn by hand as five-by-seven bitmaps, carried in the tool as data. It existed because the VM has no font, and at icon size it terraced at the dark end where the ramp's last few characters land within a couple of cells of each other. Dots need no bitmaps and no font.

**Struck:** a tactical patch — a raven carrying a rifle on an olive shield with a crosshair and grain. It reads as a badge.

**Struck:** the raven alone, glitched or standing, in hard-edged flat line art. The mascot replaced it.

## Home

### Four tabs, and the bar is glyph over label

`HOME`, `PROJECTS`, `MACHINES`, `TOOLS`. Each tab is a house glyph over a mono 9 label, accent on the active one, with a thin top rule segment over it. No floating centre button, no pill container, no glow.

**Every tab owns its glyph rather than borrowing one.** A destination is a place, and a glyph shared with an action says the place is that action. `HOME` is a house the roof is carried down into, open on the right, with the local endpoint inside it — a roof over a detached baseline was drawn first and reads as two objects rather than a place. `MACHINES` is two stacked rack units carrying a system node each — machines, not a page of text. `TOOLS` is a bay of docked slots holding unlike modules, which is what a destination filled by plugin pages is.

**Struck:** an `ACTIVITY` tab and a `SEARCH` tab. Activity events keep being written and nothing draws them; search is a screen Home pushes, not a tab to live on. And a separate `SSH` tab: it listed the same machines a second time, so a host's shell and its details were one tab apart.

### Home is the agents first, then the next thing, then the work

The panels, in order: `AGENTS`, because what the machines are doing is the most important thing on the screen; `NEXT ACTION`, present only when an item is actually marked next and absent otherwise; and `DROPS`, unfiled items newest first with bundles adjacent. Panels a plugin contributes stack in with the rest.

There is no suggestion fallback under `NEXT ACTION` — a panel that guesses at the next thing reads as a mock, and the one thing this screen must not be is a mock.

**Home has no screen title.** The breadcrumb line is the whole header, with the search glyph, then plugins and `SYS`, as its right-hand actions. `TODAY_` and its cursor are gone: the panel under the crumb already says what the screen is.

**Struck:** a `PROJECTS` panel on Home, and with it a `VIEW ALL` and a `NEW +` there. A project is reached through its tab, and a new one is made from that tab's own `NEW +`.

**Struck:** a `BLOCKED` panel and a `RECENT` panel on Home. Blocking is reached from an item's quick view and the reason still renders in warning on the row; it is not a section.

**Leaving a screen is leaving it.** A tab switch clears the selection and the fresh set of the tab being left, exactly as a route push does, and coming back starts clean.

### Unfolded, the columns scroll and the page does not

Wide enough for two columns, `AGENTS` sits in a narrow one on the left and the cards in the rest. The crumb line stays where it is, and each column scrolls under it on its own, so a drag down the drops never carries the agents or the header away with it. The `DROPS` card is as tall as its rows and never taller than the room the other cards leave in the column, so a card under it is on the screen without a scroll: past that its header holds still and its rows scroll inside the frame, which ends a gap above the capture bar rather than being cut by it. A collapsed `DONE` under it stays a header strip at the foot of the frame; opened, the two share the height. On a screen too short for the card to show more than a couple of rows, the column scrolls the card whole instead. Folded, Home is one page as before, `AGENTS` over the cards, and a fold or an unfold keeps both panels as they were.

### The capture bar is a panel, pinned above the nav

Header strip `CAPTURE / QUICK ADD`, then the field line with a mono placeholder and the accent target glyph on the right. Submitting creates a drop; it never submits empty text. The form closes itself the moment the item is in.

**The bar is put away with a flick on its own header strip, and the strip stays.** A drag down the screen on `CAPTURE / QUICK ADD` takes the field, the actions and the keyboard with it and leaves the strip standing over the nav; a drag up it, or a tap on it, brings the whole bar back. Down is away and up is back, which is the answer the shell's sheet already gives a drag. The header is the only place the flick is read — over the field a vertical drag belongs to the text it is scrolling — and it is the same strip the finger grabs in both states, so nothing the gesture put away is out of reach of the gesture that undoes it.

**A drag that has taken the gesture shows what it lands on, as a ghost.** The moment the travel passes the threshold, the body the flick is about to trade for is drawn as a schematic: a block for the field line, a square for the glyph beside it, and the capture block under them when there is text held. They are hairline boxes over the dither, in the muted ink, and nothing in a ghost is live — no glyph, no placeholder, no accent anywhere in it. A drag down the screen stands the ghost where the real body was, so the bar is already gone before the finger is. A drag up the stub grows it under the strip at the height the bar is about to take, which claims the room the bar wants before it arrives rather than after.

It appears whole on the frame the threshold is crossed and it leaves the same way; it does not fade, because every effect in this app is a flipbook and none of them interpolate. Letting go past the threshold commits. Letting go short of it, or losing the pointer to the system, takes the ghost away and leaves the bar in the state it was already in.

Putting the bar away drops the caret and closes the link line with it: a strip pinned over the keyboard outlives nothing. What was typed and what was attached are held and come back with the bar, because putting the bar away is not throwing a capture out. The selection bar takes the same slot and is never put away; ending the mode returns the capture bar to whichever of the two states it was left in.

**The scrim outranks the flick.** While the field has focus the scrim covers the header strip along with everything else outside the form, and a drag on it is the scrim's, not the strip's. The bar is put away from a Home nobody is typing on: the tap that drops focus comes first, and it is the same tap that has always closed the keyboard.

It stays away across a tab switch and across a route pushed over Home, and it is not written down. A phone picked up cold opens on a Home with something to type into, whatever the last session left put away. Only Home's bar is hidable — a project's detail captures into itself and its bar is always there.

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

The panel is one row per installed plugin that is off, bundled or not, in catalog order. The row is the plugin's name over what turning it on puts on the phone, derived from the plugin's own declared contributions and never written per plugin: a widget that can sit on Home is `<TITLE> CARD`, a widget that takes the input bar is `<TITLE> BAR`, a page pinned to the nav bar by default is `<TITLE> TAB`, any other page is `<TITLE> PAGE`, and a manual action is `<TITLE> ACTION`, or `<n> ACTIONS` when it declares more than one, joined by middle dots. Drops reads `DROPS CARD · CAPTURE BAR`, Projects reads `PROJECTS TAB · NEXT ACTION CARD`, Agent schedules reads `AGENT SCHEDULES PAGE`. The row's value is `OFF`, muted, and a tap on the row opens plugin management, which is where a plugin is turned on. `MANAGE PLUGINS` stays as the panel's text action under the rows.

With nothing left to turn on, because every installed plugin is already on and none of them puts anything on Home, the panel is the one line `ADD HOME CARDS, AN INPUT BAR, AND TOOL PAGES.` over the same action. A plugin whose contributions are none of the five kinds is not listed, because there is nothing the row could promise. Home does not turn anything on itself, and Drops and Projects stay off by default.

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

**An item that has been sent says so on that strip**, as the `SENT` tag the row carries, in the same label type, standing where a strip's affordance stands. The row's tag is what the eye finds in a list and the sheet is where the user goes to ask about one item, so the answer has to be on both; the strip says it in a word before the body says it in dates. It is the mark and not a verb: nothing happens when it is pressed, and it is absent on a sheet opened on a picker or a target.

The body is a readout. The full title in mono 13, unclipped, tapped to edit in place — which raises the keyboard and its toolbar — and saved on blur or submit. Attachments follow: links as rows, mono 11, showing a label or the host, tapped to open in the browser and long-pressed to delete; images as a row of 56px squares, tapped for a full-screen viewer that is black, pinch-zoomed and dismissed with back, long-pressed to delete behind the same confirm. Then `[ WITH ]` when the item has mates, `[ BLOCKED BY ]` when it is blocked, `[ EFFORT ]` when one is set, and `[ SENT ]` listing where each dispatch went, newest first.

The footer is one row of solid action blocks, and it is there for one-tap work when the keyboard is down: `DONE`/`UNDO`, `NEXT`/`UNSET`, `MOVE`, `PAIR`, `BLOCK`/`UNBLOCK`, and `DELETE` behind its inline confirm.

Done is also toggled without opening anything, by tapping the row's leading checkbox glyph — a 40px hit area — and the glitch and the row hold apply there too.

**Struck:** a separate action sheet on long-press. Long-press opens this same sheet. And this sheet is the only modal surface in the app; nothing else may be modal.

**Struck:** a `FieldPanel`, a `+ LINK` row and inline editors in the body. The body reads; the keyboard toolbar writes.

### A send goes on after its sheet closes

`SEND` closes the sheet the moment it is tapped and the send runs behind it, because an agent can take the whole of the send's deadline to come up and nothing about the item needs the sheet held open for that. While it runs, the row and the sheet's strip say `SENDING` where `SENT` stands, ahead of `PROMPT` and `SENT` and behind only the `NEXT ACTION` arrow, and the sheet lists it under `[ SENDING ]` as its destination and agent beside a spinner. A send that lands leaves that block, and the dispatch it recorded is what the row, the strip and `[ SENT ]` say from then on. A send that fails stays: the tag reads `FAILED` in red, and the line under `[ SENDING ]` gives the reason in red with `RETRY` and `DISMISS`. A retry hands the agent the same message, images and model the first try had; a later edit to the item is a new send.

The send is said from anywhere by one toast that follows it: `SENDING` beside a spinner over the agent and the item's title from the tap, held for as long as the agent takes to come up, and turned in place into `SENT` over the title or `FAILED` over the reason and the title with `RETRY` once it ends. On Home it is also a row at the head of `AGENTS`, before the pane it is starting exists. Several sends run side by side, and the tag reads `FAILED` only once none of the item's sends is still going.

### Filing an item is picking a target, and pairing is picking an item

`MOVE` opens a target picker: `DROPS` first, then every active project as a header row with its goals indented one level under it, then the paused projects. Archived projects are absent. Picking a project files the item as that project's drop; picking a goal files it under the goal. A bundle moves whole.

`PAIR` opens a picker of items — drops and items under goals, open ones first, newest first, with the item itself and its current mates excluded — over a search field. Picking one joins the two bundles into their union. When the item is already in a bundle, `UNPAIR` stands where `PAIR` was.

### A drop has no state but done and how loud it is

A drop is text plus attachments. It carries `done` and its priority step, and nothing else: no next, no blocked, no pair. Those columns stay in the schema — the row becomes a task the moment it is filed — but no surface reads or writes them while the item is a drop.

Its quick view is the readout with `DONE` and `MOVE` on the footer, and nothing else: no state line, no `BLOCKED BY` panel. Its row on Home carries the checkbox and the dimming that done drives, and no other glyph. That dimming goes a shade below anything the priority ramp reaches, so a done drop and one parked on the floor are told apart by the ink and not by the checkbox alone. Nothing in the app is ever struck through.

**A goal is optional grouping and not a requirement for state.** A project's `DROPS` panel holds that project's items that have no goal, and they are tasks: the same checkbox, the same checked-and-muted done state, the same blocked line as an item under a goal, the full quick view, a place in the project's and Home's progress numbers, and the right to be `NEXT ACTION`. Filing a Home drop into a project or a goal turns it into a task, and only then do the remaining state blocks appear.

### An item's text may be more than one line, and outside its sheet it is the first of them

The capture field and the title edit both take six lines and carry `↵` on the keyboard toolbar, so the text is whatever was typed, newlines and all. The sheet is where all of it is read: the body draws it unclipped.

Everywhere a row stands for the item — on Home, in a project, under `NEXT ACTION`, in a picker, as a toast's subject, as a mate under `[ WITH ]` — the row shows the first line that has text on it, clipped to the width as any long title is, and the number of lines under it follows in muted mono as `+2`. **The count is what tells a two-line item from a wide one**, because `…` says the width cut the line and says nothing about a line the user chose to end. One line carries no count, and a blank line is not a line here: it is spacing that was typed, and it is not counted.

A sentence that names an item rather than standing for it — an activity line — takes that same first line and no count, because a count inside prose reads as part of what the sentence says.

**What leaves the app leaves whole.** A copy and a send carry every line. Clipping is for reading a list and never for moving the thing.

**Struck:** the `…` alone. Every list ends a long title that way, so three lines of detail under a drop read as a drop that happened to be wide, and opening it was the only way to find out.

**Struck:** the newlines painted inline, as a glyph or a middot, so the whole text reads across the row. A row is one line of a list and the width is the width; a mark standing for a keypress inside prose is a second alphabet on the busiest surface in the app, and the middot already joins the parts of a path.

### An item carries the prompt it will be sent with, and its text is only the label

The text an item was captured with is a label: what the thing is, read off a row at a glance. The prompt is the instruction an agent is handed, written whenever the user has the words for it and kept until a send needs it. They are two fields because they are two jobs, and one line doing both does neither: a title long enough to brief an agent is a title no list can show, and a title short enough to read in a panel is a brief that has to be rewritten at the moment of sending.

**A prompt is optional and absent by default.** An item with none sends its text, the way every item did before there was a second field, and its sheet draws no prompt block at all: no empty block, no placeholder, no dash.

**`[ PROMPT ]` sits under the title on the quick view**, above everything else the readout carries, because it is what the item is for and the rest is what has happened to it. It draws the whole prompt unclipped, newlines and all, and it is a readout like the blocks under it: the body reads and the prompt is never tapped to edit.

**`PROMPT` on the footer is the way in**, standing immediately before `SEND`, because a prompt is written and then sent. It reads `EDIT PROMPT` once there is one. It takes the sheet over the way `MOVE` and `SEND` do — its own panel under the word `PROMPT`, `BACK` in the affordance, a six-line field with `↵` on the keyboard toolbar, and one `SAVE` block. `BACK` leaves what was already saved alone. **Saving an empty field is how a prompt is deleted**, and there is no second verb for it: an item whose prompt the user has emptied is an item with no prompt, and the app already draws that.

**A prompted item is tagged where a sent one is** — `PROMPT` in the row's trailing column and on the sheet's header strip, in the same label type, the mark and not a verb. It stands where `SENT` stands and wins over it when an item has both, because a prompt is what the item will do next and a dispatch is what it already did, and the sheet's `[ SENT ]` block still lists every dispatch in full underneath. The `NEXT ACTION` arrow still wins over both.

**A drop carries a prompt.** It is not state waiting on a project: it belongs with the attachments a drop already takes and the dispatches a drop can already make, and an unfiled item is the one most likely to be a thing to hand an agent.

**The prompt leads and the title follows it as context.** What goes out is the prompt, then `ITEM` with the item's text under it, then the links and the image paths as before. The agent is told what to do first and which row it came from second, and neither is wrapped in words the app put in the user's mouth.

**Struck:** the prompt composed inside the send flow, prefilled from the title. A send already asks for a host, a directory, an agent and a model; writing the instruction in the same breath makes the prompt a thing done under pressure rather than a thing prepared, which is the whole point of having one.

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

**The bar is the contextual action bar**, the way a file manager or a mail client does it: `×` on the left to cancel, `N SELECTED` beside it, and on the right three icons, a sheet of paper for copy, a forward arrow for move and a bin for delete, 22px with 44px hits, ink `--fg-dim` and accent on press. No text blocks. It takes the capture bar's slot rather than standing over it, so no panel on the screen moves when the mode comes on.

Move opens the target picker once and files every checked item. Delete opens a panel-style confirmation — `DELETE N DROPS?` with `CANCEL` and `DELETE`, the destructive one filled accent — and nothing is deleted before that second block. `×`, the back gesture, or finishing either action leaves the mode, and the selection never survives a navigation away from the panel.

A `DROPS` panel header also carries a `SELECT` text action on the right beside its count, in the tracked uppercase of `NEW +`. It enters the same mode with nothing checked: the bar reads `0 SELECTED` with every icon in the idle disabled ink until the first check — `--fg-dim` is brighter than that ink and would invert the state. `SELECT` is hidden while the panel is empty and while the mode is on.

Home's `DROPS` and a project's `DROPS` both have this. A row under a goal keeps its quick view.

**The selection bar stays where the thumb left it.** It is pinned to the bottom of the surface rather than riding the list, so scrolling through a long selection never takes the verbs off the screen.

### A copied set says where one drop ends and the next begins

`COPY` puts the checked drops on the clipboard in the order the panel draws them, on Home and in a project alike, and the bar reads `N COPIED` in place of `N SELECTED` for a moment. A drop's text goes out whole — every line the user wrote, no prefix, no indent, no marker on any of them — with only the empty space above and below it taken off, because that space is the boundary's job and the boundary is drawn by the app.

**A rule of three dashes on a line of its own stands between one drop and the next**, with a blank line on each side. A drop's links follow its text under a blank line, one per line. A single drop copies bare: there is nothing to separate, so there is no rule, and the clipboard holds what the item holds and not a character more.

**The rule is there because a blank line is not a boundary.** An item's text may run to several lines and may carry a blank line the user typed as spacing, so a set joined by blank lines alone comes back from the paste as more drops than went into it, and a second line reading `https://…` is indistinguishable from the next drop's link. What separates entries has to be a thing the text does not do by accident, and a blank line is the most accidental thing in it.

**Struck:** escaping a rule the user typed. A drop whose own text is a line of three dashes reads as two drops after a paste, and every fix for that — doubling the dashes, fencing each entry, prefixing every line — puts a syntax in front of text whose whole point is that it comes out the way it went in. What is on the clipboard is read by a person and never parsed back.

**Struck:** a bullet or a number leading each drop. It is unambiguous and it is a list the user did not write: the first line of every drop comes out altered, and the alteration has to be picked off by hand wherever the text is going.

### Search finds any item, from Home, and narrows it with marks

The search glyph in Home's breadcrumb row pushes `SEARCH` over Home with no nav bar, the keyboard already up on a field at the top. It reaches every item the phone holds — Home drops, a project's drops and the items under goals — newest first, and an item under a hidden project is absent here as it is from Home. With Projects off it reaches the unfiled ones only, because a filed item's place is Projects' to say.

**The field matches words, not a phrase.** Every word typed has to appear somewhere in the item's text, its prompt or one of its links, in any order and any case. An empty field with no mark lit lists everything.

**Under the field is a row of marks**: `ATTACHMENT`, `IMAGE`, `LINK`, `PROMPT`, `SENT`, `OPEN`, `DONE`, in the tracked uppercase of a panel header. A tap lights one in the accent and a second puts it out, and every lit mark has to hold along with the words. `OPEN` and `DONE` put each other out, since both lit would match nothing. Each mark carries the number the list would hold with it flipped, so a mark that would empty the list stands in the disabled ink and does not take a tap.

The hits sit in one `ITEMS` panel with the count on its header. A hit is the same row the item has in its own list — checkbox, priority, tags, the slide — with its place under the title as the crumb the quick view carries, `DROPS` or `INFRA / REDUCE SAAS`, and a tap opens the quick view over the search. `NO MATCH` stands when the words and marks leave nothing, `NOTHING CAPTURED` when there is nothing to search.

**Struck:** typed filters, `has:image` and the like. The colon is a trip to the symbol layer of a phone keyboard, and a syntax hides its own vocabulary until someone reads about it. The marks show everything search knows, one tap each, and leave the field for words. Both at once would be two states for one filter that have to agree.

**Struck:** search as a field on Projects. Most of what is searched for is a drop, and drops live on Home.

### A slide sets how important a row is, and a numeral carries it

Every item row and every project row takes a horizontal slide. A slide left raises the row one step, a slide right lowers it one step, and the row snaps back to where it was either way. One gesture is one step, so the top is three slides up from the floor.

There are four steps and three of them are counted in Roman numerals. The numeral has a column of its own on the right of the title, in the kicker's mono at the kicker's size, right-aligned so `I` and `III` end on the same edge:

- **The floor only subtracts, and it has no numeral.** The title goes muted and the checkbox goes with it, the age stays where every other step already leaves it, and nothing whatever is added. A row parked here is the quietest live row in the panel, and it is the one step read by what is missing.
- `I` is the row exactly as it draws otherwise, its numeral in muted ink. It is where a captured item and a new project land.
- `II` warms: the numeral and the title take the amber at half strength.
- `III` is that same amber at full strength, on the numeral and on the title.

**The numeral column is held whether a numeral is drawn or not**, so a row on the floor sits in the same grid as a row at the top and stepping one row moves no neighbour by a pixel. Its width is the kicker's own line and not the three characters as they were first drawn: the numerals are read at the reader's text size and a column fixed at the one wraps `III` onto a second line the moment that size rises, which grows the row and shoves the panel. Whatever is in the column stays on one line and is cut at the column's edge before it is ever allowed to wrap.

**The glitch is progressive and it is on the numeral alone.** `I` and the floor are still. `II` tears every few seconds, lightly and in few blocks. `III` tears about twice as often and in more of them, so the top of the scale is the thing in the panel that will not hold still. The corruption is seeded off the row's own id, so two rows on the same step never tear in lockstep, and the glitch never leaves the numeral's box: it marks the rank and not the title. Reduce-motion freezes all of it, and the ramp still reads, because it was a numeral before it was an effect.

**Every step is the same type at the same size.** No step changes the title's size or its weight, and none of them touches the age, the checkbox, the progress or anything else on the row. The ramp is one colour getting stronger — the numeral, the title's ink and the numeral's glitch — and the panel is a grid before it is a ranking.

**The ramp is amber and it never reaches the accent.** The accent is what the app answers a tap with, and a rank nobody pressed does not get it; the ramp is one hue warming from the body ink through half-strength amber to full, so a panel is read by which lines are warm and how warm they are rather than by four colours that have to be learned. The floor's grey is the same ramp one step colder.

Done still wins, and it wins by going one shade colder than the ramp can reach. A done row takes the disabled ink on its numeral, its title, its age and its checkbox, and stops glitching, whatever its step, because the step says what is worth reading and a done row is not. **The disabled ink is done's and nothing else's**: no step lands on it, the floor stops one shade above it, and a finished row is therefore never read as a quiet one. A fresh row keeps its accent age for as long as it is fresh — that highlight is about the capture that just happened and not about the rank — and the checkbox and the title carry the done state under it.

The row travels under the finger while the drag is on, capped short, and returns over 140ms. **A slide with nowhere to go does not move the row at all** — right at the floor, left at the top — so the end of the scale is felt instead of announced. The recogniser is horizontal only, so the list still scrolls under the same thumb, and the system's own edge gesture keeps the screen edge.

**A slide changes how a row reads and never where it sits.** Drops stay newest first and items under a goal keep their order. A project row is the exception and not a new rule: the projects list already sorts by priority under status, so a slid project does move in it.

The step is per item, and a bundle does not share it. Mates travel together when they are moved and are slid one at a time.

**The project form has no priority field.** The slide is the whole gesture, so a row is the only place priority is set, for a project exactly as for an item, and a picker would be a second way to say the same thing. The quick view has no priority block for the same reason, and the activity feed records the direction — `raised`, `lowered` — and never the step.

The slide is off while a panel is in selection mode, and the `NEXT ACTION` card does not take it: it is one card and not a list.

**Struck:** a numeral on the floor, a step that grows the type or thickens it, a glitch on anything but the numeral, a slide that cycles from the top back round to the floor, a drag whose distance picks the step, and a step that dims a row as far down as done.

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

The row carries the checkbox every other row carries. Same column, same forty-pixel target over the row's corner, same glitch on the glyph as the state turns over, and the same muted title afterwards. A finished drop stays on DROPS: the panel is the whole of the unfiled, done or not, and a row that vanished under the finger would take the undo with it and leave the user with nothing to aim at. The age stays in the value column, because a drop has no project and no goal to say where it is, and when it was written down is the only thing the column can hold. Finishing one raises a toast that names it and carries `UNDO` for eight seconds; the checkbox is the other way back and it never expires.

The quick view names it on the footer of every item. `DONE` is the first block and takes the one filled accent surface in the row, `UNDO` when it is already done, and it draws for a filed task and a stray drop alike. The sheet's title dims with the state wherever it is opened from.

Nothing else follows it in. An item unfiled by MOVE keeps whatever `isNext` and `blockedReason` it had in the schema, so the row and the sheet suppress them rather than trusting the columns to be empty: no forward arrow, no blocked line under the title, no NEXT, PAIR or BLOCK on the footer. Done is the exception that was asked for, not a door the rest of the state walks through.

Struck: a `DONE` verb on the multi-select bar. Its verbs are the ones worth doing to a set — copy the text out, file them all under a project, delete them — and finishing things is done one at a time, by the row the eye is already on.

Struck: `done` in the toolbar extras behind `+`. That row exists for what cannot be reached while the keyboard is up, and the footer under the keyboard is exactly where DONE already is.

## Hosts and keys

### A key is made on the phone and never leaves it

A key row is the name over a truncated `SHA256:…` fingerprint in mono. A tap opens the key's detail — `[ NAME ]`, `[ TYPE ]` reading ed25519, `[ PUBLIC ]` as the full `ssh-ed25519 AAAA… name` line in a selectable mono field with `COPY` beside it, `[ USED BY ]` listing the hosts that reference it, and `DELETE` at the bottom behind a confirm.

A new key is a form with `[ NAME ]` and nothing else: ed25519 always, the comment being the name. It is generated on the device. **The private key never leaves the phone and is never shown** — the row lives in a `keys` table of id, name, public key and creation time, and the secret lives in the platform's secure storage under the key's id, behind the Android keystore.

**A key in use cannot be deleted until the host is repointed**, and the bar says so: it reads `USED BY N HOST(S)` where `DELETE` would be, rather than sitting there greyed and silent.

Installing a public key on a host is the user's own job, done by hand. The app never writes an `authorized_keys` anywhere, with one exception: the Linux it runs on the phone itself, which is the app's own files and no one's machine.

### A host is a machine, not an integration

The `hosts` table is id, name, address, port, user and key id. A host is a machine that happens to run things; what the app is allowed to do there is a separate list.

The host form carries an `[ INTEGRATIONS ]` block, one checkbox row per integration the app knows about, its name over what it gives: `HERDR` · `Agents in its herdr panes`, `AGENTS` · `Agents heard from their own hooks`, `VNC` · `Its desktop, tunnelled through ssh`, and `DEVICES` · `Its emulators and simulators`. `VNC USER` and `VNC PASSWORD` sit in the same block under the rows while `VNC` is checked. The form is drawn in the house's own rows: `CANCEL` beside the bar and `DELETE HOST` in warning are action blocks, never stock buttons or switches. **The transport behind an integration is the integration's own concern** — nothing in the schema names ssh — so a later backend that proxies one swaps the transport and leaves the host row and the integration row alone.

**No host is ever assumed.** The app connects to a machine because the user entered it and switched something on, and to nowhere else, ever.

### A host has a port, and the row says so when it is not 22

`hosts.port` is an integer defaulting to 22. A host row reads `user@address` when the port is 22 and `user@address:port` when it is not. The form has a `[ PORT ]` field between the address and the user, numeric keyboard, `22` prefilled on a new host.

Without it every machine whose sshd is not on 22 reads as unreachable no matter what its address says — and a machine whose 22 is a tarpit reads as unreachable while being perfectly up.

### The host form never hides its way out

The form needs a name, an address, a port, a user and a key. **The action bar is always drawn.** While the form is invalid the bar is dimmed and its label names the first missing part in field order — `NAME MISSING`, `ADDRESS MISSING`, `PORT MISSING`, `USER MISSING`, `KEY MISSING` — and a tap does nothing. A port that is empty or outside 1–65535 reads `PORT MISSING`. When the form is valid the bar reads `CREATE HOST` or `SAVE`. The label updates on every keystroke and every picker tap.

The convention of hiding a bar until the form is valid is fine where the only requirement is the field on the screen. It is not fine here, because one of the requirements is a tap on a picker row: hiding the bar hides the requirement, and the user fills everything they can see, finds no action, and leaves.

**`[ KEY ]` preselects the only key** when exactly one exists and the host is new. With two or more, nothing is preselected — a picker with one entry reads as already chosen, and a picker with several does not. Editing a host keeps that host's own key. The block is a row per key, its name over its fingerprint, the chosen one with a check at its end, and `CREATE SSH KEY` as its last text action. With no keys at all the rows are one dim line, `NO KEYS YET`, and the bar reads `KEY MISSING`.

**Leaving a dirty host form asks.** The back arrow or the back gesture raises `DISCARD HOST?` with `DISCARD` as its confirm. Dirty means a new host with any field typed, any key the user picked themselves — one the form preselected is not a pick — or any integration switched on; or an existing host with any value changed from what was loaded. A clean form leaves without asking, and a save or a delete pops without asking. This is the host form's rule alone: the key and project forms keep their silent back.

### A failure names the host, and names which kind of failure it was

`unresolved` is the address failing to resolve, before any socket opened. `unreachable` is everything after a name. The underlying error is written to the debug log with the host's name on every failure, so a report from a handset can be read without guessing.

### MACHINES is the tab for machines, and everything running on them

A card per host, then `ADD A MACHINE`; `CODE` is the second segment. A card is the host's mark and name with the `LINK` word on the right — in warning when the probe failed — over `user@address`, the port after it when it is not 22, and under that what the machine can do right now as accent text actions: `SHELL`, with the worst state dot and `· <n> OPEN` once sessions exist, `DESKTOP` when VNC is on, which floats its desktop at once, and `DEVICES` when devices are on, which opens the screens list. `DETAILS` and a tap anywhere else push the host's panel. `MANAGE SSH KEYS` and `SCREENS` sit in the header.

**`ADD A MACHINE` is one panel with a row per way in**, each a glyph, a name, a line saying what it is and an arrow: `ADD HOST` · `A machine you reach over ssh`, which pushes the host form, and `LINUX ON THIS PHONE` · `Its own Linux, run as an app without root`, which raises the system picker. With no host registered the panel is the whole tab, a line over the rows reading `No machines yet. Add one you reach over ssh, or run Linux on this phone.`

Struck: a shelf of live terminal miniatures over the cards. Open shells are already counted on their host's `SHELL` and resumed from the parked bar, and a row of thumbnails was a recents screen pushing the machines down the tab.

The host's panel has its own header strip carrying the host name and `EDIT` on the right, which pushes that host's form. The body is metadata rows: `ADDRESS` as `<address>:<port>`, `USER`, `KEY` naming the key, `INTEGRATIONS` as mono tokens of whatever is on or `NONE`, and a `STATE` row carrying the host's latest agent outcome when the agent integration is on — `3 agents · 1 blocked`, or the reason line in its colour.

Under the host panels, a `KEYS` panel: a row per key, name over the shortened fingerprint, tapping into the key's detail, with `ADD KEY` as its last text action. **Hosts come first because they are what the tab is for.** Keys were listed first in SYS only because a host cannot be saved without one, and that rule now lives in the form.

Nothing on this tab edits in place. The form is the one editor. SYS keeps `[ STATIC ]`, `[ ALERTS ]` and `[ BUILD ]` and has no host or key block of its own.

### A host is drawn with the mark of the system it runs

A list of machines that are all the same name in the same face reads as one machine repeated. Each host carries a mark for its operating system: the NixOS snowflake, the Apple apple for macOS, Ubuntu's circle of friends, the Arch peak, Alpine's mountains in a hexagon, and for anything else a single rack unit. It sits before the name on the host's card in `MACHINES` and in its panel's header strip, and before the name on its group's label in the tab strip.

A scoped exception to never shipping a third-party mark, like the agents' marks, and narrower than theirs: the vendor marks are the vendors' own silhouettes, solid, in `currentColor` and never the vendor's colours. A redraw in the house stroke read as a near miss of the marks, so these are the family's only filled glyphs. They are `hl-system-nixos`, `hl-system-darwin`, `hl-system-ubuntu`, `hl-system-arch` and `hl-system-alpine` in the icon index under their own heading, and nothing else in the family borrows from them. The rack unit is the family's own `hl-system-server`, one unit where `hosts` draws two.

**A host the phone runs draws its system on a phone's screen.** `hl-phone-frame`, a phone's outline with a rule across its chin, takes the mark's whole square, and the system's mark sits on the screen at half the size, wherever such a host's mark is drawn, so a system the phone runs is told from the same system on another machine at a glance; the picker that installs one draws it on every row. Struck: the phone cropped to half its width beside the system's mark, which read as a broken box rather than a phone.

**The system is learned from the host, never typed.** The first time a shell to a host goes live in a run, a second channel on the same connection asks `uname -s` and reads `/etc/os-release`: `Darwin` is macOS, Linux with `ID=nixos` is NixOS, `ID=ubuntu` is Ubuntu, `ID=arch` or Arch Linux ARM's `ID=archarm` is Arch, `ID=alpine` is Alpine, and every other answer is the rack unit; `ID_LIKE` is not read, so a derivative keeps the rack unit rather than borrowing its parent's sign. The answer is written to `hosts.system`, a nullable column with no backfill, so a host no shell has reached yet draws the rack unit until one does. An exec that fails is no answer and is asked again on the next shell. The form has no field for it: a picker would be a second source that can disagree with the machine, and the link probe cannot answer it, since it reads the banner and never authenticates.

### `LINK` says whether the machine answers at all

A metadata row above the shell row on each host panel. `—` before the first probe, `PROBING` while one is out, `<software> · <n> MS` when the machine answered — `OPENSSH_9.9 · 120 MS`, the software token taken off the identification string and uppercased — or the failure word in warning: `NO ROUTE`, `UNRESOLVED`, `REFUSED`, `NO BANNER`.

The probe is a TCP connection to the host's address and port that reads the identification line and hangs up, on a four-second deadline, with no key and no handshake. **It waits for the banner rather than settling for the connection**, because a port that accepts and then stalls is a tarpit and not a shell. Rows that name the same address and port share one probe: three logins on one machine are one machine, and three connections at once can overflow a small accept queue and stall one of them past the deadline. It runs for every host when the tab comes to the front, at most once every thirty seconds per host, and on a tap of the row, which probes again whatever the age.

### A machine is verified before it is trusted, and a changed key is refused

Every ssh dial in the app — the shell, the screen's tunnel, the agent poll — verifies the remote's host key against one pinned on the host row and refuses when it does not match. The pin is a key type, a fingerprint in the OpenSSH `SHA256:<base64>` form and the time it was pinned. Those columns are nullable with no backfill: a host registered before the pin existed is unpinned and pins on its next connection. They say *host key* and not *ssh* on purpose — they identify the machine, not the thing running on it.

**Only a route the user is looking at may ask.** An unknown key pauses the dial and raises the confirm sheet — header `NEW HOST KEY`, the host name and `<address>:<port>`, the key type and the full fingerprint in mono, wrapped, then `REJECT` and a filled `TRUST`. That happens on a shell the user opened, on the screen route, and on `VERIFY`. The agent poll, the alert watcher and a reconnect never ask: they refuse an unpinned host and report `host key unverified`, which shows beside the host with `VERIFY` next to it.

**A changed key is refused everywhere, always, with no override on the connect path.** The line is `host key changed`, in warning. The only way past it is `[ HOST KEY ]` on the host form — the pinned type and fingerprint, when it was pinned, and `FORGET KEY` behind a `FORGET HOST KEY?` confirm, which drops the pin and lets the next connection pin whatever answers. A changed key is either a machine reinstalled or a machine in the middle, and the app cannot tell which; the user can.

### The deadline is on the machine, not on the user reading a fingerprint

The dial's timeout is armed at the connect and disarmed the moment the key arrives, so a sheet can stand open as long as the user needs. The transport's own deadline is set out of the way. The dial returns once the key has been answered for; authentication is never what it was waiting for.

The same holds for the authentication the shell, the screen and a workspace pane wait on after the dial: its clock stops while the sheet stands and starts over, whole, once the key is answered for. A user who reads the fingerprint for a minute and taps `TRUST` gets a login, not `timed out`.

A socket that opens and then says nothing is its own failure and not silence: that is a machine behind a tarpit, not a machine that is down.

### `VERIFY` is the whole report, in the row that was tapped

`VERIFYING` while a dial is out, and then the word it came back with when it failed — `NO ANSWER` for a socket that never presented a key, `NO ROUTE` for one that never opened, `KEY CHANGED` for a fingerprint that is not the pinned one, `NO KEY` for a host whose private key the keystore no longer holds, `FAILED` for the rest — in warning, standing until the next tap. A user who taps `REJECT` said no on purpose and gets `VERIFY` back, not a failure.

**Nothing is written only to the debug log.** A handset has no way to read one.

**A dial that came back clean is an answer.** A machine that presents the key the app already trusts refuses nothing and asks nothing, and the row takes that as the answer it dialled for: the affordance goes, whatever a background poll still says. The row's own dial outranks a poll it does not re-run.

**Saving a host dials it.** `CREATE HOST` and `SAVE` verify the machine themselves when the host has no pin, before the form is left, and raise the same sheet; the bar reads `VERIFYING` while that is out. Every failure leaves the host saved and unpinned with `VERIFY` on its panel — a machine that is not answering while a form is being filled in is not a reason to hold the user on the form.

**The pin travels with the host into the watcher.** A service that rebuilds a host without its pin dials with a verifier that has nobody to ask and refuses the machine on every tick. A pin that appears or changes is a different dial, so the loop already running under the old one is stopped rather than left refusing a machine the user has already stood in front of and trusted.

### Every ssh connection is kept alive once a minute

One interval for every connection the app holds — the shell, the agent client and watcher, the screen, the devices, the workspace, the host-key check, the plugin hosts — and it is sixty seconds, with no setting. It is what keeps the far side and every NAT between from forgetting a connection that is idle, and each one is the radio waking, so it is as long as that allows and set in one place. One keepalive unanswered is not an error. Three in a row, with nothing else heard from the machine between them, is a dead link, ended for everything riding it, three to four minutes after it went. Three and not one, because a connection outlives a minute in a tunnel and a plain shell ended for being quiet is not given back. A shell the user is typing into does not wait that long: a key the machine does not answer runs a round at once, and the link is found dead in about ten seconds. Nor does a tap that rides a connection already held — a send, an answer from a notification, a new tab, a paste: it runs a round first, and when nothing answers in five seconds it dials a connection of its own rather than wait minutes on a socket nothing reads. The silent one is not ended for that: whatever else rides it, a plain shell among them, keeps it until its own three keepalives go unanswered, and it closes once the last of them lets go. A plain shell's own tap never dials, since a new connection would not carry its terminal; it fails and waits like the rest.

**The agent list, the send, the path, model and launch pickers, the engine, the devices, the screen, the workspace, the files sheet and the plugin hosts share one ssh connection per host**, opened by the first of them to ask, held thirty seconds past the last one done with it, and dialled again once, for all of them, when it drops. A channel the host refuses because that connection already carries all it allows fails only what asked for it, as `host busy`, and the connection stays.

**Every connection is opened in one place, and only two are not the shared one.** A terminal tab rides the shared connection unless it was opened on one of its own, and then it dials one that nothing else rides and that ends with the tab, so a tab that redials on it never drops what everything else is riding. The host-key check dials one that hangs up once the key is answered. The watcher and an answer from a notification run where the app's connections cannot reach, so each holds one shared connection per host of its own, by the same rules. A test fails the build when anything else opens a connection.

### A host's files move both ways, from anywhere

**`[ FILES ]` is one sheet per host**, opened by `FILES` on the host's panel, by a hold on the panel's header, and by `FILES` on the shell's tab strip for the host of the active tab. It is a tree rooted at `~`, folders first and dotfiles after the rest, a tap opening or closing a folder and `reading…` or `could not read it` under one that has not answered. A linked folder opens like any other. A host that cannot be reached says why, over `RETRY`. The foot of the sheet names the folder last opened and still open, from `~`, its own name in full, beside `UPLOAD`; closing it or a folder above it moves it to the closed folder's parent, and closing `~` leaves it at `~`.

**A file is shared, saved or sent.** A tap or a hold on one offers `SHARE`, which pulls it to the phone and hands it to the Android share sheet; `SAVE TO PHONE`, which pulls it and asks the system where to write it; and `SEND TO HOST`, which asks for a host and then a folder on it, pulls the file to the phone and puts it there. **A hold on a folder offers `UPLOAD HERE`**: the system's document picker, any number of files of any kind, each written under its own name. It also offers `REFRESH`, which reads the folder again. The sheet's link sleeps with the app, the document picker included, and the next tap opens it again where the tree was rather than reading every folder as unreadable. A name the folder already holds is never overwritten; the newcomer becomes `name (2).ext`, and up. A folder that cannot be read takes nothing, since its names are unknown; the batch says `could not read the folder`. **A batch starts whatever else is moving**: the sheet draws every batch of its host as `[ TRANSFERS ]` does, and its `STOP` stops all of them. A batch that ends with a file failed or stopped offers `RETRY` beside its line, which moves those files again and only those. **An upload's retry outlives the sheet**: the batch keeps the phone's copies of what did not land and stays on the bar with `RETRY` and `DISMISS` until one of them is tapped, a retry taking the batch's place in the list; a file whose copy the phone has lost fails as `the phone copy is gone` and is not offered again; a pull's retry goes with its sheet, which is where the file was going, and one tapped while the host is unreachable reads `RETRYING` while it reconnects, once however many are tapped, and stays offered if it cannot.

**Picking a folder is the same tree.** Where a transfer needs a destination the sheet opens as `[ PUT HERE ]`: a tap on a folder opens it and makes it the target, drawn in the accent and named over a `PUT HERE` block that stays at the foot of the sheet however long the tree runs, and a hold puts the files there at once. Files are drawn dimmed and take no tap.

**Striked is a share target.** "Share" in any app offers it, for one item or many, of any type, and for plain text. What is shared is copied into the app's cache while the sender's grant lasts, and the app opens on `[ SEND TO HOST ]`: what came in, the hosts, and once one is picked, `CLIPBOARD` and `FOLDER`; a phone with one host has it picked already. An item the sending app would not let be read is counted as `1 UNREADABLE` beside what came in, and the sheet stays open on what it sent, `COPIED · 1 UNREADABLE`, rather than closing as if all of it went; a share none of which could be read opens on that count and `CLOSE`, with nothing to send, rather than not opening at all. `FOLDER` asks for a folder and writes each file there, and shared text as `shared-<date>-<time>.txt`. **`CLIPBOARD` puts text in as text and anything else in as a path**: a single picture goes onto the host's clipboard as that picture, of its own type; every other file lands under `/tmp/striked` and its path goes onto the clipboard, one per line with any shared text. A host whose clipboard cannot be written still has the files, and the sheet lists where; `CLIPBOARD` again tries the copy with those files and does not send them twice. A file whose phone copy is gone is left off the clipboard and off every retry, and a copy that fails beside it still says why; when lost copies are all that failed, the rest is done and the sheet stays open on `COPIED · 1 FAILED` or `IN <folder> · 1 FAILED`, or only `2 FAILED` when nothing went. The copies are deleted once they are on the host, and a batch that did not finish offers `RETRY` as `[ FILES ]` does, there and in `[ TRANSFERS ]` after the sheet closes; a new destination takes the batch over rather than sending beside it. `CANCEL` becomes `CLOSE` once anything has started moving, since closing no longer stops it.

**`ATTACH` takes any file too.** `PHONE` beside `PHOTOS` opens the document picker; a PNG goes in like a photo and anything else lands under `/tmp/striked` with its path typed at the cursor.

**Every one of these is the same queue.** Three files move at a time, the lightest first, on the transfer link, over sftp or exec as an upload does, and each is drawn as the `ATTACH` queue draws a picture, `DOWN 43%` for a file coming to the phone. A file is written whole or not at all, on the phone and on a host alike, so a retry lands under the name the first try had; over exec the part is renamed only once it holds every byte, whether or not the host's shell heard the stop. The share sheet is only ever handed what the app put in its outgoing cache, read-only; the cache sweeps anything older than a day.

**A transfer goes on when its sheet closes, and is seen from anywhere.** While anything moves a bar sits above the nav bar: `UP 2 · DOWN 1 · QUEUED 3`, a file counted up or down only while it moves, the progress, the percent and the rate, `1.2 M/s`, over the last three seconds. Over the shell the bar would take rows from the terminal, so there it is a badge in the terminal's top right corner, `UP 2 · 34%` over its progress. A tap on either opens `[ TRANSFERS ]`, each batch by what it is doing and to which host, drawn as its queue, with `STOP` beside a batch still moving and `RETRY` beside an upload that ended short. The status bar carries the same as a progress notification, `UP 2 · 34%` over the rate and `4 M of 12 M`, with its own `STOP` for everything moving; a tap on it opens `[ TRANSFERS ]`. Once the last batch ends it says `MOVED 3 · 1 FAILED · 1 STOPPED` and can be swiped away. A phone that has not allowed the notification gets a line in `[ TRANSFERS ]` saying so, with `ALLOW`; nothing asks on its own. A finished batch stays on the bar for four seconds, `DONE` or `STOPPED`, and goes; a batch with a failure stays, `1 FAILED` in red, until `[ TRANSFERS ]` or that host's `[ FILES ]` has been opened and closed, then goes four seconds later; a batch that can still be retried stays until it is, and the bar counts it apart, `DONE · RETRY 1`, so a later batch's word still shows. A clipboard or text step that fails once its files are up marks the batch `FAILED` with the reason, and for the clipboard where the files are, so a sheet closed early hides nothing. The files and send sheets keep their status line and `STOP` pinned beside their actions. A stop lets no queued file start, cuts the ones moving, and removes the part an upload had written; a stopped file counts as stopped, not failed.

**An action that ends a sheet never scrolls away.** Where a sheet's list can run past the screen — the host list of `[ SEND TO HOST ]`, the folders of the path picker, the models of a send — its actions stay pinned under it.

### The phone is a host too, running Linux of its own

`LINUX ON THIS PHONE` is always the second row of `ADD A MACHINE`. A tap raises `LINUX ON THIS PHONE` — `Adds this phone to your hosts. It runs as an app, without root.` — over a `NAME` field holding `PHONE`, or `PHONE 2`, `PHONE 3` and on when a host already has that name, which the user may change, and one row per system, each with its vendor mark on a phone, its name and what it costs: `UBUNTU 24.04` · `apt · about 70 MB to download`, `ARCH LINUX ARM` · `pacman · about 160 MB to download, 840 MB unpacked`, and `ALPINE LINUX 3.24` · `apk · about 4 MB to download`. A tap on a row chooses it, with a check at its end, and Ubuntu is chosen when the sheet opens. `CANCEL` closes the sheet and `NEXT` turns it to its second step, `LINUX ON THIS PHONE · PACKAGES`, **so the system is chosen before what goes on it**. Each later step opens on what came before, one row with the system's mark on a phone, the name, and the system, `PHONE` · `ALPINE LINUX 3.24`, and `CHANGE` at its end; a tap on the row or on `CHANGE`, or `BACK`, returns one step with every choice as it was. Under it a `PACKAGE MANAGERS` group: the system's own first, fixed, `APK` · `Alpine's own · always there`, then, unchecked, a `NIX` checkbox — `Its own glibc, for root · about 25 MB to download`. `NEXT` turns to the third step, `LINUX ON THIS PHONE · TOOLS`, whose row adds `NIX` when it was checked, `ALPINE LINUX 3.24 · NIX`. Under it the tools in a `MULTIPLEXERS` and an `AGENTS` group, every box unchecked so a system comes bare unless the user asks: `TMUX` · `The terminal multiplexer · about 1 MB` and `HERDR` · `The agent multiplexer · about 27 MB`; `CLAUDE CODE` · `Anthropic's coding agent · about 250 MB`, `CODEX` · `OpenAI's coding agent · about 370 MB`, `CURSOR AGENT` · `Cursor's coding agent · about 550 MB`, and `OPENCODE` · `The open coding agent · about 190 MB`. Cursor Agent ships a glibc build that Alpine's musl cannot load, so with Alpine chosen and no Nix its row is muted, reads `Needs glibc: choose NIX in the previous step, or pick Ubuntu or Arch`, and takes no tap. `INSTALL` installs the chosen system with what is checked. **The phone holds as many systems as the user installs**, each its own host with its own files, key and port, any number of them running at once, each started, stopped and removed on its own; two of the same system are two machines that share nothing. **The sheet's foot counts what the choices cost**: `STEP 2 OF 3 · ABOUT 95 MB IN ALL` over its actions, the system, Nix when checked and every checked tool that fits added up again at every tap. The row reads `PREPARING` on its right while the host is made and `FAILED` in warning when that did not happen.

**It is a host like any other, at `root@127.0.0.1`.** Every install makes a key and a host named what the field held, the name it was offered when it was left empty, on a loopback port picked at random from 20000–39999 and held by no other host, since the low ports other apps on the phone listen on are the ones a fixed choice would meet. The system's image is unpacked in the app's files and runs under PRoot, which needs no root: Ubuntu's base image, on which setup installs `openssh-server` with apt and nothing else, proot-distro's build of Arch Linux ARM, which carries openssh already, or Alpine's minirootfs, on which setup adds `openssh` and `tzdata` with apk. Each image is a pinned release checked against its digest. Each system lives in its own directory and is never moved, since PRoot keeps hard links as absolute paths; the one a phone held before it could hold several stays where it was and stays its host's.

**Nix is laid on any of them, single user, for root.** The app downloads Nix's own release tarball, pinned like the images, moves its store into `/nix/store` and registers it, and puts Nix and its certificates in root's profile; it does not run Nix's installer, whose copy needs GNU tools Alpine does not have. `/etc/nix/nix.conf` turns the sandbox, the syscall filter and the build users off, which PRoot cannot give, and turns flakes on. A login shell finds `nix` through `/etc/profile.d/nix.sh`. Nothing more of Nix is laid on: Home Manager, a flake for the home, or anything else Nix can bring is the user's to install. The host carries the system's mark from the install on, before any shell has probed it. Everything past the dial — tabs, the launch picker, files, the link probe — is the same ssh every other host gets, and the system is its package manager's to grow: a user who wants python or git installs it.

**What is offered is one file.** `assets/linux/catalog.json` holds each system's name, package manager, C library, image, digest, cost and the packages its setup and the install scripts need, Nix's cost, and each tool's name, line, cost, C library and where it comes from on each system. The sheet and the system's own install both read it, so a new release, a new cost or a new tool is an edit to that file and not to the app's code, and a tool the file no longer names keeps its place in a system that has it, named by its id. `just linux-catalog` refreshes the installer digests and the pinned nixpkgs revision from upstream. A tool fits a system whose C library it was built for, where a repository holds it or its maker's script runs. The file carries a version the app reads, and a file whose values are not plain names, https URLs or absolute paths is refused when the app loads it, so no value in it becomes a command. A tool may carry files the system is given where it has none, as Claude Code on Alpine carries its settings.

**A tool is the system's own package where the system carries one, and only Cursor Agent on Alpine needs Nix.** tmux comes from apt, pacman or apk, and OpenCode from pacman on Arch, the one system whose repositories hold it for arm64. Where no repository holds a tool — herdr, Claude Code, Codex and Cursor Agent on all three, OpenCode on Ubuntu and Alpine — the app fetches its maker's install script itself and runs it only if it matches the digest the file pins; a script changed upstream is refused as changed since this release, and the tool's row offers it again once a release carries the new digest. Each is linked into `/usr/local/bin` so a shell or an exec finds it without a login profile; the agents update themselves from there. The script's own needs come first: curl and its certificates where the system has no curl, and on Alpine bash, libgcc and libstdc++, which OpenCode and Claude Code load, plus ripgrep for Claude Code, whose bundled ripgrep is a glibc build, so a fresh `/root/.claude/settings.json` turns it off with `USE_BUILTIN_RIPGREP=0`; one already there is left alone. On Alpine with Nix, Cursor Agent is nixpkgs' own build, glibc included, from the nixpkgs revision the file pins: Nix builds it into a root under `/nix/var/nix/gcroots/striked`, so garbage collection keeps it, and links it into `/usr/local/bin`. Tools are installed once the system is, so a tool that fails leaves the system installed and its host whole. Each tool is written into the system's ready mark as it lands, so what a system has survives the app.

**The system is started by whatever dials it.** Opening a tab on a host the phone runs, a tab restored after the app was gone, and the launch picker all start sshd first and wait for its banner; a reconnect does not, so a system the user stopped stays stopped. The user's own `START` does, and brings that host's tabs that are down back with it. The start writes the one key sshd lets in into the system's own key file every time, so a key the app replaced is never locked out, and pins the host key setup generated, so the user is never asked to trust their own phone. **A running system is a foreground service**, one for all of them: `LINUX · RUNNING` in the shade, `LINUX · 2 RUNNING` while two run, with `STOP`, which stops every one. A stop of one system ends only its own processes, told from another's by the system's directory they stand in or the PRoot they descend from. The zone is the phone's, so the first package that pulls tzdata does not stop an install to ask.

**The host's panel carries the system.** A `LINUX` row reads `DOWNLOADING 43%`, `UNPACKING`, `INSTALLING SSH`, and `INSTALLING NIX` while the install runs, the failure in warning with `RETRY`, which tries the same system with the same choices again, `NOT INSTALLED` with `INSTALL`, which raises the system picker, `RUNNING` with `RESTART` and `STOP`, and `STOPPED` in warning with `START`. A `SYSTEM` row reads the installed system's name, `UBUNTU 24.04`, `ARCH LINUX ARM` or `ALPINE LINUX 3.24`, with `REMOVE` in warning, behind `REMOVE LINUX` — `Deletes the system with every file in it, and the <name> host.` — which deletes the files, the host and its key, and leaves every other system as it was. The host form's `DELETE HOST` on such a host does the same, its confirm carrying that line. A `NIX` row follows when Nix was installed with the system, reading `INSTALLED`. A `TOOLS` row reads what the system has, `TMUX · CLAUDE CODE`, or `NONE`, with `ADD` while a tool that fits the system is missing; `ADD` raises `TOOLS`, the same groups for only the missing tools, every box unchecked, with no `NIX`, which comes only with the system; on Alpine without it Cursor Agent reads `Needs glibc, which ALPINE LINUX 3.24 does not have; a system with NIX can add it`, `INSTALL` taking at least one, its foot reading `NOTHING CHOSEN` or `ABOUT 250 MB IN ALL`. While they go in the row reads `INSTALLING CLAUDE CODE` for the one on its way; a failure reads in warning, `claude exited 1`, with `RETRY`, which tries again the tools that were asked for and are not in yet. Adding tools never stops the system or its shells. **A stop ends everything the system runs**, the shells in it and whatever they left in the background, not only sshd.

**The engine comes with the app.** The system finds `strikedddd` at `/usr/local/bin/strikedddd`, and it is the app's own build, laid over that path at every start and never copied in, so an update of the app is an update of the engine. `AGENTS` on a host the phone runs is switched on in the host's form like on any host, and hears the agents the user installed from its terminal; the panel's hook rows install their hooks the same way. A stopped system is not started by the poll, so its line reads unreachable until something dials it. A schedule there is refused like on any host without a user service manager.

**No system travels in a bundle.** Their files are the phone's and the next phone installs its own; their hosts, their keys, the rows that name those hosts and the setting that marks them are left out of the file.

## Agents

### The panel at the top of Home says what the agents are doing

Header `AGENTS`, a count, `VIEW ALL >`. Column labels `AGENT`, `STATUS`, `WORK`. One row per working or blocked agent, most recently changed first, at most three: a 24px bordered mono glyph box, the agent's name, a 6px status dot with the status word in the state's colour — and the pane's stripped terminal title as the work, on one line, ellipsised. A footer line reads `N idle · N blocked`, the blocked count in danger when it is not zero. When nothing is working or blocked the rows collapse to that footer alone.

**A send on its way is a row before it is an agent.** Until herdr has a pane to report, a send the user made from an item sheet heads the rows: the item's title as the work, the agent's mark and name, and `STARTING` beside a spinner in `--fg-dim`. One that failed reads `FAILED` beside a dot in `danger` until it is retried or dismissed. A tap opens the item's sheet, where both are. These rows come first and share the three; `STARTING` is the app's word for a pane it is waiting on, not a state herdr gives, so it takes no herdr hue and the header count stays herdr's.

**The panel never assumes a host.** Until some host has an agent integration switched on — `HERDR`, `AGENTS`, or both — the panel is blocked: one dim line, `NO HOST · SET IN SYS`, no rows, no footer, and not a single connection opened. Every host with it on is polled concurrently, rows merge across hosts, and a host that fails contributes its own dim line while the others still draw rows.

A host that is unreachable, has no key installed, or answers a protocol the app does not speak shows one dim line with the reason — `nyx unreachable`, `key rejected`, `protocol N` — and keeps the last good snapshot's age on the right, `12s ago`. It never blocks the rest of Home.

`VIEW ALL` pushes an `AGENTS` route with no nav bar listing every agent, idle included, grouped by host and then by workspace — the host level collapsing when only one host has the integration on — each row adding the pane id and the directory's basename as a subtitle. What the engine hears is not grouped by workspace, because a session it hears has none: it is the inbox, below the workspaces.

### An agent state is drawn in the colour herdr gives it

The phone sits beside herdr's own sidebar, so a state reads in the same hue on both: working in `warning`, herdr's yellow; blocked in `danger`, herdr's red; idle and unknown in `--fg-dim`; done in `--fg`. It holds on every surface that colours a state — the Home panel's dot and word, its footer count, the picture-in-picture window's headline and state words, and the mark on the agent status bar.

A link that failed or went down is drawn in `danger` too. Blocked and down both mean the user has to act, and the reason text says which. The accent is never a state colour: it is the app's own voice, and a lime blocked row beside herdr's red one told the reader two different things about the same pane.

### Each agent is drawn as its own mark

A scoped exception to never shipping a third-party mark: one is allowed inside the panel's glyph box, to identify the product behind a pane. Nowhere else in the app, never in the launcher icon, never in the vendor's own colour.

The box keeps its 24px border. Inside it the agent's official mark is reduced to a single colour through the same tint path as the house glyphs and fitted to a 16px square centred in the box. The files are `assets/icons/agent-<kind>.svg`, the kind being the string the server reports, on a 24-unit viewBox, paths only, with no fill colours baked in. Each is traced onto that grid from the vendor's own brand page or from a CC0 path, never pasted with the vendor's viewBox, and the source of every file is listed in `docs/agent-marks.md`.

**Struck:** a mark drawn for an agent there is no file for. A shape invented for a product is a claim about what that product looks like, and the names arrive off the wire — the night a new agent ships, the row nobody recognises is the one somebody is waiting on. The box carries the agent's own initial instead, in the muted grey that says the app is admitting it does not know this one: mechanical, the same every time, and visibly not a logo.

**Struck:** a question mark for an unplaceable name. It is the same box for every one of them, and a list with two unknown agents on it drew two identical boxes and told the reader nothing.

**Struck:** a colour per agent. It reads well enough on its own and it costs the thing the panel is for — the state colours are the only hues here and each one means something, and a row of six more beside them is six things competing with the two that do. The mark carries the identity and the name is written beside it.

The name itself stays plain text as the server reports it, uppercased.

### The pet is a glyph in the family and is bound to no surface

An agent drawn as a small hard-edged creature — angular ears, two diamond eyes, an open jaw — with a second file that closes the viewer's left eye to a bar of the same width, so the pair is a wink and not a redraw. Both live in the family, in the same stroke language as every other glyph, and neither references any vendor.

It is not the mark for an unplaceable agent: that box carries the agent's own initial, and one creature drawn for every unknown name is the identical-box problem the question mark was struck for. It is not the mascot either, which is pixel art and is Striked's identity rather than an agent's.

Nothing on any screen asks for it yet. The wink, when a surface does take it, is one autonomous tick and never a loop.

### A tap on an agent row lands in its pane

A row the engine heard is the exception, and opens that session's conversation instead: the pane is a button there, when the session has one.

A row on the Home panel and a row on the `AGENTS` route open the shell sheet on the host the agent is on, in a tab attached to its pane. The nav moves to SSH under the sheet first: that is the tab the sheet belongs to, the parked bar is there when the sheet goes down, and Home's poll stops for the visit. The `AGENTS` route stays under the sheet, so leaving the shell returns to the list the agent was picked from.

**The tab is found before it is made.** A shell tab remembers the session and pane it was opened on, and a tap on an agent whose pane a tab of that host already holds activates that tab and opens nothing. Otherwise the app says that another terminal view will be detached and waits for `OPEN HERE`; cancel changes neither route nor tab state. Confirm opens a fresh tab whose pty command attaches that pane under its own session with a takeover flag. **The takeover transfers terminal ownership and never replaces or stops the agent.** The pane id and the session name are checked against the same shapes every other command checks before they are quoted into the line. At nine tabs the tap lands on the host's last active tab.

**The binding is tab state.** The session and pane pair survive reconnects and app restarts: a reconnect reruns the command already consented to, and a process restore reconstructs a plain attach to the recorded pane. A clean detach ends that command and closes the tab, so no tab remains claiming it still owns a pane.

### What the agents are, on the screens that are not HOME

The AGENTS panel answers this and answers it better: a row per agent, the work each one is on, the pane a tap away. What it cannot do is answer it from PROJECTS or from SSH, which are the tabs where the user is standing when they stop and wonder. HOSTS is not one of them: its host panel already carries the agent state with the same reason line and a `RETRY` beside it, and a bar over that panel would say the host is down twice, one line above the other, on a screen that is also carrying the parked shell and the nav bar. The shade answers it too, and answering it from inside the app by pulling the shade down over the app is the app admitting it has nothing on screen. So one line, on the strip above the nav bar that belongs to the app rather than to a tab, over the parked shell and under nothing. A route pushed over the shell carries no strip and should not: an open terminal and an open diff are outside the shell's scaffold, and the reader of one of them is already inside the thing a count would have sent them to.

`1 BLOCKED · 3 WORKING · 2 DONE · 5 IDLE`, in that order, blocked first for the reason the shade puts it first: it is the count about to cost the user something. The states at zero are left out rather than printed as zeroes. At the head of the line is a block in one colour, the colour of the state that most wants the user, and at the tail the word `AGENTS`, so that the line reads as a count of something and not as a sentence the app is saying about itself.

**It counts every state herdr classifies, which is one more than the shade counts.** The shade is answering whether anything is happening, and an agent at rest is not; a bar inside the app is read by somebody already holding the phone and deciding whether to go and look, and `5 IDLE` beside `1 WORKING` is the difference between a busy machine and one nobody is using. Both surfaces count over the hosts that answered this round and neither counts the agents a failure report carried along — that ride-along exists so a host blinking does not empty the panel, and counting it is counting work the app has lost sight of.

**A host that is down leads the line, and the counts follow it rather than being suppressed by it.** The shade drops its tally under a failure because the tally it could draw came off the host that stopped answering. Here the tally is taken over the hosts that did answer, so a machine that is down and a machine that is working are two true things at once and there is room on the line to say both. One failure is named; the rest are a count after it, `NYX UNREACHABLE +2`, because the bar is the place the user finds out that something is wrong and HOSTS is the place they find out which. The named one carries its host whatever the count beside it says: two of the reason lines a failure can carry write their host into the words and the rest do not, and `KEY REJECTED +1` on a strip that shows one failure and counts the others is a line the reader cannot resolve anywhere else on the screen.

**Blocked outranks a host being down for the one colour.** A machine nobody can reach is the app failing to look. An agent stopped at a question is the user being waited on, and it is being waited on right now.

**The bar is not there when there is nothing to stand it up for.** Height is the scarce thing on this window — a parked shell is already taking a row of it — and a strip that stands up to report that there is nothing to report is the strip the reader stops seeing. Nothing blocked, nothing working, nothing finished and nobody down: no bar. Work that finished while nobody was watching is on the other side of that line, because it is the thing the phone is picked up to find out.

**A tap goes to the panel.** The count is not an answer: a blocked agent is answered in the pane it is blocked in, and the panel is the door to that pane.

**The feed is the panel's feed, which means the bar is only as live as the watcher.** With `[ ALERTS ]` on, the watcher is running and the bar is current on every screen that draws it. With alerts off, the feed runs while HOME is on screen and stops when it is not, so the bar is correctly absent rather than quietly stale — a line that says `3 WORKING` about an hour ago is worse than no line, and the app does not have a second source to keep it honest. Absent is a thing the bar has to do and not a thing that happens to it: a feed whose poll has stopped goes on handing out the last state it held, for as long as the app is open, so a count is never on its own evidence that anything is still counting. The bar asks whether something is dialling before it asks what the number is, and that question and the poll's own gate are one answer kept in one place rather than two readings of the same conditions.

Struck: the bar on HOME. The panel is there, saying all of this and the rows under it, and two answers to one question on one screen is one of them too many.

Struck: the bar on MACHINES. The host panel is there, with the reason line and `RETRY`, and the strip would stack a third row of chrome over a parked shell and the nav bar to repeat it.

Struck: the block at the head held at the size it was drawn. The phone's text scale is a curve that gives a small size most of the rise, so a fixed six pixels shrinks against its own line until it reads as dust on the bar. It is sized off the line's own face.

Struck: a row per host. That is the panel, and the panel is one tap away.

Struck: the same bar on iOS. There is no `ios/` directory in this repository to put it in, and the bar is Flutter widgets rather than a system surface, so the work is the target and not the feature.

### The app reaches a herdr server over its socket, and is told when something changes

herdr is a server and every session of it listens on a unix socket. A request is one line of JSON on that socket and the answer is one line back. The phone opens a channel straight to that socket inside the ssh connection it already holds — `direct-streamlocal@openssh.com`, the forward an ssh client opens for a socket on the far side — so no shell runs and no `herdr` process starts for anything a server can answer. What the app sends travels as JSON values: a pane id, a session name, a directory, a prompt, each one a string the server reads as a string, where a quote is a character rather than a word. The shapes are still checked before they go, because a pane id that is not a pane id is a bug wherever it ends up, but nothing the user ever typed is composed into a line for a shell to read.

A server answers one request per connection and then stops reading, and it resets the connection if the client half-closes, so a request opens a channel of its own and destroys it once the answer is in. That is the cheap side of the trade it replaces: a channel is a window and two packets, where a command was a shell, a `herdr` process, and this same socket opened from the far end.

Nothing is added to the host for this. The key the app installs is a plain `authorized_keys` line with no forced command and no `restrict` on it, and a line like that already opens channels — the terminal and the VNC stream ride ones of their own. A key that was narrowed by hand would have to allow forwarding, which is the same thing that line already has to allow for the shell to work at all.

**The list is an answer to an event, not to a clock.** A held channel per running session subscribes to panes and workspaces appearing, closing and exiting; a held channel per agent pane subscribes to that pane's own status changes, which is a subscription that must name a pane — the session-wide set carries a pane coming and going and never the moment an agent stops at a question, which is the moment the whole panel exists for. An event is a signal that something moved and never the new state: what it does is start a quarter second of quiet, after which one `agent.list` per session runs and the panel is drawn from the answer. A quarter second is there because one user action moves several panes, and a burst of events is one list rather than six. A machine where nothing is happening costs nothing at all, which is what a phone holding an idle connection over a mobile radio should cost.

**The roster is watched from the host, and asked for on a clock only where that cannot run.** No socket method lists sessions, and the socket path of a session is what that listing carries, so the app has to have it before it can reach a server at all. `herdr session list --json` stays a command, and a loop in the shell of one held channel runs it every ten seconds and sends the listing only when it differs from the last one sent, the first always. Each listing that arrives is one round. The loop holds the channel's input open and ends itself when that closes, so a phone that goes away leaves nothing running behind it. A loop that has sent nothing for four minutes sends a beat instead, and a channel that brings neither a listing nor a beat for five minutes is a dead link: the app closes that connection, asks at once, and dials again when that fails. A connection dropped without a close never tells the host its input is gone, and the beat is what ends the loop then — its writes are what make TCP give up on a peer that no longer answers, in minutes rather than never. A host where the watch will not stay up is asked every thirty seconds instead. Ten seconds is the delay before a session that appeared has its panes watched, and a roster that does not move costs the radio nothing.

**A session is a socket, not an environment variable.** Which session a pane lives in decides which socket the request is dialled on, so it never travels inside the request and a pane of one session can never be read on another's server. The pairing of a session and a pane is still what identifies an agent everywhere above this — two sessions on one host can both own a `w1:p1` — and it still travels with the snapshot across the watcher's isolate, into a notification's payload, onto the shell tab an attach opens.

**A session that stopped is not a host that went away.** A channel to a socket nobody is listening on is refused by the far end and that session is skipped for this round; every other failure to open one is the connection itself, and the panel says the host is unreachable rather than saying the host has no agents. The two are different errors on the wire and the app reads them apart, because an empty panel is the one wrong answer here: it looks exactly like a machine with nothing running on it.

**What is still a command is what no server can answer.** The attach is a TUI that owns a pty until the user detaches. A directory is resolved and tested by a shell before a workspace is created in it, because `~` is the shell's and a `workspace.create` given a directory that is not there says nothing about it. Model discovery reads files. Checkout discovery walks a tree. An image is uploaded on stdin. Each of these is a quoted script under `sh -c`, with every value that came from the user or the host quoted into it, exactly as before.

**A tab that came up over mosh keeps its commands.** Mosh carries a terminal and cannot forward a unix socket, so the pane listing a shell tab does for its own header goes on asking a shell. The AGENTS surface does not: it runs on the app's own ssh connection to the host and never on a tab's transport.

Struck: a runtime of the app's own, injected on the host and written in a native language, to make this faster and safer. The daemon it describes is herdr, which is already there and already speaks a protocol; the cost the phone was paying was a process per poll on the host and a wakeup per poll on the radio, and neither is a thing a second daemon removes. It would also be the app installing a binary on a machine whose owner installed a key for it, which is a larger permission than anything else in this document asks for, and every byte it parsed would be one more thing between the user's agents and the screen.

Narrowed to exactly what it rejected, and no further. What stays struck is the daemon and the injection: a host binary that is resident, that listens, that the app puts on a machine of its own accord, or that stands between these panes and this screen. A host binary does exist, and it is none of those things — it runs when it is called and is gone when it has answered, and the user declares and installs it themselves. It serves this surface one thing herdr does not have, which is the agents' own word about themselves; it never stands between a herdr pane and the panel. herdr's panes are still read off held channels and its roster still listed by a shell loop that lives and dies with its channel, because a process on the host was never what either of those was waiting on.

### The engine hears the agents from their own hooks, and herdr is one source of two

herdr reads a pane and guesses what the agent in it is doing from the screen. It cannot say which command the agent wants to run, and it cannot say anything at all about an agent that is not in one of its panes. Claude Code, Codex and OpenCode each call out to a program of the user's choosing when a session starts, when a prompt goes in, when a tool is about to run and when a turn ends, and they call it with the facts rather than a picture of them. The engine is that program. `strikedddd hook <agent>` reads the agent's event on stdin, writes the session's state into the owner's state directory under a lock, and exits; `agents/1` reads it back for the phone.

**A host is watched through either source, or both.** `AGENTS` is an integration of its own in the host form, beside `HERDR`, and neither needs the other. herdr keeps everything a pane is for — the attach, the spawn, the prompt handed to a started agent — and the engine gives the panel what only the agent knows. A session whose hook ran inside a herdr pane is that pane's agent told firsthand, so the pane's own row goes from the panel and the session keeps the pane as its way back to the terminal. Each source is dialled and fails on its own, with its own reason line; `no engine` is the one only `AGENTS` can say, and `no herdr` the one only `HERDR` can. A host whose shell cannot find `herdr` has none, which is not a herdr answering in words the phone does not know, so it never reads as a protocol.

**The watch is a question held on the host, not an event stream.** `watch` names the generation the phone last saw and a wait, and the engine answers when the state moves past it or the wait runs out, at most thirty seconds. That is one exec and one answer per change on a quiet machine, and nothing on the host outlives a phone that went away but the wait it had already asked for.

**A session is the agent's, not the pane's.** Its key is the agent and the id the agent gave it, and it carries the directory, the first prompt of the turn, the last thing the agent said when it stopped, and the herdr pane or tmux pane the hook ran in when its environment says so. A subagent's events are its parent's business and never end the parent's turn. A session the agent has said nothing about for a day is gone from the host, ended or not; one that ended stays readable until then and is not drawn.

**Struck:** the engine deciding what an agent's state is from anything but the agent's own event. herdr already does the reading from the screen; a second reader would be a second guess.

### A request for permission is answered from the phone with the command on it

When an agent asks before running something, the hook that carries the question is held open by the engine for sixty seconds, and in that minute the phone can answer it. The session is `blocked` with an approval on it: the tool, and the one argument a person decides on — the command, the file, the address — cut on the host. The alert says `<AGENT> BLOCKED` with that line under it, and carries `ALLOW`, `DENY` and `OPEN`. An answer from the phone is the agent's decision: the hook prints it, the agent acts on it, and the terminal never asks.

**Nobody answering is not an answer.** At the end of the minute the hook exits saying nothing, and the agent asks at its own terminal as it would have with no engine there; the session keeps the question as a line without buttons, and the alert loses its answers. It does not ring again: the question that replaces the approval is the same ask, so its alert is put up without sound. The same happens the moment the question is taken at the terminal instead — the hook is ended from under the wait — and an `ALLOW` that lands after either is refused by the engine rather than applied to a question that has gone.

**The command is on the alert because it is what is being decided.** `YES` over a pane title was a keystroke into a dialog the user could not see. What the agent is about to run is the one fact the answer depends on, so it travels with the question instead of being left behind on the host.

**Struck:** answering on the user's behalf by rule. An allowlist on the phone is a second permission system beside the agent's own, and the agent already has one the user configured.

### The AGENTS route is an inbox, one row per session

Under the workspaces, one panel per host the engine answers for, titled `INBOX` — the host's name before it when more than one host is on. One row per live session, the most recently changed first: the agent's mark, the question or the approval line when it is blocked, otherwise the session's title, prompt or last message; the agent, the directory's basename and the host under it; the state on the right in its colour. A tap opens the conversation.

**One row per session, not per event.** An inbox of every turn would be a log; the phone is asked what each agent is doing now and what it wants, and a session answers both.

### A session reads as a conversation, from the transcript the agent already writes

`/ STRIKED / AGENTS / <AGENT>` is the conversation of one session: what the user asked, what the agent said, and each tool it ran with its argument and a cut of what came back, read from the transcript file Claude Code and Codex already keep. The engine parses it on the host and sends only lines after the last one the phone holds; a line the agent is still writing is read on the next call rather than half now. The route asks again every three seconds while it is on screen and not at all once it is gone.

**The approval sits under it.** A session blocked on an approval carries a bar at the bottom with the line and `ALLOW` and `DENY`; a question without an approval carries the line alone. A session linked to a herdr pane carries `OPEN PANE`, which is the tap on a herdr row.

**An agent with no transcript the engine can read says so.** OpenCode keeps its conversation in its own store, and the conversation says `NO TRANSCRIPT` under the session's state rather than drawing an empty chat. A session that has not named its transcript yet says `no transcript yet` until it does, and is asked again like any other. A read the host refuses for any other reason, the file unreadable for a moment, is not an answer about the transcript: the reason stands on the session's `LINK` line, the conversation keeps what it already holds, and the next ask tries again.

**Struck:** sending a prompt from the conversation. Typing into an agent is the terminal's, and the pane is one tap away.

### The hooks go in when the user is standing where they matter, and never behind their back

A hook is a line in the agent's own configuration, which is a file the user owns. With `AGENTS` on, the host's panel on MACHINES lists each agent kind with whether its hooks are in: `INSTALLED`, or `INSTALL` behind a sheet that names the file and what will be added to it and waits for a confirm. The engine merges its entries beside whatever is there and touches nothing else; OpenCode takes a plugin file of the engine's own. A plugin file at that path the engine did not write is not its to replace: it is reported as not writable, and the sheet shows the plugin with `COPY` like any other declaration.

**A file a declaration owns is shown, not written.** A configuration that is a link into a store — home-manager, a Nix module, anything the user rebuilds from — is read-only in every way that matters, and a write to it is undone at the next switch. The engine reports it as not writable, and the sheet shows the path and the exact entries with `COPY`, for the user to put in their own declaration.

**`teardown` takes the hooks back out.** It removes the engine's entries from every file it can write, leaves every other entry where it was, and says which files it changed; a file it could not write was never written by it.

### A pane the app opened carries a mark, and the host decides what the mark means

Every workspace the app creates puts `STRIKED_PANE=1` in the environment of the shell that comes up on the pane. The app is stating one fact and no more — nobody typed in this pane — and the host is what acts on it: an rc that knows the name unsets `HISTFILE`, so the command line the server types at the prompt to start an agent is never written into the history its owner searches. A machine that has never heard of the name is left exactly as it was, and the app is the same app on both.

**A mark beats a value, and here nothing else does.** A generated rc assigns `HISTFILE` outright a moment after the environment is read, so a path put in the environment loses to the file the rc names. The rc is therefore the only thing that can undo the rc, and what it wants from the app is a flag to key on rather than a setting to be overruled. It is also why this is one line on the host and not a rule per shell: zsh and bash unset the same variable.

**The mark names the pane, not what is running on it.** Agent kinds arrive and change their flags, and a pane the app opens for something that is not an agent at all is still a pane nobody typed in. So no command line is written down anywhere for this and there is no pattern to extend the day a kind is added.

**Struck: dropping the line with an ignore pattern instead.** zsh applies `HISTORY_IGNORE` when history is written and applies it to every entry in that write, including the thousands it read out of the file when it started. On a pane sharing the user's own history file a pattern of `*` therefore does not drop the start line, it saves an empty file over the history, and every pane that exits costs its owner everything they had. It reads as working from the inside — the file is whole for as long as the pane is alive, the start line really is absent, and the loss lands at exit — which is how it survived being checked. A pattern narrow enough to match only the start line rewrites the file just the same and takes the user's own matching lines with it. Nothing the app puts in a pane's environment may cost a host data it had before the pane existed, and a start line back in the history is the smaller harm by a distance: pollution is a line to delete, and a wiped history is not recoverable at all.

**An attach carries no mark and needs none.** It is not a pane the app opened, and the shell behind an ssh session runs the attach non-interactively — no rc, and no history to write.

### A started agent is handed its prompt once it is ready for it, not once it is launched

Starting an agent and giving it the text are two requests, and the server answers the first as soon as the process is on the pane rather than when the agent is up. A pane with a process in it is not yet a named agent, and the prompt that follows a millisecond later is refused for exactly that — a send that had already made a workspace and started an agent, closing both and telling the user the spawn failed, every time, on a machine where nothing was wrong.

So the send waits between them, and the wait is the server's own: after a start that was accepted it asks the server to hold until the pane comes to rest, and prompts when that answer lands. A wait that expires is an agent taking longer than the window rather than a verdict, and the prompt goes anyway.

**A prompt refused because the agent is not ready is a moment, not an answer.** It is retried on the same terms as one the agent never read, inside the deadline the whole send is already under, and before each retry the pane is looked at: a trust dialog is answered the way the start's own refusal used to be answered, and anything else is waited out. What is never done is reporting the text as refused because the far side was still opening.

### A pane that stops for a question rings, and so does one that finishes

Two kinds of alert leave the watcher and `[ ALERTS ]` carries a row for each.

`BLOCKED AGENTS` posts `<AGENT> BLOCKED` on a pane entering `blocked`, the pane's terminal title under it and the tail of what the agent said in the expanded view, with `YES`, `NO` and `OPEN` on it. A session the engine heard carries its approval instead — `<tool> · <command>` under the title, with `ALLOW`, `DENY` and `OPEN` — and each new approval is a new edge, since two questions in a row are two questions. A question the engine can only relay carries `OPEN` alone. `FINISHED AGENTS` posts `<AGENT> DONE` on a pane entering `done`, the same title under it, and carries `OPEN` alone: a finished agent is news rather than a question and there is nothing on it to answer. Each comes down when its pane leaves the state, and both come down when the watcher stops, because an app that can no longer say the pane is still there should not leave a line claiming it is.

**Each kind has a channel of its own**, for the reason the passphrase alert has one: Android hands the user a channel's sound and vibration after it is created, and a night of agents finishing should be silenceable without also silencing the one pane waiting on a keystroke.

**Both fire on the edge into the state and never on the state.** A report that says what the last one said posts nothing. This is what `done` needs most: it is where an agent rests once the tab it finished in went unwatched, which from a phone is every tab, so a phone alerting on the state would repost the same finished agent for the rest of the night. The edge fires once per episode, and again only if that agent is given more work and finishes again.

**A pane that blocks and then finishes carries both alerts at once.** The id is derived from the host, the pane and the kind, so the second posts beside the first instead of replacing it in place, and each is taken down by its own edge. The question the user has not answered is not cleared by the news that something else ended.

**The watcher runs while either row is on.** It is one connection per host and one ongoing line whichever kinds are wanted, so the first row turned on is what opens it and the last row turned off is what closes it. With both off the app opens nothing in the background, ever; what it keeps there is an SSH tab the user already opened.

**Struck:** an alert for an agent that failed. herdr classifies a pane as `working`, `blocked`, `idle` or `done` and holds no verdict on how the work went, so there is nothing here to read a failure off. A line saying an agent failed would be the app inventing the one fact on the screen the user would have most wanted to trust.

**Struck:** a row for the host going down. The ongoing line already names the failing host with its reason and its countdown, and a machine that is not going anywhere does not earn a surface that makes a sound.

### The ongoing notification says what the agents are, not what the watcher is

The watcher has always posted a notification of its own: silent, at the bottom of the shade, there for as long as `[ ALERTS ]` is on or an SSH tab is held, because Android will not hold a service's connections open without one. It said `WATCHING 2 HOSTS`. That is a line about the app. The phone comes out of a pocket to answer a different question — whether anything is waiting on the user — and the one surface the app has on screen without being opened was the one surface that did not answer it.

So the line is the tally. `1 BLOCKED · 3 WORKING`, across every host at once, blocked first because that is the count about to cost the user something. The states counted are the states that earn a row on the AGENTS panel and no others: one rule for both surfaces, and an agent at rest is the night going the way it was supposed to rather than news. With nothing active the host count has the line back, being the only thing left to say. A host that is down takes it ahead of either — a watcher that cannot reach a host is not a watcher reporting that the host is quiet, and the tally it could still draw is the last one it was told rather than the one that is true.

**A report that does not move the line does not repost it.** herdr sends a report whenever it has anything to say, and most of what it says is a terminal title three panes down; the tally over that is the same tally. The line the shade is currently showing is kept and compared, and the service posts only when they differ.

**The shape this idea takes on the other phone is out of reach, and saying which shape keeps it from reading as an oversight.** The same idea — a phone that says what the agents are doing without being opened — lands on iOS as a lock-screen Live Activity and the Dynamic Island above it. Neither is a status bar and neither is Android: the lock-screen card is ActivityKit, and this repository has no iOS target to build one in. The shade's ongoing notification is the surface of that shape that exists here, it was already being posted every time a report landed, and what it cost to make it say the right thing was the text.

**Its transport is the one the watcher already does better.** There, an agent POSTs to a hosted endpoint whose URL is itself the credential, and a vendor's push wakes the phone. Here the watcher holds herdr's own `agent watch` open per host over ssh, and the engine's held `watch` beside it where `AGENTS` is on, on a key the phone generated and a host fingerprint it pinned: the same liveness, with no third machine in the path and no bearer token left in a shell history. What the push buys and this does not is a phone whose app is gone — the ongoing line is live only while the service is, which is the trade `[ ALERTS ]` already names on the row that turns it on.

Struck: a lock-screen card and a Dynamic Island. They are the same tally on a platform this does not build for, and the day it does they are a rendering of a line that already exists rather than a feature to be designed then.

Struck: an endpoint agents ping, and the pairing code and hosted key that go with it. It would be reachable by anyone holding a URL, and it would put a machine the user does not own between the phone and their own panes. The agents' own word arrives through the engine instead, which writes it on the machine it happened on and hands it only to the ssh key that asks.

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

**Preferences per kind are the piece of its model this took, and the only piece.** The moment a second alert existed, one row governing both would have left a user who wants the blocked pane and not the finished one holding only the switch that stops the watcher. So there is a row per kind, each on or off on its own, which is the small half of what BuzzKit does here. The channel half does not carry across: it routes between email, SMS and push, and here there is one destination and it is the shade — though each kind is given a channel of its own inside it, so the sound is the user's to set per kind rather than the app's.

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

**The app's own two refusals sit on the same side of that line for a plainer reason.** A host key that was never pinned and a host key that changed are both answered by a person standing in front of a fingerprint on MACHINES. A loop cannot be the one to answer them, so a loop that retries them is asking a question with nobody in the room, every minute, for as long as the phone is on.

**Everything else costs the host nothing to be asked twice and can answer differently without anybody touching the phone.** A route that is not there comes back, a name starts resolving, a herdr too old to be understood is upgraded on the far side. Those keep the schedule they have.

**A line nobody is coming back from carries no countdown.** The shade reads `KEY REJECTED`, not `KEY REJECTED · RETRY 60S`. A countdown under a refusal the app has decided not to retry is the app promising a knock it is not going to make, and the reason on its own is the whole of what is true about that host.

**What starts the loop again is the user, and that is the right trigger.** The watcher rebuilds a host's loop when the row changes under it — a different address, user or key, a pin that appeared or changed — and when `[ ALERTS ]` goes off and on. Every one of those is the same act that could have fixed the credential, which is the only thing that makes another dial worth making.

Struck: a longer timer for a refused key, an hour or a day instead of a minute. It is the same knock with a longer fuse, and the penalty it lands in is measured from the last attempt, so a loop on a slow timer keeps the lockout alive rather than letting it expire.

Struck: a notification asking the user to go and fix the key. The ongoing line already names the host and says what it refused, HOSTS is where a credential is answered, and a second alert about a machine that is not going anywhere is a phone buzzing about the state it was in a minute ago.

### The watcher holds no lock on the phone

The service that carries the watcher keeps the process out of the freezer, and that is all it takes. Its connections sit idle between reports, and a packet arriving wakes the process to read it. It takes no wake lock, which would hold the processor up through every idle minute of the night, and no wifi lock, which turns the radio's power saving off for as long as it is held. An alert still rings on a phone asleep in its deepest idle.

## Shell

### A host's shell is the app's own terminal, and several at once

Every registered host offers it: ssh is what a host already is, so there is no integration toggle for it. The session is `shell` on the ssh channel with a pty of type `xterm-256color` at the view's columns and rows, and nothing else — no command, no `exec`, no environment beyond what the pty implies, no rc injection, no multiplexer attach, no wrapper. What sshd starts for the user is what runs.

The terminal is libghostty, Ghostty's own emulator core, drawn by `flterm`, one controller per session, on a black ground in the mono face, the cursor a block in the accent, the foreground text primary, and the ANSI palette taken from the tokens for black, white and green with standard hues for the rest. Bytes in are the channel's stdout and stderr, bytes out are the terminal's, a resize sends a window change, and the scrollback is ten thousand lines. **The emulator is not ours to write.** Parsing, reflow, wide and combined characters, the modes, mouse and focus reports, colour queries and the search are the engine's, and what striked patches in it is a short series written down against a pinned revision, one concern per file, rebuilt and checked by `just flterm-build` and `just flterm-verify`. A behaviour the engine has is not built again on top of it.

Sessions outlive the route. A store per host keeps every session, its connection, its buffer and its state, so leaving the shell and coming back finds the tabs where they were, still running. A session ends by `×`, by the remote shell exiting, or with the process.

### The shell is a sheet over the screen it was opened from

It is presented as a modal sheet over the surface that opened it — the MACHINES tab, a host panel, a workspace, an agent row — and not as a page in front of it. The screen beneath stays in the tree under a `0x99000000` wash, lighter than a panel sheet's, so the tab still reads as the tab.

**The sheet stands flush under the status bar**, its foot at the screen's, so the terminal keeps every row a full page had. In place of a band or a shoulder, one rule on the sheet's own top edge — 36 × 2 px, centred, `textDisabled`, 5 px under the edge, drawn over the header's ground, with the hairline `borderNormal` along the edge itself. That rule is the only thing that says sheet, and it says it inside the row the header already holds, so it costs no rows either. It takes no touches: the header under it is what the finger grabs.

**A vertical drag that starts on the header row, or on the reason row under it, moves the sheet with the finger one to one**, the wash thinning with it, terminal and key bar and keyboard going along. Released past a third of the way down, or flung downward faster than 700 px/s, the sheet finishes its way down and the route pops; released short of that, or flung upward, it comes back. Under the finger the motion is linear; from a release it goes down from where the finger left it. The header's cells still take their taps. The terminal keeps its one-finger drag as the scroll and the key bar keeps its horizontal one; neither moves the sheet. Back still leaves, and the last tab closing still pops, both down the same slide.

Leaving by the drag is leaving by back: the session lives on, the tabs are where they were on the next open, and the SHELL actions on the MACHINES cards are the way in again. Landscape is allowed.

**Struck:** X's parked state as a resting height for the sheet itself — one row at the bottom with the page behind it whole. One resting height. **Struck:** the sheet as an inset card held clear of the screen's edges on three sides. Columns cost more than the top ever did. **Struck:** a tap above the sheet to leave. What is left up there is the status bar strip, and the system takes that tap before the app sees it.

### The shell parks as a bar over the nav, and one tap is back in

One row, 36 px, over the nav bar and under all four tabs, drawn whenever a host is registered. Ground `surfacePrimary`, a hairline `borderNormal` along its top, capped to the content column as the nav bar is. It says what the strip will show once the sheet is up: one cell per host with a shell — the host's system mark, its name and its tab count, flat on the bar's own ground in the face `TAP TO RESUME` is set in, the count a space apart and muted. The strip's `surfaceSecondary` block is not carried over: on `surfacePrimary` the two greys are close enough that the block reads as a smudge rather than a label. The host the tap lands on comes first and in primary; the rest follow in strip order, muted. A host with a tab that is not live carries the state dot after its count, in the colour of the worst of them, and a host whose tabs are all live carries none. `TAP TO RESUME` sits in the accent at the right edge. The whole bar is the target, not the words.

With one host, the room the other cells would take holds the tab the tap lands on, by the label its tab carries in the strip, in `rowKicker`; a tab with nothing but its number shows nothing there. With more than one host, no tab is named.

**The bar gives way from the end.** Cells that do not fit whole are dropped from the last, and `+<n> HOSTS` in the muted weight counts them, shortened to `+<n>` when that does not fit either, and left off when the front host's name would have to shrink to nothing for it. The host in front is never dropped: when it alone is wider than the room, its name is cut and its count stays. `TAP TO RESUME` gives way last: it shortens to `RESUME` only when the front host's whole cell would not fit beside it, which on a phone happens only at large text sizes. No tab numbers are drawn on the bar: a number is never reused within a visit, so it counts tabs ever opened rather than tabs open.

The session it names is the tab last opened or brought forward, on the host it is on. Closing the named tab falls to whatever its host is on now, closing a host's last tab falls to another host that still has one, and a restored run parks on the tab that was on screen when the process died.

**With no session anywhere, the bar is the way to the first one.** It carries one cell, the host a shell was last on, a restored run's included, or the first host in MACHINES order when none has been — its system mark and its name in primary, with no count — and `NEW SHELL` in the accent at the right edge in place of `TAP TO RESUME`. The cell is a suggestion, not the answer: with more than one host, a tap opens the `NEW SHELL ON` menu the header's `+` opens, every host in MACHINES order with the named one marked `CURRENT`, and the host picked there is the one started. The menu opens where the finger lifted, held on screen, so a tap on the right lands it against the right edge and the thumb that tapped is the one that picks. With one host the menu would be a list of one, so the tap skips it. Either way the start is asked with the same picker the host card's `SHELL` raises — login shell, tmux, herdr — and the pick opens it in the sheet. The first shell is a tap or two from any tab, on any host, rather than a trip to MACHINES and a hunt for the card. A host deleted under it falls to the first one left, and the bar goes with the last host.

**The bar stands under the sheet rather than appearing when the sheet leaves.** Nothing animates it in or out: it is there before the drag starts and is already drawn where the sheet lands the instant the sheet is gone. A row sliding in under the nav while a sheet is going down is two things moving in the same 180 ms.

The cost is one row on the tabs, for as long as a host is registered. The terminal refuses 24 px at the top because rows are what a terminal is; this spends 36 px on screens that scroll.

**Struck:** a drag up from the bar that raises the sheet under the finger. The route does not exist until the push, so the gesture would drive a controller it made mid-drag, and on a row this size the tap is already the whole target. **Struck:** a close cell beside the verb. Killing a shell belongs to the header row inside it, not to a 36 px bar the thumb passes over on its way to the nav. **Struck:** the bar showing through mid-drag as the place the shell is going — the sheet slides as a whole and its foot goes down with its head, so the screen's bottom row is sheet until the sheet has left.

### The tab strip holds every host's shells, grouped by host

The strip is every session on every host, one group per host with a shell, the way a browser groups its tabs. A group is its label — the host's system mark and its name in the label face on a `surfaceSecondary` block, primary for the host in front and muted for the rest — followed by its tabs, and a `borderNormal` rule two hairlines thick runs under the label and every tab in it, with the active tab's accent drawn over it. **A host's shells are never apart**: a group holds all of them and nothing else.

Groups come on demand. There is no host cell at the head of the header: a host gets its group when its first shell opens, at the end of the strip, and loses it when its last one closes. The `+` after the last group is how a shell is opened on any host, the one in front or any other.

A tap on a tab on the host in front is a tab switch. A tap on a tab on another host hands the sheet that host: the sheet keeps its route and rebuilds under the new host's key, which runs the arriving host through the same path a fresh open takes. **One route means one way out** — the drag that was there before the switch is the drag that is there after it, and it goes to the tab underneath.

**A tap on a label folds the group**, the way a browser collapses one: its tabs go and the label counts them, `+<n>` in the muted weight after the name. A second tap unfolds it. The group in front keeps its active tab while folded, because folding never takes away the shell being typed in. A fold lasts for the run and is not written down, and a group that goes with its last tab takes its fold with it.

**A long press lifts a tab or a group and the finger puts it down elsewhere.** A tab moves among its own group's tabs and never out of it; a group moves whole, lifted by its label. A folded group's tabs do not move, since the ones not drawn have no place to be put between. The order is written down with the tabs, so a restart brings them back where they were put, and a tab opened after the last move goes at the end of its group.

**Struck:** the host name at the head of the header as a cell that opened a `SHELLS` sheet over every host. It named one host and hid the rest behind a tap, while a strip that groups them shows every shell at once and costs no row.

### A tab says which shell it is and how it is doing

The header is one row of 44: the strip of host groups and a `+` inline, the active tab underlined in the accent, then the diff, files and machine marks, then a rule and `×` at the right, so the `×` is never read as one of the verbs beside it. The `+` opens a new session and makes it active, and is gone once every host is at nine; its menu is headed `NEW SHELL ON` and marks the host in front `CURRENT`. `×` closes the active session behind a `CLOSE SHELL <n>?` sheet while it is live, and at once when it has exited or failed. Numbers are not reused within a visit.

**A tab is named by the shell in it.** It takes the title its shell set, shortened for the room a tab has: the `user@host:` a login shell puts in front is dropped, a remainder that is one path is cut to its last segment, and what is left is drawn in the shell's own case and cut off by the width of the cell. A shell that has not named itself keeps its number. The number is still what the app calls it: a tab's key is its host and its number.

**A tab carries its state**, the dot the host row carries, in front of the word: a tab that dropped, gave up or exited is seen without being visited. A tab opened on tmux or herdr, or on a pane attached from the agents panel, draws that program's logo in place of the dot, in the colour the dot would have been, so what the tab is and how it stands read from one mark. It is the one thing on a tab that changes with nobody touching it.

**The tab in use is on the screen.** The strip scrolls, and a tab going active — by a tap, by being opened, or by the one beside it closing — is brought into view. A strip that scrolled the shell the user is typing in off its own edge is how a tab is lost.

### The tab on screen carries a rail of what it runs with

**The active tab grows a rail at its right edge**, after a `borderSubtle` hairline that stops short of the row's top and bottom, with the tab's accent underline carried under it so the rail reads as part of the tab and not a cell beside it. The rail is a list read from the top: one mark per feature, the first one level with the top of the hairline, so the room under it is where the next feature goes. It is read-only; a tap on it does nothing. Tabs not on screen carry no rail, because the strip is where every shell is found and nine rails would cost it the room.

**The one feature today is the connection, drawn 12 wide on a 1 stroke, and the rail is no wider than the mark and its hairline.** Shared, two channels leave two hollow nodes and converge into one route to the host's node. Dedicated, one channel runs straight from its node to the host's. Routes are `textMuted`, nodes `textSecondary`.

**Accent dots of 2 px run along it only while the tab has traffic**, the host's bytes or the app's: one traversal takes about 1.8s, stepped at the spinner's 80ms like every other effect, and a traversal that ends with no traffic since it began leaves the routes bare. On a shared mark B trails A, so the two alternate along the shared run and never merge. The dots are illustration and say nothing about volume. Under reduce-motion the mark is drawn still and bare.

**The choice is made once, in `NEW SHELL ON`, behind `ADVANCED OPTIONS`.** The row stands under the menu's list, saying `SHARED` or `DEDICATED`, and opens the menu's second page: `ADVANCED OPTIONS` with `BACK` in the title bar, and under `CONNECTION` the two marks to pick from, `SHARED` checked by default. `BACK`, or the system back, returns to the first page with the choice kept, and whatever row is picked there opens on it. The choice holds for the life of the tab: nothing switches a tab already open, so the choice never redials one. Only the tab moves: the pickers, the send, the workspace and the files sheet stay on the shared connection.

**The choice is written down with the tab** in a nullable `own_connection` on its row, null for shared, so a restart dials each tab back on the connection it had. The v22-to-v23 migration leaves the column null, and every tab written before it comes back shared.

### A tab the host has not drawn on yet carries the spinner

A tab that is dialling, or is up and has not had a byte from the host, is a black page and a cursor, which reads the same as a shell that hung. The dot spinner stands in the middle of the terminal until the host's first bytes land, under the same 200ms rule as every other wait, so a dial that answers at once never shows it. It takes no touches and hides nothing: the cursor and anything written under it are the terminal's as before.

**The tab sweeps while it waits.** Its mark and its name drop to `textDisabled` and a ten-pixel band in the tab's lit ink — the accent on the tab on screen, `textPrimary` on the others — steps across them left to right and starts again, twelve steps of the spinner's 80ms. It is a flipbook like every other effect here, and it is the one way a tab off screen says it is still coming up. The band is hard-edged, a cursor passing over the letters and not a glow. It waits the spinner's 200ms before it is drawn, ends on the same bytes, and under reduce-motion the tab is drawn plain.

**It sweeps in `warning` while a link comes back.** A tab that dropped and is being dialled again, or a Mosh tab missing its acknowledgements, sweeps the same way with the band in `warning`, on screen or not, until the link is live, and goes back to the lit ink if the host has still not drawn on it. The spinner stays out of it: a page the host drew on keeps what it drew, and the header already says what the tab is waiting on. A tab that is waiting, failed or exited does not sweep, because nothing is trying. Mosh calls itself reconnecting on every return to the foreground until the first acknowledgement, and the 200ms is what keeps that round trip from flashing every tab.

It is the host's bytes that end it, not the terminal's: the modes and the mark the app writes into a fresh terminal on its own are not an answer. A tab restored on its saved screen never shows it, because it opens on something to read and the dial lands under it the way a reconnect does, and a reconnect on a tab the host already drew on never shows it either. A tab that failed, exited or is waiting drops it — the reason row says why, and a waiting tab is not working.

### A shell that exits clean takes its tab, and one that does not says why

**Exit 0 closes the tab.** The user typed `exit`, the tab holds nothing they asked to keep, and it goes the moment the code arrives — from the store, so it goes whether or not anybody is on the route. The last tab going takes the route with it, the same pop closing the last one by hand does, and that pop has one owner: the store's listener, which every way of losing the last tab passes through.

**Every other code is a sheet.** `SHELL <n> EXITED <code>`, one at a time, over the terminal the shell died in, with `CLOSE` and `KEEP` — `KEEP` filled, because the output under the sheet is the only place the shell wrote what went wrong. A connection that went away without a code reads `EXITED —`, the word the header already uses. A tab is announced once: the sheet is the moment it ended, and the header goes on saying it afterwards.

### The tabs survive a restart, because what is written down is the tab

An ssh channel dies with the process that held it; nothing on the phone can keep one warm across a launch, and a session that claimed to be the same shell would be lying about the state on the remote. What survives is the row: host, number, the remote identity it was on, and whether it was the tab on screen — and beside it, the screen the tab last showed. A multiplexer on the far side is what makes the shell itself survive, and that is the remote's job.

**Startup dials them back.** The rows are read before the first frame and a tab is opened per row, on the host it was on and under the number it had, so the numbering carries on where it stopped rather than restarting at 1. The dials are not awaited — the boot log is on screen while they run — and the log carries `restore shells <n>`, since it reports real work. Each dial is unattended, so a host whose key was never pinned is refused here as it is on a reconnect, and a row whose host was deleted while the app was down is dropped rather than dialled.

The table follows the tab row: opening writes one and makes it active, closing takes it out, switching moves the flag, and a shell that exits clean takes its row with its tab. A tab left on a failed shell keeps its row — it is dialled again next launch, which is the thing the tabs were wanted back for.

### The screen comes back with the tab

A tab dialled back on a blank terminal has lost the one thing the user was looking at: the build log, the error, the command they were halfway through reading. The shell is new, but what the old one printed is on the phone, and it is written down beside the row.

**The terminal is saved whole.** Grid, scrollback, cursor and modes go to a file per tab in the app's own storage, never to the database: a snapshot is as big as the scrollback behind it, and it is a copy of the screen rather than a record anything else reads. It is written when the app leaves the foreground, and again while it is away, once a tab's output has been quiet for a few seconds or has run unsaved for a minute, because the shells keep printing in the background and a process killed an hour later would otherwise come back to the screen it had when the user left. A snapshot that cannot be taken at that moment, output cut mid-sequence, keeps the one before it.

**Restoring draws it before the dial.** The file is read with the row, so the tab opens on the screen it had, and the dial lands under it the way a reconnect does: the modes of the dead program are turned off, the mark is written, the new prompt comes up below the old output. A file that does not read back as a terminal is dropped, and the tab opens blank, the way it would have without one.

**It goes where the row goes.** Closing a tab removes its file, and so does a row dropped at startup because its host is gone. A file with no row beside it is removed when the tabs are read back.

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

**A session tells the views drawing it, and nothing else.** What a shell prints, what it calls itself, what state it is in, what its bar has armed and which clipboard its host turned out to have are all facts about one tab, and each is announced by that session. A key pressed with a modifier armed once announced itself to the whole store, and every view watching the store repainted on each keystroke of a `CTRL` chord, behind the sheet.

**The list tells the list.** Which tabs exist, which one a host is looking at, and which one is parked are facts about the set, so those stay with the store, and they are the only things it announces. A view that draws one tab listens to that tab; a host row watches every session it counts; nothing reads a session's state through a listener on the store. **A retired session announces nothing**, so nothing in flight when a tab closed can reach a listener that has gone.

### A failure keeps the words it failed with

The line says what happened; the detail says what the machine said. `key rejected` is the whole of what the header has room for and the whole of what most failures need. Underneath it is the transport's own sentence — the ssh error, the code the host answered with — and that is the one thing that tells the user which of the six ways a key can be refused this was. It is carried on the state, not dropped at the seam that worded the line. **An error nobody mapped is its own detail**: a throw the transport has no reason for reads as a closed stream, which says nothing, so its own words are kept and the one failure the app cannot name is the one whose text is always there.

**The reason row opens.** A tap shows the detail under it, wrapped, and a second tap puts it away; with no detail the row is not a button and does not answer a tap. What is open is copied by the cell beside it, because an error is something the user pastes somewhere else. A reconnect does not carry a detail forward: what is shown belongs to the failure on screen, and a tab that came back shows none.

**Closing a dead connection is a failure nobody needs told twice.** A dial that failed closes what it opened, and closing a socket the host reset fails with the reset; that close is awaited and its error dropped, so the log holds the one line the app wrote.

### One vocabulary says why it broke, wherever it broke

Every sentence a failure is worded with is written once — the five ssh lines, the two host key lines and the screen route's own four — and each carries whether it names the host it happened to. Two do, because a machine that did not answer is about a machine; the rest are about this connection and read the same wherever they are found, so a host handed to one of those is dropped rather than prefixed and no caller has to know which kind it is holding. The header's uppercase word is derived from the same constant, so the two forms of a shell's failure cannot say different things about it. Each failure type answers what it is and none of them says it in words: five mappings remain because there are five domains, and changing what `key rejected` reads as is one edit every layer follows. The one line with a value in it — `protocol N` — stays a function beside the vocabulary rather than a constant in it.

**Struck:** folding the host panel's verify words into that vocabulary. `NO ROUTE` and `NO ANSWER` look like the same facts abbreviated and they are not: the probe reports a machine, and it separates a socket that opens and stays silent from one that never opens — a tarpit against a dead host, which the reason lines deliberately do not distinguish. Two vocabularies, because there are two questions.

### The key bar is one row of 36, and it keeps its last cell

A bar at the bottom of the route, always drawn, above the IME when it is open, landscape included. Cells sized to their label plus 10 px each side, never narrower than 36, the hit area the full row height. `FIND` is at the head, then `CTRL`, `ALT`, `SHIFT`, `ESC`, `TAB`, the four arrows and `END` in the strip's marks and the strip's mono. That is the default layout, and `[ KEY BAR ]` on SYS rearranges it. The bar's keys go through the byte table — `ESC` `1b`, `TAB` `09`, arrows `1b 5b 41..44`, `END` `1b 5b 46`, Return `0d`, backspace `7f` — and `CTRL` turns the next letter into its control byte while `ALT` prefixes it with `1b`.

**`SHIFT` is for the keys the IME has no shifted form of.** A shifted arrow goes as `1b 5b 31 3b 32 41..44` and `SHIFT TAB` as `1b 5b 5a`, which is what an agent's TUI reads as a mode switch or a history walk. On a typed character it does nothing: the soft keyboard has already chosen the capital.

**The IME belongs to the terminal.** The view takes text input itself through a focus node the route owns, and the keyboard toggle focuses and unfocuses it. Because a modifier has to reach characters the IME types straight into the terminal, the armed set lives on the session and is applied where the terminal's output becomes bytes.

**`ATTACH` is pinned, not scrolled.** On the phone the cells are wider than the row, and the cell that puts a picture in the hands of what is running sat past the right edge of a row that looks like a whole row: the only way in for a picture was a horizontal drag nothing asked for. It sits on the other side of the rule beside the keyboard toggle, where it is always under the thumb.

**A row that goes on says so.** Whichever end of the scrolling half still has cells behind it is drawn over with a short fade into the bar's own surface, so a cell is cut by a gradient rather than by an edge that looks like the end of the row. A bar whose keys all fit fades at neither end, and the fades take no taps: the cell under one is pressed through it.

**Struck:** a `PASTE` cell. The phone's text clipboard reaches the terminal through the IME, and a bar that hides its own cells is not fixed by putting another cell on it. **Struck:** `SUPER` on this bar, which belongs to a compositor and not to a terminal.

### A modifier is armed for one key, for a count, or until it is let go

A tap arms a modifier for exactly one key and then clears it: a soft keyboard cannot hold two keys at once, and that is the rule a modifier cell answers to by default. The chords that end a program are not one key, and a session at a REPL is not a count, so the cell has three answers and the gesture says which.

### An arrow held down repeats, at the pace a keyboard does

A press on an arrow that stays down sends the arrow, waits 400 ms, and then sends it again every 50 ms until the finger lifts, which is twenty a second — the delay and the rate Android gives its own keys. A tap still sends exactly one. Only the four arrows repeat: a held `ESC`, `TAB` or `END` is almost never meant twice, and a held modifier already means a latch. A drag that turns into a scroll of the row, or a pointer lost to the system, stops the repeat at once. An armed modifier is spent by each arrow that goes, so `SHIFT` for one key shifts the first and not the rest.

### The four arrows are one stick

The four arrows are not cells on the row. One cell takes their place on the pinned side, before `ATTACH`, drawing the four arrow glyphs in a cross, whichever way the phone is held and whether it is folded or open. Upright on a phone the row could not hold four arrow cells: only `←` showed, and `↑`, `↓`, `→` and `END` sat behind a scroll. The stick keeps one place and one gesture on every screen rather than switching to cells on a screen that happens to be wider than it is tall, which an open foldable is by a few pixels. The stick is the default; `[ KEY BAR ]` draws the arrows as four cells instead, as a choice the user makes and never one the screen's shape makes.

**A push holds an arrow.** A finger that lands on the stick and moves 12 px from where it landed sends the arrow it points at, waits 400 ms and repeats every 50 ms, the pace a held arrow cell keeps; the held arm draws in the accent. Swinging to another arm sends that arrow and starts the wait again, the way a second key pressed on a keyboard does. Coming back within 6 px of the landing stops it, and so do the lift and a pointer lost to the system. A tap sends nothing.

**No diagonals.** A terminal has four arrows, so the axis the push leans on decides. Leaving the held arm for the other axis takes 1.4 times the travel on the new axis that the held one has, so a thumb near the diagonal does not flicker between two arrows.

**The stick takes the pointer the moment it lands.** Neither the route nor the bar gets a drag that starts on it. Each arrow it sends spends the arming like any other key.

The screen's key strip keeps its four arrow cells: nothing is pinned there.

**A downward drag sets a count.** One drag arms the cell at two, another takes it to three, which is the cap; an upward drag walks it back down and past two disarms it. **A long press latches it**, and a tap on a latched cell lets it go — the same tap that arms an unlatched one. A downward drag on a latched cell does nothing, there being nothing above forever, and an upward drag releases it whole. No cell is added to a bar the phone already scrolls, and a user who never drags never sees a count.

**The label rolls to say so.** The cell reads `CTRL(x2)` for a count and `CTRL(∞)` for a latch, arriving on a 140 ms downward roll — the old word leaving through the floor, the new one coming in through the ceiling — in the same accent an armed modifier already draws in. A latch replaces a count, and releasing goes back to the bare word.

**The arming belongs to the session, not to a cell.** One session holds one arming: which modifiers, how many keys they survive, and whether they survive keys at all. `CTRL` and `ALT` armed together apply to the next keys, both of them; `CTRL` latched and `ALT` tapped on after it are both latched; tapping either takes that one off, and the arming ends when the last modifier does. Switching tabs switches it with the session, and a reconnect, a close and a dead shell drop it.

**One spender.** The armed set is spent where every byte passes — the store — and the bar does not clear it on the side, so the bar's own keys and the characters the IME types count the same. A count walks down as keys go; **a latch is spent by nothing**.

**Only a key spends it.** A terminal answers the program on its own behalf — where the cursor is, what it is, how big it is, where a finger touched — and those replies go out on a path of their own. Nothing armed applies to them and nothing armed is spent by them. Left to share the user's path, an `ALT` put an `ESC` in front of a cursor report and the program read the wrong answer, and an agent that asks where the cursor is left `CTRL(x2)` at one before a key was pressed.

### The terminal's type is pinched to size, and the size is kept

A two-finger pinch scales the type: spread to grow, close to shrink, live while the fingers are down, rounded to whole points and held between 8 and 24, with 13 the default. Columns and rows follow the size the way they follow a rotation — the view re-measures, the terminal resizes and the host is told — so a smaller face is more columns and rows, not more margin.

One size for every shell on every host, kept in the settings table and read on the next open. It is the user's reading distance, not a property of a host or a tab, so it is not per anything, and there is no row for it in SYS: the gesture is on the surface it changes and the change is visible while it happens, which is the whole of the feedback. One finger stays the terminal's — a drag scrolls the buffer and a long press selects — and the pinch is taken only once two fingers have moved past the tap slop. The phone's own font scale still applies on top.

### Scrollback is compressed between frames

A terminal's scrollback is compressed in bounded steps once its output has been quiet for a quarter of a second. A step runs when no animation holds a frame, and waits for the end of the next frame while one does. With the app away no frame comes, so compression waits for the return. It is never queued as an idle task: Flutter refuses those while an animation holds a frame, and with frames stopped out of sight the refusal posts itself again without end, a busy loop on the main thread for as long as the app is away.

### A run of operators is shaped once while it stays on screen

A run of operator characters — `=>`, `!=`, `//` — goes through the text shaper so its ligatures form, and that is the costliest thing a row rebuild does. A laid-out run is kept by its text, colour, weight and slant and shared by every row that shows it, so a rebuilt row showing a run it had before reuses it instead of shaping it again. A run no row paints any more is kept among the last 256 of those, and a theme change or a change to the system's fonts forgets them all.

### A press selects where the finger is, and takes the whole thing

**A held finger takes what is under it**, the way a phone's text does, with a tick under the finger when it takes, and the drag after it grows the selection a word at a time. The grips on its ends are the terminal's own, with its magnifier; the cell is resolved by the engine against the line it is on, so output printed under a held finger leaves the selection on the text that was pressed. One finger selects and a second one is a pinch.

**The unit is the run, not the word.** A word rule breaks on `.`, `:`, `-` and `/`, which are the characters a URL, a path and `file.dart:42` are made of, so it can only ever hand back one segment. A run ends only at a blank, at a quote or backtick, at a bracket of any shape and at the rule a full-screen application frames itself with; everything between is taken. That takes `/home/luis/x.dart:42`, `git@github.com:o/r.git` and `url=https://x.dev/a/b?c=1` whole with no per-shape regex zoo, and a press on the word after a blank takes that word. **A soft wrap is not a boundary**: a URL the width of three rows is one press.

**Over an application reading the mouse the hold is still the user's.** A touch reports its click on the lift, so a finger held still has sent the application nothing when the hold is recognised, and the hold becomes the same selection, with its grips, its magnifier and `COPY`, instead of a click. While a selection is up a touch is the selection's: a tap lets it go and is spent on that, a hold takes another word, and the tap after it is the application's again.

**A selection keeps to the pane it was pressed in.** On the alternate screen, or under an application reading the mouse, a press looks for the rules a multiplexer splits the screen with: a column of vertical strokes at least three rows tall through the press row on either side, and a row of horizontal strokes across the whole width between those above and below, meeting a corner or a tee at each end or running into the screen's edge, the way tmux and herdr join their borders. The box they close is the pane, and the selection lives inside it: a drag or a grip past its edge stops at the edge, and every row of the highlight and of the copied text is cut to its columns, so neither the sidebar nor the pane beside it comes along. tmux told to leave the alternate screen alone still draws its panes over the primary one, and still reads the mouse, which is how its panes are found there. A single `│` in a line of text closes nothing, nor does a table's rule, which ends against the pane's plain side; and a shell on the primary screen has no pane, so a table drawn in its output never cuts a selection. A row whose text runs to the pane's right edge is the multiplexer wrapping a long line, and is copied joined to the next, unless it ends in a box-drawing stroke; any other row ends with a newline. The pane's own history is out of reach: what a selection can take is what the pane shows.

### A program on the host copies to the phone

An OSC 52 write from the host puts its text on the phone's clipboard: a multiplexer's selection, an editor's yank, whatever a desktop terminal would have copied for it. Only the standard clipboard is taken. A primary selection, which some programs set on every highlight, would overwrite what the user copied under them, and a request to clear the clipboard is not a copy. **Nothing is read back**: a program asking what the clipboard holds is told nothing, because the phone's clipboard holds what was copied everywhere else. The system's own copy notice is the confirmation, and the app draws none of its own.

### A click names a row of the screen, not a row of the scrollback

A terminal holds two coordinate spaces and they are not the same one. The buffer is the scrollback and the screen in one list, and a cell in it names a row that follows its line for as long as the line is kept. The screen is the rows drawn right now, and its first row sits at the buffer's row less however deep the scrollback has grown. A pixel under a finger resolves into the buffer, because that is the space a selection lives in.

**What crosses the wire is the other one.** An application asked for mouse reporting because it draws a screen, and the screen is all it has: it keeps no scrollback and has no row to name outside the one it painted. A report carrying a buffer row puts every press as many rows below the finger as the scrollback is deep, and that distance grows with the session instead of staying wrong by a constant. So a press, a release and a wheel report take the cell the pixel falls in and then subtract the screen's first row, clamped to the screen; a selection, a long press and a drag keep the buffer's row untouched. On the alternate screen the two agree, a screen with nothing behind it being its own buffer, which is why a full-screen application is the last place the difference shows.

### A redraw in flight does not swallow a touch

An application that redraws in one piece wraps each frame in synchronized output, and the terminal keeps the last whole frame on screen until the new one closes. Over a program that does not read the mouse, a touch on a held frame lets it go and is spent, because the cell under the finger may already hold something else. **Over an application reading the mouse the touch is the application's anyway**, and the frame stays held until the application closes it: the application resolves the click against the screen it holds, not the picture the phone drew, and a drag that tore every frame it crossed would show half-drawn screens for as long as the finger moves. A multiplexer redrawing behind a streaming agent holds a frame most of the time, so a spent touch would lose most taps while the agent works, with the keyboard still answering. A touch over a selection stays the selection's.

### The wheel under a full-screen application is one listener

A drag over an application that asks for mouse reporting is its wheel, and the terminal turns each line of travel into a wheel report at the cell under the finger. **The screen does not decide it, the mode does**: a multiplexer or an agent that reads the mouse on the normal screen has scrollback under it, and a buffer that scrolled under the drag took it before a single report went out. While the mouse is read the buffer does not scroll under a finger; the moment the application lets go of the mouse, a drag is the scrollback's again.

### A view off the live line says so and offers the way back

The terminal follows its output only while it is on the last line. Scrolled up it stays where the reader put it and the shell goes on printing underneath, which is right and is the whole problem: nothing says the shell has moved on, and the way back is a drag of unknown length through a scrollback ten thousand lines deep. A cell over the terminal's bottom trailing corner appears the moment there is anything below the fold and goes when there is not, and a tap on it lands on the last line, from where the shell scrolls itself again.

**A key is not a read.** Bytes from the bar go straight to the remote and never pass the view, so anything sent to the shell puts the view back on the last line first. **One thing floats over the terminal at a time**: while there is a selection the corner belongs to the copy cell, and the way back waits until the selection is let go.

### The selection asks a surface where the cells are

What the selection's verbs need from the thing under them is named once: where a cell is and which rows the selection covers, on the geometry the view hands the layer it draws over the terminal. **A cell's offset is already in the layer's own coordinates** — the terminal is drawn inside an inset and the layer is not, so the view settles it and nothing on top adds a padding of its own. The `COPY` cell sits over the top row of the selection, and under its bottom row, past the grip hanging off it, when the top row has no room over it. **No surface is not a wrong surface**: with no view laid out to ask, the `COPY` cell goes to the corner over the key bar, where a thumb already is.

The route is one job per file. The sheet and its drag, the header, the terminal and its theme, and the selection are four things, and the file that holds the route holds the route.

### A selected link opens from the terminal

The floating cell reads `COPY` and `CLEAR`, and between them, on a selection that is a link, `OPEN`. It is drawn only when the selection parses, so the cell says what the selection is: the verb appearing is the app agreeing that those cells are a URL, and a grip dragged one character too far takes it away again. `CLEAR` keeps the trailing edge, because it is the way out of the selection and the last thing a thumb should find by accident; `COPY` keeps the first, because it is the verb that is always there.

**The scheme is the whole test.** A selection is a link when it says `http` or `https` in front of an authority, and nothing else is promoted: `min.io/docs` off a wrapped paragraph, `/home/luis/x.dart:42`, `git@github.com:o/r.git` and `mailto:` are left as text. Nothing demands a dot in the host either — `http://localhost:3000` and `http://100.118.60.77:8080/` are what a dev server and a tailnet address actually print, and a terminal is where you meet them. This is the opposite trade to the capture field's prose rule, which promotes a bare host and refuses a dotless one, and both stand: a title is prose and a selection is what the user dragged a grip across. **A run opens from its scheme**: a press takes `url=https://x.dev/a` whole, and `OPEN` takes the link that starts at `https`. **Whitespace ends it** — two words are not a URL, and a range dragged over a hard-wrapped line carries the newline that says so, while a soft wrap does not, the buffer stitching a wrapped line back into one string.

**Opening spends the selection, unless nothing took it.** The highlight goes when the browser goes, the way it goes on a copy. A launch the device refused leaves the selection and its cell where they were, so the words are still there to copy instead. There is no second look at the buffer: the press that made the selection did the finding, and there is no scan of the screen for links and no underlining of what was never touched.

### The scrollback is searched from a line under the terminal

**`FIND` opens a line, not a page.** A tap raises a line between the terminal and the bar — a field, the count, a step either way and the way out — and a second tap takes it down, with no sheet either way. A shell has no key that searches its own scrollback, and ten thousand lines is not a thing a thumb reads through.

**What is typed is looked for and nothing is sent.** The line takes the keyboard off the terminal while it is up, so the characters land in the field; the buffer is read and the shell is not written to. The bar's keys still reach the shell, because a search is not a mode.

Every hit is marked and the one being read is marked apart, both as washes the text shows through — a block over a glyph hides the very word that was found. The finding and the marking are the terminal's own; the line only drives them. **A search starts on the newest hit**, because what is being looked for is almost always what just went past, and the steps walk back from there; past the oldest is the newest again. The hit being read is put on the screen, which is what makes the mark worth drawing. Closing takes the marks with it and leaves the view where it is, because the line that was found is the reason the search was made.

**Struck:** a jumper that walks the user's own turns. Half the panes could never be walked and the half that could was the half that did not need it: a scan reads whichever buffer the pane is showing, which is the whole history on a classic renderer and exactly one screen on a fullscreen one, and on a fullscreen renderer the turns above the top row are in no buffer the app holds. Nothing the app is allowed to do reaches them — writing scroll reports at the pane, reading the host's own session files, and a multiplexer's scrollback capture that scrolls the pane and refuses while the agent is working, which is when a phone is watching. A feature that is right on one renderer and quietly partial on the other is worse than no feature, because the user cannot see which one they got. A search is honest under either: a count of zero on a screen with no scrollback is an answer, where a jumper that steps three turns out of thirty is a claim.

### `ATTACH` puts a picture in the hands of whatever is running

The cell is a picture, drawn in the accent while memory holds anything; the count is not on the bar. The sheet it opens is `[ ATTACH ]`: `PHOTOS` first, an action block that opens a multi-pick of the gallery and attaches every picture picked, the lightest first, and `PHONE` beside it for any file on the phone; then a rule and `HELD`, the tiles of what the screen route is holding, or `NOTHING HELD`, a tap attaching one and `×` dropping it. **Photos are never held**: they go in and are forgotten.

**A `?` on the header strip, beside `CANCEL`.** A host is uploaded to, a clipboard is written and a keystroke is sent, and none of that is visible from a sheet of two verbs and a grid of thumbnails. `?` is a toggle and not a route — the sheet is the only surface the answer is on — and the copy is off until it is asked for, because a sheet that explains itself every time is a sheet whose explanation is scrolled past. Opening drops the copy in above `PHOTOS`, over its own rule, and the `?` goes accent while it is open; nothing else on the sheet moves and reading attaches nothing. Four things are said and no more: what `ATTACH` is for — a picture put in the hands of whatever is running in the shell, read off the clipboard rather than named at it; what `PHOTOS` does — the gallery, many at once, the lightest first, and the path typed at the cursor where the host has no clipboard tool; what `PHONE` does — any file, a PNG like a photo and anything else as its path; and what `HELD` is — the crops, kept for the app run, a tap to send and `×` to drop. It is the sheet's own body copy, so it is the Sans of an action sheet and not another tracked mono label.

**A clip lives for the app run and nowhere else.** It is not an attachment, it has no row, and it does not survive a launch. The file sits under a `clips` directory in the cache the system may take back on its own, and the app deletes that directory before the first frame, which is what makes "runtime only" true across a kill nobody saw. In memory the app holds the record and nothing else — id, file, pixel size, source, the host it was cut from, the moment — and no thumbnail: the tray draws the file at tray width, so the full picture is never decoded whole. The budget is eight clips and 24 MB, whichever binds first; a ninth, or one that crosses the ceiling, deletes the oldest until it fits, and dropping the last one takes the directory with it. A clip cut on one host may be attached on another, so a shell session is the wrong owner for it.

**The bytes go up over sftp, every time.** Never the pty, whose bytes a pty would translate, and never the link the terminal is on: a file goes up on a transfer link, a second ssh connection to the same host, user and key, dialed when the first file needs it and ended five seconds after the last one lands or with the link beside it. A picture queued on the terminal's own link waits ahead of its keepalive, and on a slow uplink that is long enough for the keepalive to go unanswered and the shell to end. On it, the directory `/tmp/striked` made and the file written whole to `/tmp/striked/<name>`. A host with the subsystem off gets the same file on an exec channel, `mkdir -p /tmp/striked && cat > /tmp/striked/<name>` with the file on stdin and exit 0, so no host the app can open a shell on is refused a picture; a host that started sftp and then refused the write has given its answer, and it is not asked again over exec. The write is one piece shared by every upload in the app, the terminal's paste and an agent's start alike. They go up on every paste rather than once per host: `/tmp` is cleared by a reboot the app never hears about, and a path an agent is then told to read would be a lie. The file is left there; the host's own reboot is the cleanup.

**Pasting is the clipboard, on every host that has one.** Neither agent reads a picture off the terminal — both take it through the system clipboard and what the terminal sees is a key — and over ssh the agent runs on the host, so the clipboard that matters is the host's. The app writes it directly: upload, set the host's clipboard to the file as `image/png`, then one `0x16` into the pty, and both agents answer `[Image #1]`. Many at once are a queue on that link: three go up at a time, the lightest first, so a heavy picture never holds the light ones behind it, and each is pasted as it lands, one copy and one `0x16` per picture, with 300 ms between them because the agent reads the clipboard on the keystroke and the next write has to wait for that read. The agent numbers them in that order, so `[Image #1]` is the lightest. The sheet reads `ATTACHING 2 OF 5` while it runs and `PASTED · 5` or `PATH · 5` at the end for a moment; a failure stops the run where it is and leaves its line on the sheet.

**The queue is drawn while it runs.** Under the status line, `2 UP · 1 QUEUED · 2 IN`, then one row per picture in the order the queue takes them: the thumbnail, its weight, a tag and a bar. The tag is `QUEUED` in `--text-muted` over a dimmed thumbnail and an empty bar; `UP 43%` in the accent, the weight read as sent over total and the bar filling with what the host has acknowledged; `LANDED` in `--fg-dim` with the bar full, waiting its turn at the clipboard; `PASTING`, then `PASTED` or `PATH`, in the accent; `FAILED` in `danger` with the host's words under the bar; and `STOPPED`, dimmed, for every picture a failure or a closed sheet left behind. A file that went over exec has no acknowledgement short of its exit, so its bar fills at once when it lands.

**Four clipboard backends, one per display server, all first class.** Wayland: `wl-copy --type image/png` under `setsid`, since the process that owns a Wayland selection must outlive the channel that started it. X11: `xclip -selection clipboard -t image/png`, likewise detached, or `xsel` when `xclip` is absent. macOS: `osascript` reading the file as a PNG pasteboard item, which is the only way to put a picture on the pasteboard from a shell. And none: the host has no display server and there is no clipboard to write. Windows hosts are not addressed; the probe reports them as none.

**The probe runs once per host per connection**, cached on the connection and re-run when it comes back, and one exec channel answers all of it: the system name; the runtime directory and the first Wayland socket in it; the X display and its authority; and which of the tools are on the path. An ssh exec channel inherits none of a desktop session's environment, so every one of those is read rather than assumed, and the pair the backend needs is carried on the command the paste runs. **Wayland is probed one step further**: a watch on the selection is run under a one-second timeout, and the timeout killing it is the data-control protocol being present while an immediate exit with the compositor's own complaint is it being absent. Listing the types is not the test — the tool exits 0 on an empty selection and 1 on "Nothing is copied", neither of which is about the protocol. That extension is the same one the agents' clipboard reader needs, so a compositor without it is a host with no clipboard as far as this feature is concerned, and is reported as such rather than being allowed to fail at the moment of a paste.

**The result is a fact about the host and is drawn as one.** The host panel carries a `CLIPBOARD` row while a shell is open on it — `WAYLAND`, `X11`, `MACOS` or `NONE` as mono tokens — and `NONE` carries its reason under it in `--fg-dim`: `no display server`, `no wl-copy`, `no xclip`, `compositor without data-control`. A host whose clipboard is missing a tool it could have is a host the user can fix, which is the point of saying which tool.

**Where there is no clipboard the app types the file's absolute path into the pty at the cursor, and a space after it.** This is not a lesser version of the feature: it is the documented way in for both agents, and on a headless host it is the only way in that exists. The tray says which of the two ran, `PASTED` or `PATH`, for a moment. **Neither failing types anything and neither leaves half a paste**: the upload must land before the clipboard command runs, and the clipboard command must exit 0 before the `0x16` goes in.

**The login shell behind an ssh session carries no desktop environment**, so an agent started in a tab found no Wayland display and fell back to an X11 socket it could not reach, while the picture was on the Wayland clipboard the whole time. The host's own login shell is where that is fixed: with no display set it discovers the first socket under the runtime directory and exports the runtime directory and **one** display — Wayland when a socket is found, X11 only otherwise. One and not both, because an agent's reader tries X11 first, and on a Wayland desktop the X11 clipboard is the bridge, which holds the selection only while an X11 window has focus. A multiplexer attached from the desktop never had the problem, which is why it went unseen.

**Struck:** forwarding the host's Wayland socket over a stream-local channel and speaking the clipboard protocol from Dart. It removes the dependency on one tool and buys nothing else — it cannot help X11, macOS or a headless host, and it puts a hand-written Wayland client in a phone app to save one `command -v`.

### `VOICE` dictates, and an agent's tab gets a composer

The cell is five level bars on the pinned side, between `ATTACH` and the keyboard toggle. A press starts listening at once, so the first word is not lost to a wait. A lift after 400 ms ends it, which is hold to talk; a lift sooner leaves it listening hands-free until the next tap, for a phone held at arm's length. A pause while it listens does not end it: what was heard so far is settled and listening carries on.

**The cell shows the microphone working.** While it listens the bars stand in the accent as a level meter of what the microphone hears, at most twelve readings a second: the centre bar is the latest reading, the pair beside it the one before, the outer pair the one before that, so a voice reads as a trace moving out from the middle and silence as five short bars. After the lift, while the recognizer finishes its last words, the panel reads `FINISHING`, and the cell holds still and gives way to the dot spinner once the wait passes 200 ms. When the words land, in the composer or at the cursor, the glyph takes the five-frame icon glitch, as a capture landing does. The meter is the one moving thing here that runs for as long as a state lasts, and it is allowed because every frame of it is a reading and not decoration; the glitch stays an event. Reduce-motion keeps the bars still in the accent and skips the glitch.

**A recognizer that will not start again is not asked forever.** Each restart after a pause waits a beat for the last session to let go. One that errors before hearing anything is rebuilt and asked once more, and three restarts in a row with no speech end a held dictation with what was settled, or `NOTHING HEARD`, and pause a tapped one.

**The recognizer is the phone's own, or Whisper once it is downloaded.** Without a model it is Android's speech service, asked to stay on the device wherever it has the language. With a model from `[ VOICE ]` on SYS, the app records the microphone itself, 16 kHz mono, and Whisper hears the recording on the phone after the lift, small when it is on the phone and base otherwise, in the language `[ VOICE ]` names, or in whatever language it detects when that is `AUTO`. Detection is a guess made again for every thirty seconds, and a short stretch of Spanish read as Portuguese comes out wrong whole, so a user who speaks one language names it. Whisper hears thirty seconds at a time, so a longer recording is cut at its quietest moment between twenty and twenty-eight seconds in and the pieces are heard in turn, none of it dropped. Whisper hears a recording whole and not word by word, so the panel holds `LISTENING` and the meter with no words under them until a pause, and `FINISHING` lasts while it transcribes. Recording starts the model loading, so the load overlaps the speaking. A recording that never rose above the room is `NOTHING HEARD` without being transcribed, because Whisper given silence invents a sentence. One recording runs at most two minutes and then finishes as if lifted, or pauses when the dictation was tapped. Either way the audio stays on the phone: it never reaches the host or any server. The microphone is asked for the first time the cell is pressed and not before.

**The dictation floats over the terminal, not in a row over the key bar.** While it hears, a panel as wide as a phone column, 280 at most, rests against a side edge of the terminal, low on the right at first but always above the close target's spot, and never past the terminal's edges when the keyboard or the composer takes room. Its header holds the meter, or the voice glyph when the bars have nothing to read, then the state in the accent, `LISTENING`, `PAUSED` or `FINISHING`, centred on the panel and not on what is left beside the glyph, and at the right the dot spinner while Whisper is still hearing a stretch already recorded. Under it, the words heard so far, the settled ones primary and the guess still forming muted, four lines tall and scrolled to the newest. The header is the drag handle: the panel goes where the finger takes it and the release glides it to the nearer side at that height. Dragged past a nudge, it raises the close target at the bottom centre of the terminal, the one a dragged float meets, and dropped on it the dictation is thrown away. The panel stays when its tab is not the one shown, and a tab that closes throws its dictation away. A failure takes the header for two seconds in warning and names itself: `MIC DENIED`, `NO RECOGNIZER`, `NOTHING HEARD`, `VOICE FAILED`. A failure never costs the words already heard: they land, and the failure shows after them.

**A tapped dictation is driven from the panel.** Once a tap has left it listening, the panel's foot carries two glyphs and no words: the pause bars, and a bare check in the accent, drawn in the same strokes as the bars and without the house diamond. Pause stops listening and keeps what was heard: Whisper hears the stretch just recorded while the panel waits, so the preview is the words and not a promise of them, and the phone's recognizer settles its last guess. The play glyph in its place resumes: it listens again and what follows joins the same dictation. The check, or a tap on the cell, ends it and lands the words, which still only land: nothing is sent from the panel. A tap while a resume is starting ends it as soon as it hears. A stretch that fails, Whisper's or the recognizer's, short of the microphone being refused, pauses the dictation with the failure in the header and the words so far under it, and resuming clears it. A resume the phone refuses ends the dictation with what was heard. A recognizer that never says it stopped is let go after five seconds. A recognizer that gives up on silence, the two-minute cap and the app leaving the screen pause a tapped dictation instead of ending it. **A held press throws it away by the drag as well.** Once the finger slides off the cell, a close target rises above the cell, and the dictation lifted on it is thrown away; lifted anywhere else it ends as a lift does.

**Where the words go is decided by what the tab is running.** A tab whose agent is Claude Code or Codex sends them through a composer. The tab counts as an agent's when it is a herdr pane the agents panel names, when its command starts one, or when its title is the one the agent set. The composer stands above the key bar: the agent's mark and name on its strip, `CANCEL` and `SEND` at the right, and under them a field of up to six lines holding the draft, which the next dictation appends to and the keyboard edits. `SEND` pastes the draft whole, bracketed when the agent asked for bracketed paste, and presses Return 80 ms after, so the agent takes it as one message and not as typing that happened to contain a Return. Each tab keeps its own draft until it is sent or cancelled. Anywhere else the words are pasted at the cursor and nothing is pressed: a command said aloud is read before it runs.

**Struck:** a hosted recognizer. A server that hears the user is the wrong place for their voice. **Struck:** the agents' own dictation. The Codex CLI has none, and Claude Code's records the host's microphone, not the one in the user's hand. **Struck:** shipping the model in the app. It is 161 MB at the least that a phone with a working recognizer never needs. **Struck:** an auto-send setting. The agent's tab already sends with one tap, and a shell that runs whatever was misheard is the wrong default.

### A passphrase the host asks for is asked for on the phone

**The prompt was never the app's to fix alone.** A key agent asks for a passphrase on whichever tty it was last told about, through a pinentry that draws over whatever is running there: a full-screen application in a tab gets a curses box painted across it and the two fight for the same keys, and no terminal can stop that from its own side. So the host runs its own pinentry, which never touches the tty that asked — it puts a modal on the computer, a fullscreen terminal window on the graphical session or a reserved console otherwise, and at the same moment writes the request into every terminal that asked to be told. The first decision wins and the others withdraw. This app is one of those terminals, and what follows is the terminal's half.

**A shell marks its pty the moment it is up.** On the tab's own connection, an exec channel writes the pid of whatever holds the tab's pty into the pinentry's directory under the pty's name. The holder is the connection's own sshd session, which is the channel's parent, or the Mosh server the tab was started under, found by the tab's mark in its environment — a Mosh shell hangs off a server that let go of the ssh session that started it the moment it came up, so the channel's parent owns no pty then. The mark is a pid rather than a token because a mark whose holder has ended is stale by inspection and the pinentry drops it itself; the app never unmarks, not on close and not on a redial, which marks again on its own. A host without the pinentry gets a directory nobody reads, and the exec's failure is dropped unspoken either way.

**The request is a private OSC and the answer is a fifo.** One sequence carries what the agent said — mode, description, prompt, the error line of a failed try, its own labels for the two verbs — and another says the request was settled elsewhere. The terminal already parses OSC and hands the ones it does not know to the session, so nothing scans the byte stream. The answer goes on a second exec channel, `cat` into the fifo the id names, guarded so that a request already gone leaves the passphrase in no regular file. It travels on the channel's stdin and never on a command line; a bare newline is the cancel; an id outside `[a-f0-9]{16,32}` is not a request and nothing is run.

**The bell is the signal and the host is the source.** An OSC reaches a tab whole over ssh, but a Mosh shell's pty ends at a server that ships a screen and not a byte stream, and a sequence it does not know never leaves the host. So the pinentry rings the pty's bell after every sequence, request and withdrawal alike, and a tab that hears a bell — any bell, whoever rang it — asks the host what its pinentry holds open: one line per request, a request being open while its fifo stands. What comes back is the tab's request, and nothing coming back withdraws the one it had. Bells that land while the host is being asked fold into one more ask, so a program that beeps ten times costs one exec and not ten. The pinentry takes the fifo and its json down before it rings the withdrawal, so a tab that asks then finds nothing. Mosh rings once per frame it ships, so a request and its withdrawal inside one frame ring once; a tab holding a request therefore asks again every five seconds for exactly as long as it holds one, and takes the empty answer as the withdrawal. **One request is one fifo**, so an answer from one tab settles it on every tab of the host at once, and an answer that comes back on a connection that is no longer the tab's is dropped.

**The sheet reads `AUTHORIZATION REQUIRED`.** Under the header: which shell, what the agent said about the key in its own words, the error line in the danger colour when a try failed, an obscured field under the agent's prompt, then `CANCEL` and `UNLOCK`. A confirm carries no field and draws the agent's own labels on the two blocks; a message draws one. Return on the field is `UNLOCK`. One at a time, and on the shell route only: a request that lands while the user is on Home has the computer's modal, and is put up when the route is entered if it is still open then. Every tab lists what the pinentry holds open as it connects, after its mark, so a request made while a tab had no link is found rather than missed. The sheet goes up for the tab on screen when it holds one, else for the first live tab that does, and its `SHELL N` follows every tab of the host, since a tab taking a request is that tab's own news.

**Withdrawal is not cancel.** The withdrawal takes the sheet down with nothing sent — the computer answered, the agent gave up, or the host's own window ran out. Swiping the sheet away is the phone declining to be the one that answers: nothing is sent, the request stays open on the computer, and the sheet does not come back on its own for that id. A swipe is as often a slip as a decision, so for as long as a live tab of the host still holds the request it swiped away, the header carries a key mark beside `DIFF`, in the accent and in warning once the ask may have expired; a tap puts the sheet back up for it. The mark goes when the request does, by the same withdrawal that would have taken the sheet down, and it is never drawn while a sheet is up. `CANCEL` is a decision and cancels everywhere. A connection that drops or a shell that exits takes the request with it, because the fifo it would be answered on is on the other side of a link that is gone.

### A passphrase ask grows old, and an answer that reached nobody says so

**The host never says how long it waits.** The pinentry holds a request for a window of its own and ignores the agent's own timeout, so nothing on the wire carries a deadline: the payload is the agent's words and the open listing says a request stands, never for how much longer. When the window runs out the fifo comes down and the same withdrawal an answer at the computer sends is rung, so from the phone's side an ask that expired and one settled at the computer are one event and always were. What the phone can know is its own clock, so it stamps an ask the moment it first hears it and counts up from there; it never counts down to a deadline it would be inventing, and it never says an ask is over on a count alone.

**An ask the phone has held five minutes stops presenting itself as certainly live.** The count is taken on the recheck that already keeps the ask alive, and one that keeps coming back past five minutes is drawn from then on as one the host's own window may have run out under: `MAY HAVE EXPIRED` in warning over the field, and the affirmative block loses its fill. Both blocks stay tappable — the host listed the request as open a moment ago, and refusing the answer on a local count would be the phone's guess overruling the host's own word. The id does not change as it ages, so the sheet stays where it is and the shade is not rung again. Five minutes is the pinentry's own default window, which the phone cannot read and does not claim is the one in force.

**An answer that reached nobody is not swallowed.** The passphrase is written into the fifo only while the fifo is there, so what that command comes back with is the verdict: a failure is proof the ask was already down, that nothing was written and that nothing is waiting on it. A command that never comes back says the same thing more quietly, and it is the commoner half — a pinentry that died without taking its fifo leaves one that still passes the guard, and the write into it waits on a reader that is never coming. So the answer is given five seconds to land, and a write still going when they run out is read as an ask that is gone. **The channel it was on is taken down with it**, because closing the channel is the only thing that ends a command blocked on something that will never arrive, and a dead request must not hold the connection and the passphrase written into it open for the life of the session. The phone says so instead of letting the user believe they unlocked anything: `AUTHORIZATION EXPIRED` over the shell it was typed on, that the host had taken the ask down so nothing reached it, and that the ask comes again if the key is still wanted. A channel that never came back at all is the link going, which already has the route's own word on it, and gets no second sheet.

### A passphrase the host asks for rings the shade

One notification per host, on a channel of its own — high importance, with the channel's own sound and vibration — so a blocked agent can be kept quiet and a key being asked for still heard. The title is `AUTHORIZATION REQUIRED` and the text is the host's name in capitals and what the agent said about the key, the prompt when it described nothing, the name alone when it said nothing at all. It reads the same in the shade as on the sheet, and it carries nothing the system adds: an ssh key's comment is often an email address, and Android hung a chip offering to write to it under the passphrase ask.

**It is heard through Do Not Disturb, once the user lets it be.** Android holds every notification silent under Do Not Disturb unless its channel bypasses it, and only an app the user has given Do Not Disturb access to may say so. `[ ALERTS ]` carries `PASSPHRASES IN DO NOT DISTURB` under the two agent rows, on while that access stands and reading `SILENT UNDER DO NOT DISTURB` while it does not; either way the switch opens Android's own list, because the grant and its withdrawal both live there. The channel is created bypassing at every start and again when the row sees access arrive, since Android drops the bypass from an app without access and takes it onto an existing channel only then. Nothing else the app posts passes Do Not Disturb. **With the app in front the phone buzzes as well**, from the app itself rather than from the channel, so the ask is felt with Do Not Disturb on and access never given: the user is looking at the app, and Do Not Disturb holds back what reaches them from elsewhere. The same ask posted again buzzes no more than it sounds. **Struck:** vibrating as an alarm to get past it without asking, which passes only while the user lets alarms through and tells the system the ask is something it is not.

**Up while any tab of the host holds the request, down the moment it is settled.** Two tabs that hear the same request are one notification; a request with another id replaces it in place and sounds once more, because it is another ask. Answered on the phone, answered on the computer, given up on by the agent, lost with the link, dropped by a redial or gone with its tab — each takes it down, and it comes down exactly once. The store is what knows all of that, so the store tells the shade. **A notification re-rung at five minutes would wake the phone to say the same thing less certainly than the first time**, so the shade is left where it is: age is something the reader sees when they come to answer, which is the sheet.

**The watcher hears the ask the tabs are not there for.** A tab hears a request because it is on a live connection, and a phone in a pocket has none: the process is gone or its shells are, the ask stands at the computer unheard, and the app finds it on the way in — the one moment a notification was never needed. So the agent watcher holds a channel per host whose shell lists what pinentry holds open every two seconds and sends the listing only when it changes, with the same beat and the same five minutes of silence, on the connection it is already holding for that host — a host where that will not stay up is asked every fifteen seconds instead — and rings the same notification a tab rings. A host the watcher reaches through the engine is asked the same way, and a host it reaches both ways is asked on one of the two, so it rings once. It marks nothing: the listing is a directory read, and the mark is only how a request reaches a tty. It reaches the hosts the watcher reaches and no others, and **it has no switch of its own** — a passphrase ask is not an agent, and the watcher is either up for one of its own kinds or it is not up at all.

**Each side takes down only what it put up.** The tabs and the watcher read the same directory on the same host, so they cannot disagree about what stands in it, only about when they last looked — five seconds against two. Each keeps its own note of the id it rang for a host and withdraws on its own empty answer; neither rescinds what the other raised. It is one id per host however many are looking, so the shade holds one line, and the tap clears it. The same ask posted again by the other side updates that line without a sound; only an ask with another id sounds.

**The tap is the way to the sheet.** It opens that host's shell, taking the sheet over from another host's if one is up; the passphrase sheet is already standing there, and the sheet stays until the request is settled. A tap that starts the process is parked the way an alert's `OPEN` is and replayed once Home is on screen, on the host it named — a host deleted since opens nothing. The replay is not a tap, so it dials nothing: it lands on the tabs that host already has, and a host with none opens on a strip with no group of its own, where the user's own tap on the `+` is what dials it. There are no `YES`/`NO` here: a passphrase is typed, never tapped, and the answering is the half that wants the activity up. The hearing is not, which is what the watcher is for.

**The ids keep out of the alerts' way.** An alert id is 1000 plus thirty bits of its host and pane; a passphrase id starts above that region and folds the host to twenty-nine bits, so the two never collide and both stay inside the signed 32-bit id Android takes. The payload names the host and nothing else: the sheet has the request.

### A shell that lost its network comes back on the pane it was on

A link that dies under a live shell puts the tab on six waits — one, two, five, ten, twenty, thirty seconds — and every dial goes back to the same tab, the same terminal and the same attach command against the same pane id, so the agent is where it was and `-- reconnected --` is the only new line between the dead shell's output and the new one's.

The end of that schedule is a tab waiting, not a tab that failed. The link is gone, the terminal still holds every byte the dead shell printed, the tab still carries the command it runs and the pane that command attaches to, and nothing is on a clock: sixty-eight seconds of schedule can run in a pocket, so a phone that was asleep comes back to a shell it can still have rather than to a dead tab. A waiting tab carries what its last dial hit rather than the drop that started the schedule, so the row under the header reads `rose unreachable` and `STOP` ends the tab on those same words. Only a closed stream and a machine that did not answer get there. A key the host refused, a shell it would not give and a host key that is not the one pinned are answers rather than accidents: they fail on the first dial and are never waited on or woken.

Two moments dial a waiting tab again, and it has no clock of its own. The app coming back in front, and a network arriving under it — the platform's default-network callback, so a handover straight from wifi to cell counts as an arrival even though the phone was never without a network, and nothing is replayed on subscribe. Either moment dials every waiting tab once as the first step of a fresh schedule, so a dial that misses waits two seconds and goes on rather than running the whole minute out again unwatched. A tab still inside its schedule has a timer already and is left to it, unless the wait ran out while the phone slept: the timer stopped with the phone, so a wait whose end has passed on the wall clock counts as due, and that tab dials on the wake and goes on from that step of its schedule rather than starting a fresh one. A tab that failed on an answer is not woken: a new network does not change what the host said.

**A tap waits for an earlier login no longer than for a dial of its own.** A dial that gives up partway through logging in leaves that login to finish in the background, up to two minutes, because sshd counts a client that leaves mid-login as a failed login against the phone, and no other dial goes to that host as that user until it has. A tap that lands in that window waits for it as long as a dial is given, in all, and dials the moment it lifts. A login still unanswered by then fails the tap the way a dial that ran out of time does: `rose unreachable`, its detail ending `an earlier dial is still settling`, and the tab goes on as any tab whose machine did not answer. A resume, a network arriving and the reconnect schedule wait the whole window: nobody is watching them, and a second dial to a host that is only slow would stall the same way.

Nothing dials while the user is looking at `AUTHORIZATION REQUIRED` or at an unknown host key. Answering what the host asked is the user's turn, and a reconnect underneath it would take the shell the question belongs to out from under the answer. The hold is a count, taken when a sheet goes up and released when it comes down however it comes down, so two sheets at once still leave one hold standing.

The readout reads `WAITING`, where `RECONNECTING 4/6` read, with `STOP` under it. There is no spinner: the app is not working, it is waiting, and a spinner would say the opposite of both.

### A shell tab owns a remote identity, not an SSH socket

Transport continuity and process continuity are separate layers. Mosh does not depend on tmux or herdr. Striked uses real Mosh over UDP when the host provides `mosh-server`; tmux and herdr only determine which remote process a later transport reaches.

**The engine is the preferred transport, Mosh the next, SSH the fallback.** A host whose engine carries `shell/1` gets the engine's own shell server, a complete alternative to both: the pty's bytes reach the phone in order over encrypted UDP, so whatever the program printed — a kitty image, an OSC 52 copy, a notification — arrives as it would over SSH, while the link roams and survives a pocket the way Mosh's does. The server keeps the screen in a terminal of its own, so a phone that fell too far behind, or a process Android killed, is handed that terminal's snapshot and the images on it and goes on from there rather than from a blank screen. A host with no engine, or one that refuses the service, goes on to Mosh exactly as below. The tab writes `ENGINE` in its header after that channel has produced output. SSH authenticates the pinned host and starts `mosh-server`; terminal traffic then moves to the Mosh UDP channel. The tab writes `MOSH` in its header only after that channel has produced terminal output. Resume or a network change rehomes the existing Mosh channel instead of opening another login. The SSH control connection under that channel — the one the pin check, the working-directory lookup and the repository ask on — is kept on a plain return and dropped on a network change, since its socket is bound to the network that went; a kept connection that turns out dead is dropped and redialled by the next command that finds it so. A missing server, failed bootstrap, blocked UDP range, or first-output timeout cleans up the attempted server and continues over the already-authenticated SSH connection. An SSH tab retains the existing reconnect ladder, and a Mosh tab reaches the same one once its channel has stopped answering.

**Anything the server signed is contact, and a channel that has stopped sending it is given up on.** A packet that carries no new screen still proves the machine is there, so a shell that prints nothing for an hour is a shell that is fine. Silence is what the tab measures: it pokes a quiet channel with the size it already has, and a poke that goes unanswered reads `RECONNECTING`, three of them `DISCONNECTED`, with the channel left open under both because Mosh can come back on the session it already holds. Thirty seconds of unbroken silence ends that. The channel is dropped and the tab enters the same six waits an SSH tab gets, so the dial that lands comes back on Mosh, or on SSH where the host has nothing to start, and the tab has a `STOP` again rather than a word that nothing will ever change. What is counted is answers missed and never seconds passed: a process Android froze in a pocket thaws with every poke it owed due at once, and that is one gap in the link rather than one miss for each, so a phone coming back in front rehomes the channel it had — which clears the count — instead of throwing it away.

Every tab gets a validated random id. The id marks its `mosh-server`, so a process restore can remove only that tab's abandoned server before starting another. A live Mosh channel is not serialized: after Android kills Striked, the app establishes a new Mosh transport and then restores the remote process through the separate identity layer. Striked does not yet claim speculative local echo prediction; authoritative terminal state comes from the Mosh server.

**An ordinary tab is the host's ordinary login path.** Striked does not insert a multiplexer. The random tab id marks only its Mosh server; it is never handed to `tmux`, used for cwd lookup, or treated as remote process identity. A new tab and an app-restored tab both enter through the same login shell, so the host's own gateway or chooser remains authoritative. A transport reconnect or process restore opens a fresh shell and writes `-- reconnected --`; Striked makes no process-continuity claim for an ordinary tab.

**A herdr tab records herdr's identity and does not nest another multiplexer.** Its row stores the herdr session and pane id as a pair. A new Mosh or SSH transport reconstructs `herdr agent attach` from that validated pair, so the same agent pane returns. herdr remains the owner of the pane and its process. Closing the phone tab detaches and cleans up that tab's Mosh server; it does not kill the agent.

**A tmux tab records its server as well as its session.** tmux keeps one server per socket, and an ssh login and a desktop launcher on the same host can disagree about where that socket lives, one setting `TMUX_TMPDIR` and the other not, so one user can hold two servers that do not see each other. The picker lists the sessions of the server the login shell reaches, then those behind the `default` socket under `/tmp` or the runtime directory whenever that socket is a different file, with the socket's directory after the window count. Picking one of those stores the socket path beside the session name, and every attach and restore passes it to tmux, making the socket's directory first when a reboot has emptied it, so the tab reaches the server it was picked from. `NEW SESSION` always starts on the login's own server. A socket named with `-L` is not looked for: a server kept apart by name was kept apart on purpose.

**A multiplexer the host does not have is drawn and cannot be picked.** Its section keeps one row, the tool's own name in muted ink over `not on this host`, and a tap on it does nothing; `START` and `NEW SESSION` are offered only where the binary is. Whether it is there is asked of the host by name and read off what the host prints, never off an exit status: Tailscale SSH on a Mac reports every command as having succeeded, and a missing binary read that way is a herdr that is merely stopped.

**Close is remote cleanup with a durable retry.** Closing a tab first hides and retires its row, then kills only the `mosh-server` carrying its exact marker. It never addresses a tmux server or session. A failed or interrupted cleanup leaves a tombstone that no restore can draw. The next successful connection to that host retries those exact markers and deletes each row only after cleanup succeeds. A dial that lands after its tab was closed follows the same path before closing its transport.

The shell tab table carries nullable `remote_session`, `herdr_session`, `herdr_pane`, and `retired_at`. Every new tab has a `remote_session` used only as its Mosh cleanup marker. A herdr tab adds a complete session/pane pair; partial pairs are refused. A row written by an older build has no identity. The v14-to-v15 migration leaves every new column null; it never invents one. New rows are written before their first network dial, so Android cannot leave a marked Mosh server whose identity never reached storage.

### A shell out of sight goes quiet

Ten seconds after the app leaves the screen every live Mosh tab closes its UDP socket, stops poking the channel for health, and stops sending. The server keeps the session and the process under it, and nothing reaches the phone, so a pocket costs neither radio nor screen updates nobody will see. The tab's screen is saved before it goes quiet. A tab stops asking its host for passphrase requests too, and a quiet Mosh tab dials no control path to its host until it is back; the watcher is what hears those while the app is away.

**Back on screen, each quiet tab rehomes on a fresh socket.** The server answers with the whole difference from the last state the phone acknowledged, so the screen is current from the first packet, and the health pokes start again. The wake stands in for the rehome a return would otherwise make, so the channel moves once. A dial that lands while the app is away goes quiet as soon as its tab is marked and the stale ones are reaped, and asks for passphrase requests only on the return.

**An SSH tab keeps its channel.** TCP cannot be put down and picked up again, and a shell that could not be resumed is never traded for a quieter pocket; what it costs out of sight is its keepalive, and the watcher's service, which runs while any tab holds a plain SSH shell whether or not `[ ALERTS ]` is on. Android freezes an app that has left the screen, and from Android 16 cuts its sockets about five seconds after it goes, unless a foreground service is running; the one rule covers every Android the app installs on, because the freeze is older than the cut. With nothing to watch the service's line is `HOLDING 1 SSH TAB`; with agents to watch it stays the tally.

**A tab holds the service from the dial that lands it on SSH until it exits, fails, lands on another transport or is closed.** A tab between dials still wants its shell back, and the redial that brings it back has to reach the network. The service is started while the app is on screen, because Android refuses one started from behind another app; a start refused that way is made again when the app comes back. The notification permission is not asked for: without it Android still runs the service and only leaves the line out of the shade. Once a minute the service asks the app whether the tabs are still there, and a second ask nobody answers lets them go, so a process whose screen was swiped away does not hold a line for shells that went with it.

### The shell header carries no state, and the tab's readout is a double tap away

The header row never carries a word about the link. `CONNECTING`, `RECONNECTING`, `DISCONNECTED`, `EXITED`, `MOSH`, the failure kind and a `STOP` beside them are not on it. The row is the host, the tabs, the diff and files marks, the machine mark and the close.

**A double tap on a tab opens its readout, whatever the tab is doing.** The first tap switches to the tab on the spot and does not wait to see whether a second follows; a second tap on the same tab inside the platform's double-tap window opens the readout over it. The readout is there for a live tab as much as for one that is down, so the user reads the state off the session rather than off a mark that comes and goes. The house panel sheet, titled `<HOST NAME> <n>`. `STATE` reads `LIVE`, `CONNECTING`, `RECONNECTING`, `RECONNECTING <n>/<m>` while a schedule is running, `DISCONNECTED` while a channel is missing its answers, `WAITING` once the schedule is spent, `FAILED` once nothing will dial it, or `EXITED <code>`, in warning unless the shell is live. `TRANSPORT` is `SSH`, `MOSH` or `ENGINE`, and `—` once there is no connection left to ask. Under the rows a tab that is down takes the reason row the header uses, so why it is down is read where its state is.

**`RECONNECT` stands under a rule while the tab is down or its host is stale**, whatever the failure was. On a tab that is down it dials the shell again at once, as the first step of a fresh schedule, whether a schedule was still running, spent, or stopped. A tab still holding a connection whose terminal has not ended is waited on, not offered it. `STOP` follows while the session is dropped or waiting: giving up on a reconnect is the one decision the readout adds. The sheet reads the session and not the tap that opened it, so a tab that comes back under it loses both rather than leaving controls that would answer nothing.

**The machine is its own sheet, apart from the shell.** A `MACHINE` mark in its own 44 cell between the files mark and `×` opens it, titled with the host's name, for the host of the tab on screen: `ADDRESS`, then `LINK`, which a tap probes again, then on a host the phone runs that host's `LINUX` row the host panel carries, without the system and Nix rows. Whether a shell is up and whether the machine under it is up are two questions, and neither sheet answers the other's. `RUNNING` takes `RESTART` beside `STOP`; `STOPPED` reads in warning with `START`. A start or a restart is the user asking for the machine back, so every tab on that host that is down dials again on that same tap once sshd answers. **The mark goes to warning while that host's system is stopped**, and when the host did not answer, the reason row under the header and in the readout reads `linux stopped · start it from machine` in place of `<name> unreachable`, so a tab that is down because its machine is off says so without the user leaving the shell.

The reason row under the header is untouched. A failure is still one short row in warning with the host's name in it, because why a shell is not there is worth a row and what a live shell is talking over is not.

### A live tab whose host is not held says why in its readout

A tab on Mosh or on the engine keeps drawing after the connection that reads the directory, the agent and the passphrase has gone, so the terminal is live and those three are not. The readout carries one more row under `TRANSPORT`: `DIRECTORY, AGENT, PASSPHRASE`, in warning, reading `STALE · HOST RECONNECTING` while that connection is being dialled again and `STALE · RECONNECT FAILED` once nothing is dialling it.

**A failed reconnect keeps the words it failed with.** Under the rows the readout takes the reason row the header uses: the line from the one vocabulary, a tap to open the transport's sentence, the cell beside it to copy it. A host whose key changed reads as a key that changed and not as a link that went away. The row is there only while the readout says `RECONNECT FAILED`, and it goes with the stale row the moment the connection is back.

**The row never says reconnecting while nothing dials.** The redials stop on their own when a failure is not the host's to fix, or when their waits run out, and any reconnect that ends in a throw, one the app has no reason for included, reads `RECONNECT FAILED` with that throw as its detail.

**A key that will not be accepted fails again and says so again**; the user is not told which failures are worth a tap.

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

The tile and the host's `DESKTOP` row in the screens list are the two ways to a host's screen. The agents panel and the agents route are about agents and nothing else.

### The screen route is the picture and a rail

Breadcrumb `/ <HOST> SCREEN`, alone while the session is live: there is no `LIVE` word, because a live picture says so. `CONNECTING` and the reason lines stand on its right when they have something to say, each with a `RETRY` text action; there is no reconnect loop here. Below it, black ground and the framebuffer scaled to fit the width. No nav bar and no capture bar, and it is the only route that allows landscape.

The reason lines are `unreachable`, `unresolved`, `key rejected`, `tunnel refused` when the channel open was denied, `auth unsupported` when the server offers nothing the client can do, and `stream closed`.

**Gestures.** A tap moves the pointer there and left-clicks. A long press right-clicks; a long press then a drag holds button 1 while moving. A pinch zooms about its own centre, and a two-finger drag pans the zoomed view — at fit, where there is nothing to pan, it sends wheel events instead, one button 4/5 press and release per 40px.

**The rail** is a vertical panel on the left edge of the picture, vertically centred, over it: three 44px toggles stacked, one for the soft keyboard, one for the key strip and one that arms crop mode, ink `--fg-dim` and accent while the thing it toggles is up. The keyboard toggle is a panel of key rules over a spacebar and the strip toggle is a single keycap carrying a caret: stacked one above the other, two drawings of a keyboard differing only in how many rules they hold are one drawing to the reader. The keyboard and the strip are independent — strip without keyboard, keyboard without strip, both, neither — and closing the keyboard by the system gesture or the IME's own hide leaves the strip where it was. It keeps the same edge in landscape.

**The rail hides on a drag to the left over it.** It slides off the edge and leaves an 8×44 handle at its vertical centre, `--fg-dim` fill with a 1dp keyline so it separates from a light picture behind it. The hidden rail keeps the footprint the shown rail had as its hit region, transparent except for the handle: a drag to the right starting anywhere in it, or a tap on it, brings it back. That region reaches past the system's own back-gesture edge zone, which would otherwise swallow a drag starting on the handle itself. Pointer drags starting inside that patch belong to the rail and to nothing else on the picture. It is shown on every route entry, the hidden state lives with the route and is not persisted, and there is no timed auto-hide.

### The key strip is the shell's key bar, one row of 36

It is the shell's bar, cell for cell: one row of 36, cells sized to their label plus 10 px each side and never narrower than 36, the row scrolling when it is wider than the phone and fading at whichever end has cells behind it. `SUPER`, `CTRL`, `ALT`, `SHIFT`, then `ESC`, `TAB`, `←`, `↑`, `↓`, `→` and `END`. Nothing is pinned: the strip's own toggles are not repeated in it, the rail carries them. It sits above the keyboard when the keyboard is up and at the bottom edge when it is not.

**Two rows gave the picture away.** Six equal columns across a foldable's inner screen made cells far wider than their words, and the pair stood a hand's height over the framebuffer with the keyboard under it. One row is what the shell already spends, and it leaves the picture the rest.

The four modifiers arm the way the shell's do: a tap for one key, a downward drag for a count to three, a long press to latch, the label rolling to `CTRL(x2)` or `CTRL(∞)`. The arming belongs to the route, and every key spends it, the strip's and the IME's alike. `SUPER` is here where the shell's bar has none: a desktop takes a compositor chord, and the IME sends none. `SUPER` draws the ⌘-like house glyph with no word beside it; the four arrows draw their own glyphs; everything else is a mono 11 tracked word. A held arrow repeats the way the shell's does.

**Struck:** `HOME`, `PGUP` and `PGDN`. The user does not use them.

**Struck:** an `ENTER` cell and a `DONE` cell. The keyboard's own return key is Return, and the rail closes what the rail opened.

### Typing is keysyms, and the IME's return key is a real Return

Each typed character goes as an X keysym press and release — Latin-1 codepoints direct, everything else as `0x01000000 + codepoint`. The hidden field takes a multiline input type with a newline action, so the IME shows its ↵ rather than a checkmark that sends nothing, and a `\n` in the field is one press and release of `XK_Return`, never text. The field resets itself after each character.

### A rectangle cut out of the picture is saved to the gallery or held for a shell

Armed, the picture stops taking pointer events for the host and takes a drag instead, which draws a rect over it in the accent and dims what falls outside; the rail's other toggles and the key strip are inert while it is armed. Releasing leaves the rect on screen with `SAVE` and `HOLD` under its lower edge, both in the accent, and a fresh drag anywhere replaces it. There is no `CANCEL`: a fresh drag replaces the box and the rail toggle leaves the mode. Crop mode disarms on either verb and on leaving the route.

Both verbs map the rect's corners through the same transform the pointer uses, so the cut is in host pixels under fit and under zoom alike, clamp them to the framebuffer, refuse a rect under 8 px on either side, copy the pixels out and encode them as a PNG. **Nothing is downscaled** — a crop of a terminal is read by an agent, and deflate over flat glyphs is small already.

`SAVE` writes the PNG to the phone's gallery under an album `Striked`, through MediaStore; Android 10 and later need no permission for the app's own media, and the manifest carries the legacy write permission capped at the API before it, asked for on the first save. `HOLD` puts it in memory for the app run, where the shell's `ATTACH` sheet can reach it. **Never both**: a saved crop is not held and a held one is not saved.

**The word for what happened goes in the breadcrumb's state slot**, the one `CONNECTING` and a reason line use while not live: for two seconds after the verb it reads `SAVED · 240×120`, `HELD · 240×120`, or `SAVE FAILED · <reason>` / `HOLD FAILED · <reason>`, in the panel header style, then the breadcrumb stands alone again. Nothing is drawn over the picture for it.

### The protocol is RFB 3.8, and the pixels arrive in Flutter's own order

Versions 3.3 and 3.7 are accepted by their own rules. `ClientInit` is shared. `SetPixelFormat` asks for 32bpp, depth 24, little-endian, true colour, with red at shift 16, green at 8 and blue at 0 — which is Flutter's `bgra8888`, so a rect lands in the framebuffer with no swizzle. `SetEncodings` is ZRLE, CopyRect, Raw, DesktopSize, in that order of preference. One non-incremental update request first, incremental after, the next sent as soon as the previous update is painted, at most twenty-four a second.

ZRLE uses one zlib stream for the whole session, 64px tiles and every subencoding — raw, solid, packed palette of 2, 4 and 16 colours, plain RLE, palette RLE — with CPIXEL at 3 bytes as the spec reads it for this format. Bell, cut text and colour-map messages are read and dropped.

There is one framebuffer, a `Uint8List` sized by `ServerInit` or by a desktop resize, with rects blitted into it and **one image produced per update, never one per rect**.

**Struck:** taking a published RFB package. It handles Raw and CopyRect only, and it owns its own socket — which is the one thing this client cannot allow, because the socket here is a channel inside somebody's ssh connection.

## Devices

### A host's emulators and simulators are reached through the tools that already drive them

The integration is a `DEVICES` row in the host form's `[ INTEGRATIONS ]`. A device is an Android device or emulator the host's own `adb` lists as `device`, or an iOS simulator `xcrun simctl` lists as booted; the AVDs and simulators that are not running are the host's too, one tap from booting. Everything rides exec channels on one ssh connection per host, held for as long as the host is in the device list: no port, no VNC, nothing installed on the host.

**It is not the desktop cut down to a window.** A window cut out of the VNC picture shows whatever is on top of it, and two emulators on one host open at the same spot, so the picture would be the wrong device half the time and off the display's edge the rest.

### The way in is the screens tab, on the edge of every tab, and its twin in the header

**One launcher holds every screen the user owns: desktops and devices alike.** A host whose VNC integration is on brings its desktop, and a host whose devices integration is on brings its emulators and simulators. They are listed together, and a desktop and a device float at the same time.

**The edge tab is the way in, not a host's panel.** On the four tabs, a 28×56 tab rests against the side edge where the bubble last rested, at its height, low on the right until the bubble has been moved: black, bordered on the three sides off the edge, holding the screens glyph torn on the bubble's beat. The border and glyph are `--text-muted` while nothing is held, accent while a desktop or a device is, minimized or not. `SCREENS` in the HOME and MACHINES headers opens the same list, for whoever never looks at the edge. An 8 px bar was tried first: nobody found it. A tap on it, or a drag inward from it, drops the bubble with the list open. It shows only while some host has either integration on or something is held; it is gone while any other route or sheet is pushed over the tabs and while a screen is full screen, so it never sits over a form. The shell sheet is the exception, and only while nothing is open on it: what a shell is building is often on a device or the desktop, and a list a sheet away is one too many. The tab, the bubble and the close target rest above the keyboard, which the shell has up more often than not.

The bubble is a square holding the screens glyph, a monitor with a phone in front of it, glitched as it lands and torn again every 1.4 seconds while it sits with the app in front, so a parked device never reads as a dead icon; with the app away it lies still and wakes nothing. A tap on it opens the list; a device's picture appears only once the user taps its row, and the list folds back into the bubble as it does. A window that was open folds into the bubble. There is no list route: the bubble holds the list.

**The list is a panel, not a strip.** It opens from the bubble on its side, downward from the bubble in the top half of the screen and upward in the bottom half, at most as wide as a phone column and never taller than the room between the bubble and the screen's edge, scrolling inside itself when the hosts outgrow it. Its whole header is the drag handle, and a tap on it folds the list back into the bubble. It holds the screens glyph, glitched as the list opens, then `SCREENS`, then the minimize dash, which folds it as well. A tap anywhere off the list folds it too. Below it, every host with either integration on opens with a band on the secondary surface: its mark, its name, its address muted at the far end, a hairline above every band but the first. Under the band each integration gets a muted caption run out to a hairline, `DESKTOP` and then `DEVICES`, so a desktop never reads as one more emulator; the `+` that opens the device sheet ends the `DEVICES` caption, not the host's band. Under `DESKTOP` is one `REMOTE DESKTOP` row with the monitor glyph and `VNC` at its end; a tap floats the desktop window and dials it, and on a desktop already held it only brings the window back. Under `DEVICES`, one row per booted device under its full AVD name, model or simulator name, with the phone glyph and its kind at the end: `EMULATOR`, `SIMULATOR` or `PHYSICAL`, an emulator known by its AVD name or its `emulator-` serial, `BOOTING` while one comes up. The held row of either kind is in accent with an accent rule down its left edge, and its end word says what the hold is: `LIVE` while its window plays, `PAUSED` while it is paused, `HELD` while it is folded away. A row opens the window on that device; one device streams at a time, whichever host it is on. A host with none booted shows a dimmed `NONE` row, one still connecting `…`, and one whose connection failed has its label in warning and its reason line, in warning, under it. Opening the list dials every host with devices on that is not dialled yet, and only those; a tap on a label asks that host again. With no host carrying either integration the list says `NO HOST HAS VNC OR DEVICES ON`, dimmed. The footer is `END` at its far end.

**Struck:** the `DEVICES` row on the host's panel, and the `+ HOST` menu in the list's footer. A way in that started from one host put the user on the MACHINES tab to watch anything, and a second host was a second trip; the list now holds every host there is to hold.

### A host's devices are booted, made and removed from the list, never from its shell

**Each host's label row ends in `+`.** It opens a panel sheet for that host, headed `<HOST> DEVICES`: the AVDs `emulator -list-avds` names and the simulators `xcrun simctl` lists as shut down, a row each under the name the list would give it, with its runtime after the name wherever two on the host share it, here and in the list, and `NEW` at its foot. A row offers `BOOT` and `COLD BOOT`. `BOOT` starts it from its own quick-boot snapshot where it has one; `COLD BOOT` starts it from nothing; a simulator keeps no snapshot and both are `simctl boot`. An emulator starts headless and detached from the exec that started it: the picture is `screencap`, never a window, so a host with no display boots it the same. The sheet closes and the device sits in the list under its name with `…` until it has finished booting, then it is a row like any other. A boot that fails, or has not finished in three minutes, keeps its row with the reason under it in warning. A host whose login finds neither `emulator` nor `xcrun` says so in the sheet instead of listing.

**`NEW` makes one from what the host already has.** For Android: a name, a device profile `avdmanager` knows and a system image already installed in the SDK. For iOS: a name, a device type and an installed runtime. Nothing is downloaded: a host with no image says so and leaves fetching one to its own SDK manager. The new device lands in the sheet, shut down.

**A long press on a device's row offers `SHUT DOWN` and `DELETE`.** `SHUT DOWN` stops the emulator or the simulator; a physical device has neither, and its long press offers nothing. `DELETE` removes the AVD or the simulator from the host for good, behind the inline confirm, `DELETE` becoming `CONFIRM DELETE` for three seconds, and shuts it down first if it is running. In the `+` sheet a long press on a row offers `DELETE` alone. **`END` never shuts a device down**: it ends the stream, and a device the app booted keeps running until the user says otherwise.

### A device's screen is frames, sent only when they change

The window's expand glyph pushes `/ <HOST> <DEVICE>`: black ground, the frame fitted whole inside it, never cropped or panned. One exec per stream runs a loop on the host: capture a PNG — `adb exec-out screencap -p` or `simctl io screenshot` — and **send it only when its checksum differs from the last one sent**, re-encoded where the host has `sips` as a JPEG at quality 60, 1200 px on its long edge, and as the PNG itself where it does not. It waits a fifth of a second between captures, so a screen that animates costs a few frames a second at about fifty kilobytes each, and one that is still costs a two-byte keepalive every two seconds. The keepalive is also how the loop learns the stream is gone: its next write fails and it exits and removes its own temporary directory.

Each frame carries the device's own pixel size ahead of the bytes, so a touch lands in device pixels whatever the frame was scaled to. A capture that fails ends the loop with its message, and the crumb reads `stream closed` with `RETRY`.

### An Android device is pressed, and a simulator is only watched

On Android a tap is `input tap`, a long press is a swipe that does not move for 600 ms, and a drag is `input swipe` from where it started to where it ended, over the time it took, clamped between 100 ms and 2 s. Under the picture, `BACK`, `HOME` and `RECENTS` send their key events. Every input is its own exec on the held connection.

`simctl` has no verb that touches a simulator, so a simulator's route takes no input at all and its crumb says `VIEW ONLY` on the right.

**Not built:** typing. A field on the device is typed into from the host's shell, and the keyboard strip of the screen route is not repeated here.

### A desktop and a device float over the app, and a stream only runs while it is being looked at

**The device window floats over every route.** It is the agents window's idea kept inside the app: a device is watched beside the app's own work, and the `PIP` glyph on its overlay takes it beside another app's. The window is the picture and nothing else, a hairline around it, as tall as the device's shape makes it; until the first frame lands it says `CONNECTING`, or the reason line from the shell's vocabulary. The bubble stays on screen beside the windows, so the list is one tap away while a picture plays. Each rests against a side edge clear of the nav bar and the parked shell, at the height it was thrown to; a drag carries it anywhere and the release projects the finger's speed an eighth of a second ahead, gliding it to the side and height the throw points at, so a flick crosses the screen. One let go past an edge folds into the bubble on that edge, whatever the flick said. Two fingers pinch it between a hundred points wide and three fifths of the screen, its side edge held, and it keeps that width for as long as the app runs.

**The window's controls are an overlay the user calls up.** A tap on the picture lays the scrim over it with the expand glyph at the top left, which opens the device's route on the same stream, the minimize dash at the top right with `PIP` beside it where the phone has picture-in-picture, `PAUSE` or `RESUME` in the middle, and `END` alone at the foot, a word and not a glyph, as far from the dash as the window allows. Every control is a full 44-point target and speaks its name to a screen reader: `FULL SCREEN`, `PIP`, `MINIMIZE`, `END`, and `SCREENS` for the bubble. A window too short for three rows of them, or too narrow for its top row, scales the whole column down rather than overlapping it. A tap anywhere on the overlay that is not one of them puts it away; nothing puts it away on a timer. Paused with the overlay down, the frame is dimmed under a small pause mark, so a frozen picture never reads as a live one. A stream that fails over a frame keeps it under the failed glyph in warning at its corner, its reason spoken. Leaving the device's route with the phone's back or the crumb brings the window back on the same stream.

**The desktop window is the same window over the host's screen.** It starts three fifths of the screen wide at the top, opposite the bubble, in the framebuffer's aspect, 16:10 until the first frame says otherwise, and pinches up to the screen's width less its edges. Its overlay carries the same glyphs; its middle is `PAUSE`, `RESUME` in accent, `RETRY` over a failure, or `…` while dialling. It shows the picture and takes no input: the expand glyph opens `/ <HOST> SCREEN` on the same connection, the rail and the key strip with it, and leaving that route floats the window back without dialling again. A desktop paused, minimized, or out of sight stops asking the server for updates; the connection stays.

**Minimizing is not closing.** The minimize dash, or a window dragged more than half past a side edge, folds it into the bubble, its row still in accent in the list. Nothing is seen there, so the stream pauses there the way it does with the app in the background. A tap on that row in the list opens the window again where it was and resumes it, unless the user had paused it first; any other row moves the stream there.

**Closing is said on purpose, and a window closes only itself.** `END` at a window's overlay foot, or the window dropped on the close target that rises at the bottom of the screen while it is dragged, ends that window's stream and leaves the bubble and the other window. `END` in the list's footer, or the bubble or the list's handle dropped on the target, ends everything, empties the list and lets every host's connection go.

**The bubble tucks into the edge.** Dropped more than half past a side edge, the bubble leaves for the handle, folding every window and keeping every stream held and paused, so the handle stays in accent. A tap on the handle brings the bubble back with the list open, a held row in accent, one tap from its window.

**The loop runs only while someone can see it.** `PAUSE` on the crumb or the window's controls cancels the exec, so the host stops capturing, not only stops sending; the last frame stays, dimmed, under `RESUME`, and the route takes no input. The app going to the background, or into the agents window or the other screen's, pauses it the same way and brings it back on return, unless the user had paused it first. Back from the background, a window or list whose connection died dials once again by itself; a second failure shows its reason, and `RETRY`, or for the list a tap on the host's label, dials anew. A tab that moves the stream to another device ends the one before it.

**`PIP` parks one screen outside the app.** The system gives picture-in-picture to one activity, so the window shows whichever surface asked last: the agents panel from AGENTS, or a device or the desktop from its overlay. It is that stream and nothing else, edge to edge in the stream's own aspect, held inside the system's 2.39:1 either way, with nothing on it to tap. The stream it carries keeps playing while the app is out of sight, a paused desktop resumed for it; every other window pauses as it would in the background. Coming back to the app puts the window back where it floated; dismissing the corner window pauses the stream like any trip to the background.

## Code

### A registered directory is a primitive of its own, beside the projects

A checkout is not a property of a machine the way an address and a port are: it outlives which machine holds it, and it is what the user actually works in. So there are two primitives with two homes. PROJECTS is the board and nothing else. CODE is every registered directory across every host, and it lives on MACHINES because a registered directory is a host thing the app owns and not a Projects thing. **They are siblings, not a hierarchy**: a workspace with no project is ordinary and a project with no workspace is ordinary.

**Struck:** a fifth destination in the nav. Four labels is what fits inside the content cap with the parked shell bar over it, and a switch that lives on the screen it switches costs no chrome at all.

**A workspace row is `<owner>/<repo>`** in `rowTitle` — the last two segments of the directory, which is what tells two checkouts of the same name apart — with the host name at the right edge in `rowKicker` `textMuted`. Under it, when the host has answered, the branch and the dirty count in the mono `rowSubtitle`: `main  +142 −38  4 files`, or `main` alone when clean. A host that has not answered yet draws the row without the line rather than a spinner per row. Grouping is by host and ordering is by name, one panel per host with its count on the strip, and a host with no registered directory draws no panel.

**Registration is a pick, never a typed path.** `ADD` asks which host first — a panel sheet of the registered hosts, skipped when there is only one — and then opens the picker, which asks the host for its own checkouts: one command walks the roots for git checkouts and returns them as a list, filtered by a field that matches anywhere in the path. `.git` is matched by name and not by type, so a superproject's submodules are in the list and so is a linked worktree, whose `.git` is a file. The sheet checks rows off and closes on `ADD n`, because a host is registered once and has thirty checkouts on it, not one; a path already registered is kept out of the list. A long press on a row offers `RE-POINT`, the same sheet in single mode, and `REMOVE`. A row in the picker is one line, the last two segments and nothing else — no label line, no directory line, no agent mark: a path answers for a directory.

**Discovery needs sshd and nothing else.** The picker and the CODE list are drawn for any host the app can dial. A multiplexer on the far side still gates SEND, the agent marks and the AGENTS panel, because starting a pane needs a running session; a host with sshd and nothing else gets the whole of the explorer and the diff and no SEND row.

**A workspace links to at most one project**, and a project holds any number of workspaces. The link is set from either end — the workspace's own `PROJECT` row, the project detail's `CODE` section — and cleared the same way. Deleting a project clears the column rather than removing the row. What the link buys is the send: choosing a target on an item whose project has exactly one workspace opens on that workspace preselected, and with more than one its host's rows come first. The kind and the model are still asked, because those belong to the send and not to the directory.

### Everything on the workspace is read back, not stored

State that can be asked for again is not state worth a table. The registered directory and its project link are the whole of what the database holds about a checkout; the branch, the upstream, the dirty count, the listing, the file, the hunks and the worktrees are asked of the host and kept for the life of the sheet.

**One warm connection, one composed command per action.** Commands run on channels of the host's one shared connection, so when the agent list, the devices or anything else already holds it the workspace pays a channel and no dial; when nothing does, the sheet opens it and holds it for the sheet's life. The budget is round trips: the branch, the upstream, the ahead-behind and the change list are **one** command composed on the host, the way discovery is one pipeline and not three hundred stats. A screen that asks twice for one glance is the bug, not the milliseconds. One listing is one command — the whole directory with its types, sizes and times, never a stat per row — sorted directories first, dotfiles shown and the checkout's own `.git` hidden.

The header reads the machine-readable status rather than the human output, so a host in another locale answers the same, and a detached head reads as the short sha. The same command counts every changed file's `+n −n`: an untracked file is counted by its lines, an empty one `+0`, the first two hundred of them, and one past that, one that is binary or a link says `NEW` where a tracked binary says `BINARY`. An untracked directory is its files, a row each, and a name outside ASCII is the name, not git's escape of it. A rename is one row, `RENAMED`, at its new path with the old one under it, and never a modified path with the braces git writes it in; it is the pair status makes, so a moved file edited past recognition is still one row, its count and its lines the new file against the old, unless the old path has a change of its own again. A copy is an added file, and the file it was copied from keeps its own row. A file with no count heads its pane with none. A directory that is not a checkout says so in one line and keeps its shell.

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

Code is coloured by `packages/striked_highlight`, a pure-Dart copy of the highlight.js engine vendored whole, with the plugin hooks, the language detection and the renderers cut out and thirty-two grammars kept: dart, javascript, typescript, go, rust, python, c, cpp, java, kotlin, scala, bash, shell, yaml, ini, json, sql, nix, lua, markdown, dockerfile, makefile, css, scss, xml, protobuf, graphql, properties, diff, http, nginx and plaintext. The language is the extension's or, for `Dockerfile`, `Makefile` and `nginx.conf`, the name's; a file the app has no grammar for is drawn plain, and nothing is ever guessed from the content. C#, Swift and Objective-C ship no grammar and draw plain.

Six colours and the muted text: keyword, type, string, number, comment, annotation, with punctuation in the muted text and everything the grammar cannot place in the line's own colour. A grammar that gives up part way through a file gives the whole file back plain rather than a coloured head over an uncoloured tail.

The diff colours a line on its own and never across two, since the line above a hunk line may not be the line above it in the file; the one guess made is that a line whose first mark is `*`, or that closes a block comment it did not open, is a comment whole. The explorer colours the file whole, so a block comment or a string that runs over a line break is coloured to where it ends. Above sixteen kilobytes the colouring runs on another isolate and the file draws plain until it lands; below, it draws coloured at once.

### The explorer is a sidebar beside an editor, not a list that turns into a file

The explorer is laid out the way an IDE is: a sidebar on the left holding the tree, an editor on the right holding the open files under a row of tabs. Nothing swaps a list for a file and back: the file stays open in its tab while the tree is looked at, and the tree keeps its shape while the file is read.

Unfolded, both are on screen at once, the sidebar holding the share of the width it was left at and the editor the rest. Folded, the editor is the screen and the sidebar is a drawer over it from the left: `FILES` at the head of the tab row opens it, and picking a file, tapping the ground beside it, `BACK` or the system back closes it again. The drawer is open when the explorer comes up with nothing to read, so on a phone the first thing seen is still the tree, and the last tab closing opens it again. A fold or an unfold mid-session changes the widths and nothing else: the tabs, the drawer and the tree's open directories are the same widgets at every width.

The tree expands in place. The root is open when the screen opens; a tap on a directory opens it and draws its entries under it, one step further in per level, and a second tap closes it. A listing is one command, asked the first time its directory is opened and kept for the screen's life. The `[ TREE ]  [ CHANGED ]` switch, the letters, the counts and the rows for deleted files are as ruled under the checkout's marks.

Every file opened is a tab and stays one until it is closed. A tab carries the file's name, the checkout's letter in its colour when it has one, and `×`; the tab on screen is in the accent with the underline the shell's tabs carry, the rest in the muted text. A tap on a file already open goes to its tab rather than reading it again, and a tab holds its text, colours and marks for the screen's life, so switching costs the host nothing. Closing the tab on screen moves to the one beside it. The tab row scrolls sideways once it is fuller than the screen, and the tab on screen is scrolled into view. Under the tabs the editor is a panel titled by the open file's path, with the changed file's strip and the file under it; with no tab open it says `OPEN A FILE`.

Over both is the sheet's own toolbar, and the explorer draws no header of its own: what says which checkout this is belongs to the sheet that holds it, not to the tree inside. The system back closes the drawer when it is open over a file, and leaves the sheet otherwise.

### The explorer marks each file row with a Nerd Font glyph

Every directory and every file in the tree carries a glyph before its name, from the Symbols Nerd Font Mono the app already carries for a shell prompt rather than the Striked vector set. This is the one place the house vectors are stood down, and it is stood down for now and not for good: `languageOf` alone names close to thirty grammars, and the set is borrowed until the vectors catch up with it.

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

**The viewer is a sheet.** The app's modal shape — a panel parked at the bottom of the screen over a dimmed terminal, and unfolded as wide as the screen rather than the content column, since a diff is the one sheet whose lines are wider than any column — and not a screen of its own: what is behind it is the context the diff is being read against, and a diff read on a phone is read once and dismissed. It carries no `BACK` and no `REFRESH`. Out is the scrim or the phone's own back, which steps out of a file the user picked before it steps out of the sheet, and what is on it was read when it opened. The workspace's change list opens the same sheet at the file that was tapped. There is no second diff surface in the app.

**It is on the screen before the answer is.** The tap opens the sheet, not the round trip that fills it. The mark was lit by a checkout the app had already asked for, so there is nothing left to find out before the sheet can come up; what it does not have yet it says it does not have, `loading` where the subject goes and on the strip of every list, and it fills in underneath as the host answers. A modal that waits on a phone's radio before it draws is a tap that did nothing, and the user taps again.

**Both lists open folded.** `CHANGES` and `COMMITS` are a header strip each when the sheet comes up, each carrying its own count, and the sheet is only as tall as what is unfolded. A diff on a phone is read one file at a time, and two lists of rows over it are the wall between the user and the thing they opened. Unfolding one leaves the other where it is, and picking a file folds both again: which of the three is worth the screen is the user's to say, and the sheet says nothing about it until they have.

**Two panes.** A list beside the hunks, two fifths and the rest: folded with nothing picked the list is the screen, folded with a file picked the hunks are, unfolded both are drawn. A source of one changed file opens on that file, and unfolded a source opens on its first file, so the pane beside the list is never an empty offer to pick one; folded with several, the list is still what comes up. Back from a file the sheet opened by itself leaves the sheet, since the user never went there; back from one they picked steps out to the list. One tree at every width, so unfolding the phone never throws away the commit the user had walked to.

**The list is `COMMITS` over `CHANGES`.** The commits are `git log` — the short sha, the subject, the author and how long ago — and the working tree sits above them as a row of its own, which is the row the viewer opens on. Tapping a commit points the whole screen at it: the `CHANGES` panel becomes that commit's files and the hunks become that commit's hunks. The working-tree row carries the dirty count, a commit row carries nothing, and whichever is the source is drawn in `accent`.

**The head line.** Over both panes: the subject of the commit on screen, or `WORKING TREE` when that is the source, then the branch, the short sha and `+n −n` across every file of the source. It is the line the eye lands on and it says what is being read.

**The hunks are coloured by syntax, under the diff's own two colours.** The ground and the glyph still say which side of a change a line is on; the syntax colours the text inside it and never the ground. The language comes from the file's extension and from nothing else, and a line is read on its own: a hunk is not a file, the lines above a line may not be the lines above it in the file, and a highlighter that carries a guess across a hunk boundary is a highlighter that lies. What it cannot place it leaves the colour the line already had, which is the colour the whole line used to be.

**History is read, in one round trip each.** `git log` for the list, `git show --numstat` and `--name-status` composed into one command for a commit's files, `git show` for every file's hunks at once and `git show -- <path>` for a file that answer was cut before reaching — all `--no-color`, all under the same `sh -c` budget the workspace already keeps, all on the connection the screen already holds. Nothing here writes, and nothing here checks anything out: reading a commit does not move `HEAD`, and the verbs still live in the shell.

Struck: a file tree in the viewer, and a way to open a commit's file at its full text. The explorer is one row away on the workspace screen and it already does both.

### The whole diff comes back at once, and the walk under it spends nothing

The viewer asked the host for one file's hunks every time a row was tapped. A commit of twenty files was twenty commands, which on a radio is twenty handshakes' worth of latency paid one at a time by the user walking the list — and the workspace was built on the opposite rule from its first command: what a machine on the other side of a phone's radio charges for is the round trip and not the bytes, so one user action is one command and a screen wanting three answers asks for them together. The viewer was the one surface that had not been written that way, and no amount of work on how the lines are drawn would have fixed a screen whose problem was that it was waiting.

So the hunks of everything that changed come back with the list. `git diff --no-color HEAD` for the working tree and `git show --first-parent --format=` for a commit: one command for the whole source, split by file on the way in and held for as long as that source is the source. A tap after that asks the host nothing and the file goes up in the frame the row was tapped in, which is the speed a list has to answer at to be walked at all.

**The cap is on the answer, not on the file.** Half a megabyte, taken with `head`, which counts bytes and will cut a line in half. What the cap was is carried back to the reader, so it knows the last file of a full answer is however much of one there was room for, and it drops that file rather than drawing a fraction of it as though it were the whole. A file the answer did not reach is then asked for by name on the command the viewer has always had — and so is an untracked file, which `diff` never names and which is read against nothing.

**The walk is under the lines.** `PREV` and `NEXT` step through the change list in the order it is drawn, `HUNK` goes to the next hunk header and wraps at the end of the file, and beside them the count says which of how many files is open. They sit below the hunks and not on the strip above them, because a file is read to its end and the way out of it has to still be under the thumb when it gets there. They are the foot of the file's own panel, ruled off from the lines, and never a row floating over whatever is under the sheet. A step with nowhere to go is drawn dimmed rather than dropped: a row of verbs that changes width as it is used has to be read again every time it is used.

**A file that is all new or all gone is the file, not a diff of it.** An untracked or added file is drawn as its lines, and a deleted one as the lines it had: no hunk header, no `+` or `−` on every row, no ground, one column of numbers, and `NEW FILE` or `DELETED` at the head of the panel in the accent or the warning. A file whose answer carries both sides is drawn as a diff.

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

The nav has four labels and gains no fifth for settings. The door is a `SYS` breadcrumb action on Home, in the same slot and style as a project's `EDIT`, pushing a `SETTINGS` route with no nav bar under the crumb `STRIKED / SYS`. Its blocks, top to bottom, are `[ STATIC ]`, `[ ALERTS ]`, `[ VOICE ]`, `[ KEY BAR ]`, `[ BUNDLE ]`, `[ THEME ]` and `[ BUILD ]`. Hosts and keys are not among them: they have a tab of their own, and the rule that a host needs a key lives in the host form.

**`[ STATIC ]`** is `ON` / `OFF` as a two-row picker with the block on the active one, persisted in a `settings` key-value table. OFF draws the noise tile once, unmoving, which is the same path the thermal throttle takes.

**`[ ALERTS ]`** is a row per alert kind, `BLOCKED AGENTS` then `FINISHED AGENTS`, each with a toggle of its own. Turning one on asks the OS for notification permission; refused, that toggle stays off and the subtitle reads `NOTIFICATIONS DENIED` — the permission is the app's, so the refusal is drawn on the row that asked. With no host on the agent integration both rows are dim, subtitle `NO HOST`, and the toggles do nothing. The settings survive a launch. These rows are the whole of what lets the app hold a connection open while it is not in front — with both off, the app opens nothing in the background, ever.

**`[ VOICE ]`** is a row per model, `WHISPER BASE` and `WHISPER SMALL`, each with a toggle of its own that is off on a fresh install. Each subtitle says what turning it on costs: `161 MB DOWNLOAD · STAYS ON THE PHONE` and `375 MB DOWNLOAD · SHARPER, SLOWER`. On fetches that model, int8, from a pinned revision of sherpa-onnx's model repository: three files, each checked against its sha256 before it is kept. While it fetches, the toggle stands on and the subtitle reads `DOWNLOADING 42%`. The fetch belongs to the app, not the screen, so leaving SYS does not stop it. Done, the row reads `IN USE · 161 MB` for the model that hears, and `INSTALLED · 161 MB` for base while small is on the phone too: small hears whenever it is there, so base can be kept or deleted beside it. A fetch that fails leaves nothing behind, turns the toggle off, and reads `DOWNLOAD FAILED`, or `MODEL CORRUPT` when a digest differs, until the next try. Off cancels a fetch under way and deletes that model; with both off, VOICE goes back to the phone's recognizer. **The toggle is the files**: no settings row says Whisper is on, so a model that is not on disk is a toggle that reads off. Under the rows, `LANGUAGE` offers `AUTO`, `ES`, `EN`, `PT`, `FR`, `DE` and `IT`, `AUTO` on a fresh install; the choice survives a launch, applies from the next recording, and is drawn whether or not a model is on the phone, because it is Whisper's alone and says so: `WHISPER ONLY · THE PHONE'S RECOGNIZER FOLLOWS ITS OWN`. The recognition engine ships in the app, because Android will not load native code the app downloaded. Only the model is a download.

**`[ BUILD ]`** is the last line, mono 11 `--fg-dim`: `v<version> (<versionCode>) <short sha>`, the sha injected at build time and reading `dev` when it is absent.

### `[ KEY BAR ]` arranges the shell's bar on the bar itself

The block draws the shell's own bar from the stored layout, at the width the panel gives it, scrolling and fading the way it does over a shell. A `TRY` / `ARRANGE` switch heads it.

**`TRY` is the bar working.** Modifiers arm, count and latch, the stick pushes and repeats, and the line above the bar shows the bytes each key would have sent — `1b 5b 43` — the last four of them, in the accent. Nothing reaches a host. `ATTACH` and `VOICE` say their name on that line instead of acting.

**`ARRANGE` is the same bar held still.** A hold on a cell lifts it in an accent frame; a drop on another cell lands on whichever half it was let go over, and an accent caret says which before the lift. Each side of the rule ends in a slot of its own, so a cell can go after the last one or onto a side left empty, and that is how a cell is pinned or unpinned. A drag held near either end of the scrolling side scrolls it. Under the bar, `HIDDEN` takes a dropped cell off the bar and holds it; a tap on one there, or a drag back onto the bar, puts it back. `KEYBOARD` moves but never hides: it is the only way to the IME from a shell, and the tray refuses it with `THE KEYBOARD STAYS ON THE BAR`. `SEND` is not arranged: it appears at the head of the pinned side when there is something to send.

**`ARROWS` picks the form.** Two tiles, `STICK` and `CELLS`, each drawing the arrows as they would sit on the bar, the chosen one framed in the accent. The arrows keep their place on the bar whichever form they take.

**The default is no row.** Every change is written at once and every open shell redraws its bar on the next frame. `BACK TO DEFAULT` deletes the row rather than writing the default down, so a layout never changed follows the app's own when that moves; with nothing changed it reads `DEFAULT · IN USE` and does nothing. A row that does not parse is the default, a name the app no longer knows is dropped, and a row without `KEYBOARD` gets it back at the end of the pinned side.

**The screen's key strip is not arranged here.** It is a different bar with different keys, and its arrows stay cells.

### A bundle carries the phone to another phone

There is no backend of the app's own anywhere in this, so the transport is a file the user holds and the file is the whole of it: a second phone, or the same phone after a reset, comes up on the same hosts with the same keys. Every key row travels and, with it, the private key out of the keystore — the one thing that never leaves the phone, and the one thing without which the other phone cannot dial. Every host travels with all its columns: the pinned host key, so the second phone trusts what the first already verified instead of meeting the machine cold, and the VNC password, which is a host secret like the private key is. Every integration switch travels, and every registered directory with its label.

### A passphrase seals it, and the envelope says what it is

Private keys travel in the file, so the file is ciphertext. The passphrase goes through Argon2id — 64 MiB, three passes, one lane, a 16-byte random salt — to a 32-byte key, and the JSON payload goes under NaCl's secretbox, XSalsa20-Poly1305 with a 24-byte random nonce, under that key. **The envelope is JSON, so a curious `cat` says what it is**: a marker, a version, the KDF's name and parameters, salt, nonce and box in base64. On the way in the envelope's own parameters drive the derivation, so a later default does not orphan an older file; a memory parameter above 256 MiB is refused rather than obeyed.

A wrong passphrase is exactly what a tampered box is — the tag fails — and it is named `WRONG PASSPHRASE`, on the assumption that the user typed rather than that somebody edited. A file without the marker is `NOT A BUNDLE`; a version the app does not know is `NEWER BUNDLE`. The derivation runs off the UI isolate and the bar reads `SEALING` or `OPENING` for the second or two it takes.

**Nothing of the app's decides where the file lives.** `EXPORT` raises the system's create-document picker with a name of `striked-<date>.bundle` and `IMPORT` its open-document picker, the bytes going through the device channel. A picker dismissed is nothing happening, and there is no line for it. A platform without a picker — the desktop dev loop, the test harness — says `NO PICKER` and stops.

### The panel is on SYS, and an import says what it holds before it lands

`[ BUNDLE ]` sits between the alerts and the build stamp, because a phone's whole set leaving or arriving is a system act and not a row beside the hosts. It carries two text actions. `EXPORT` asks the passphrase twice on a sheet titled `EXPORT BUNDLE`, two obscured fields under `[ PASSPHRASE ]` and `[ AGAIN ]`, the bar naming what is missing the way the host form does — `PASSPHRASE MISSING`, `PASSPHRASES DIFFER` — and reading `SEAL` when nothing is. `IMPORT` opens the picker first, asks the passphrase once on `IMPORT BUNDLE`, and **only after the box opens** raises a confirm that counts what is in it — `2 HOSTS · 1 KEY · 5 PATHS` — with `IMPORT` filled in the accent, so the user sees what they are about to take before anything is written. The panel keeps the last outcome as a row: `EXPORTED 2 HOSTS · 1 KEY · 5 PATHS`, `IMPORTED …`, or the failure word in the danger colour.

### Import merges by id and deletes nothing

A row the phone already has under the same id is replaced by the bundle's; one it does not have is added; one the phone has and the bundle does not is left alone. A host's integrations become the bundle's set for that host. **A host whose key is neither in the bundle nor on the phone could never dial**, so the whole import is refused as `BUNDLE INCOMPLETE` rather than landing half. Private keys are written to the keystore first and then the rows in one transaction: a private key with no row is inert, while a row with no private key is a host that cannot dial. Running the same file in twice is the same phone as running it once.

### The bundle carries the whole phone

An application id is what Android calls an app, so a rename is a second app: its own sandbox, its own database file and none of the rows. The old app cannot be read from outside either — a release build carries no debuggable flag, so `run-as` is refused, and the platform's own backup has been inert for four major versions. The only door out of an app nobody can open is the door the app itself offers, and that door is the bundle.

**So the bundle is not a curated set, it is the phone.** Hosts, keys and paths are not the line: the rest is a user's work, and a bundle that leaves it behind is a bundle that loses it the first time an app is reinstalled under another name. Every table travels: projects, goals, tasks, links, attachments, notes, activity, settings, dispatches and shell tabs beside the four curated ones. A path carries its project id, because the project it points at is in the file with it and a link that would otherwise be dangling by definition is a link that resolves. The one thing left behind is the Linux the phone runs for itself, and the host that reaches it, since the system's files are not in the file.

**The ten new tables travel as rows, not as domain objects.** The curated four are mapped by hand because they are assembled out of the keystore and three repositories and cannot be read off a table. The rest are read column for column and written back the same way, under the names sqlite knows them by. A migration that curates is a migration that loses: a repository would apply its own rules on the way in — the one `isNext` item, the reasons a delete is refused — and the phone that arrives would differ from the phone that left in ways nobody asked for. The dump is the whole row and the restore replaces by primary key, so running the same file in twice is still the same phone as running it once.

**An image attachment is a file, and the file goes too.** A row of kind `image` holds a path relative to the app support directory, which is inside the sandbox the new app does not have. The bytes ride in the bundle under that same relative path and are written back before the rows, so an attachment is never a row pointing at nothing. An image already on the phone is left as it is: the bytes are content, and the same relative path is the same picture.

**The envelope answers to both names.** A file sealed by the app under an older name opens under this one: the marker key is read as either `spectacle` or `striked` and written as `striked`. This is the whole point — the file a user has to import was written by the app they are leaving. A bundle that only the new app could have written would not have reached them.

**The panel counts what is in the file.** `2 HOSTS · 1 KEY · 5 PATHS` grows a tail for everything else — `· 312 ROWS`, and `· 4 IMAGES` when any ride along — on the outcome row and in the confirm before an import, so the user sees the size of what they are about to take.

## Theme

### One token read path carries every colour and text role

`StrikedTokens` is a theme extension holding every colour the app draws with — the palette, the syntax palette, the terminal palette, and the washes, grounds and scrims a screen used to reach for as a literal — and every text role. A component reaches it through its `BuildContext`, never through a constant directly. Geometry — spacing, radii, icon sizes, tap targets, bar sizes — is not a token: it does not move with the theme and stays the plain constants it always was.

`StrikedTokens.house` is the default, built from the same values the app has always shipped, so registering it changes nothing on screen. A different `StrikedTokens` instance is what makes a theme; nothing else does.

### No colour or text style lives outside the design layer

A feature reaches `context.tokens` for every colour and text role it draws with; it never reaches for the palette or text-role constants directly, and never writes a colour as a literal. A painter or a route with no `BuildContext` of its own takes the colour resolved by the widget that owns it, carried in as a plain field. Where nothing is meant to be painted, the app says so directly — a null colour, a `BorderSide.none` — rather than reaching for a transparent one.

### `[ THEME ]` lets the phone's own colour scheme replace the house palette

SETTINGS carries a `[ THEME ]` row with two states, HOUSE and SYSTEM. HOUSE is the default and is the fixed palette every other ruling in this document assumes. SYSTEM resolves a `StrikedTokens` instance from the platform's own colour scheme: Material You's tonal palette where the device offers one, a scheme seeded from the house accent and the platform's own light or dark brightness otherwise. Choosing SYSTEM never touches the syntax palette, the terminal's ANSI table or the diff grounds — those read code and diffs, not chrome, and stay the house's regardless of the row. Nor does it touch the device float: its black ground and everything drawn on it, the close target included, keep the house's ink, since a ground that is black in every theme cannot take a light theme's dark ink.

The running app rebuilds its theme the moment the row is written, on the same screen and on every other, the way `[ STATIC ]` already does. The status and navigation bar icon brightness follows the resolved theme's own brightness rather than a value fixed at house-dark.

## Plugins

### Plugins run on the phone through declared capabilities

Plugins contain Luau source and a `striked.plugin.toml` at the repository root. Striked bundles the compiler and interpreter. Scripts run in a worker isolate, in separate Lua states, and receive only the APIs their manifest declares and the user grants. Native libraries, arbitrary filesystem access, network access and shell execution are not script globals.

The API exposes named manual actions and dataset handles. A selected record is an invocation-scoped dataset binding, not a feature-specific runtime API. Reading it returns its key, text value and revision. Updating it produces a proposal shown with `APPLY` and `DISCARD`; the originating feature adapter checks that the record has not changed before applying it. The plugin engine does not name individual built-in features.

SYS has a `PLUGINS` panel containing the real built-in Drops and Projects plugins. They are bundled but disabled on a fresh installation. An existing installation adopts both as enabled once, preserving the features already in use; subsequent user choices survive upgrades and restarts. No example installer or demonstration action is exposed in the product. `ADD` accepts a public GitHub repository and a ref: a full commit SHA, a tag or a branch name. Striked fetches the root manifest and its declared files at that revision, then displays the release, manifest schema, required API version, dependencies and each requested capability before `INSTALL`. A revision's files and manifest are retained together with their digest and grants. Updating requires reviewing the new revision. Removing a repository plugin removes its registration; it leaves existing records and prior plugin files intact. Built-in plugins can be disabled, not removed from the application bundle.

### Plugins are switched on a board

The plugin screen opens on a board, not a list. A strip under the title switches between `BOARD`, `BROWSE` and `SOURCES` in place; none of the three is a sheet.

The board is the dependency graph drawn as a skill tree, top down. A readout heads it, `<n> ON · <n> OFF`, adding `· <n> BLOCKED` when any is, over `<installed>/32 SLOTS`, with `ADD` beside it opening the review sheet; pending host pauses and their retry sit above the readout. Under it, `UP` is a square accent block at the top centre, standing on a hard lip. A plugin with no dependency sits on the first tier, wired to the core; one with dependencies sits a tier below the first one it declares, wired to it, so Projects sits under Drops. Leaves take columns left to right and a parent centres over its children; when the columns do not fit the width the tree scrolls sideways rather than shrinking its nodes. A declared dependency that is not installed is a hollow node with a `+`, named by its id, reading `MISSING`; a tap on it opens `BROWSE`.

Each plugin is a node: a square block with a near-black outline standing on a hard lip, a solid offset edge with no blur, holding the plugin's emblem; a row of pips under it, one per page, widget and action it contributes, then its name in capitals and its state. The emblem is a monoline glyph drawn on the same grid, stroke and mitred corners as the app's own icons, painted in one colour, from a fixed set of twelve — crate, banner, gear, eye, key, dish, flask, compass, hammer, bolt, cubes, tower. A manifest may name one with `emblem`, and a catalog index entry may name the same so `BROWSE` shows it before install; an undeclared or unknown name gets one picked from the plugin's id, the same on every device, and is never an error. Each `BROWSE` row leads with the plugin's node, lit while the installed plugin is on, and the installed manifest's emblem wins over the index's. Drops carries the crate and Projects the banner. On, the block's face is the accent with the emblem in the ground colour, the way a filled action reads, and the state reads `ON`; off, the face is grey with the emblem muted and the state reads `OFF`; a plugin that cannot run — an incompatible revision, or a dependency missing or at a version it does not accept — sits on a darker face with its emblem dimmed, wears the blocked glyph on a danger square at its lower corner, and reads `LOCKED`. A press sinks the block onto its lip until the finger lifts. The pips are accent while the plugin is on. A wire is a pipe, a thick near-black casing with a core inside, running from under a node's state down and across to the top of each dependent; one whose two ends are both on has an accent core with lighter current running toward the dependent, and every other pipe has a border-colour core. With reduced motion the lit wire is solid and nothing runs. A node that turns on or off plays the glitch flipbook.

A tap on a node selects it: a ring frames the node, and the node card under the tree shows it, the first plugin on the tree until another is tapped. The card carries the name, its version, its purpose, the same promise line the empty Home derives from its contributions, `DROPS CARD · CAPTURE BAR`, a blocked plugin's reason in the danger colour, then `POWER UP` on an off plugin or `POWER DOWN` on an on one, and `DETAILS`, which opens the plugin sheet. The card leads with the node itself beside the name. The card and its buttons are blocks on hard lips like the nodes: `POWER UP` and `ADD` have accent faces with ground-colour text, `POWER DOWN` and `DETAILS` grey ones, and a press sinks a button onto its lip. The card's frame is accent while the plugin is on. A switch that would carry other plugins says so before it does anything: the card names them, `ALSO TURNS ON DROPS`, and with Drops off the first `POWER UP` on Projects arms the button in the warning colour as `TAP AGAIN · SWITCH 2`; every node the switch carries, and the wires between them, take the warning colour and read `GOES ON` or `GOES OFF`, and a warning rule under the buttons drains over three seconds. A second tap within those three seconds turns on Drops and then Projects; with Projects on, the same on Drops turns off Projects and then Drops. With reduced motion the rule stays full until the arm lapses. A blocked plugin's button does nothing, and selecting it glitches its node. A switch the resolver still refuses reports its reason in the card in the danger colour.

The plugin sheet opens like an item card. Its head is the plugin's node at full size beside its version, its state — `ON` in the accent, `OFF · LAYOUT AND DATA KEPT` muted, `LOCKED · <reason>` in the danger colour, or `READY TO INSTALL` in review — and its purpose. Under it four stat tiles, blocks on hard lips like the nodes, count what it brings, `PAGES`, `WIDGETS`, `ACTIONS` and `CAPABILITIES`; a tile with a count takes an accent frame, lip and number while the plugin is on, and a zero is dim. `[ REQUIRES ]` shows each declared dependency as a small node with its name and state, `ON`, `OFF`, `MISSING`, or `NEEDS <range>` when the installed version is out of range, or `NOTHING · RUNS ON ITS OWN`; `[ UNLOCKS ]` shows the installed plugins that depend on this one the same way, and is absent when none do.

The sheet's `ENABLE` and `DISABLE` switch the same way the card does, never by a rule of their own. When the switch carries other plugins, a line under it names them, `ALSO TURNS OFF PROJECTS` or `ALSO TURNS ON DROPS`; the first tap arms it in the warning colour as `TAP AGAIN · SWITCH <n>` for the same three seconds, and the second runs the switches in the board's order. The sheet never refuses a switch the board would carry.

Struck: currency, experience and progress meters. The board takes a skill tree's shape because plugins really depend on one another; it does not take the tree's reward loop.

### A plugin's sheet says what it adds

Under the switch, the sheet's `ADDS` section has one bordered block per contribution, every block open, with no expanders. A widget's block heads with where it is now, `DROPS · HOME CARD · AUTO WIDTH`, then its controls as segment rows whose lit segment is the current choice: `PLACE` offers the places the widget declares, `CARD` and `BAR`, then `OFF`; a place it does not declare is a line of text, `INPUT BAR · NOT OFFERED BY DROPS`, not a dead control. A home card adds `ON HOME`, `SHOWN` or `HIDDEN`, and its position, `CARD 1 OF 2 ON HOME`, with `MOVE UP` and `MOVE DOWN` where they apply. `SIZE` shows only when the widget declares more than one size, and `WIDTH` — `AUTO`, `NARROW`, `WIDE` — only when its size is not a fixed width. A page's block offers `OPENS FROM`, `TAB` or `TOOLS`. An action's block names it, `<TITLE> · ACTION`, and says it runs from a drop and that the user approves what it changes, or that it appears on drops once the plugin is on. A plugin with none of these reads `NOTHING TO PLACE · IT WORKS IN THE BACKGROUND`. A tap saves at once; taking the input bar from another widget still asks first.

### Installing is a trust decision the review says out loud

The review sheet opens, above the source revision, with a block bordered in the warning colour headed `INSTALLING IS A TRUST DECISION`. It names the repository the code comes from, says the code reaches only the capabilities listed below it, and says its limits are cooperative, not an operating-system boundary. Reviewing an update marks each capability the installed revision did not hold `NEW ·` in the warning colour, in the review itself rather than only under the diagnostics.

### Actions run on a drop and change nothing until applied

An unfiled drop's sheet has an `ACTIONS` field when any enabled plugin declares an action: one key per action, a line naming the plugins they come from, ending `NOTHING CHANGES UNTIL YOU APPLY`. The key that is running reads `RUNNING` in accent and the others wait. A proposal is shown as the change it is: `WAS` over the current title struck through, `BECOMES` in accent over the proposed one, then `APPLY` and `DISCARD`. An action with nothing to propose reads `NOTHING TO CHANGE`; a failure reads in the danger colour. Script timings and call counts are not shown here; they stay under the plugin's technical diagnostics.

### A plugin package can span several files

A repository plugin's manifest can declare extra Luau files alongside its entry, each a relative path inside the repository. A path outside the package, an absolute path, a duplicate or a path shadowing the entry is rejected before any network call, and the declared count and total size are bounded. Striked fetches every declared file at the pinned revision alongside the manifest and the entry, and retains them all together under the revision; the retained digest covers the manifest and every file, not the entry alone. The entry can `require` a declared file by its path without the `.luau` suffix. A required module resolves only inside the retained package: no filesystem access and no network access from `require`, and resolution rejects an undeclared path, a require cycle and runaway nesting depth. The multi-file format carries everything the UI-capable format does: a page or widget contribution and host capabilities declare the same way, alongside the extra files.

### A ref resolves to the commit it pins

The `ADD` and `UPDATE` ref field takes a full commit SHA, a tag or a branch name. Striked resolves a tag or branch name to its commit SHA through the public GitHub REST API before fetching anything, unauthenticated; a full SHA needs no resolution. The manifest and every declared file are then fetched and retained by that resolved SHA, never by the ref that named it, so a moving branch or a retagged release cannot change what an installed revision contains. `UPDATE` additionally offers the repository's latest revision with one tap: the tag of its latest published release, or its default branch when it has no releases. The offered revision is fetched and reviewed exactly like a manually entered one before `INSTALL` replaces the running revision.

### A manifest can list itself for the person installing it

A manifest can declare an author, a homepage, a license and a short summary, each optional and bounded. Striked shows every declared one in the review sheet before `INSTALL` and in the installed plugin's detail view; an undeclared one is omitted rather than shown empty. None of the four carries runtime meaning: they do not affect a plugin's capabilities, dependencies, compatibility or execution, and a manifest lacking all four remains as valid as one declaring all of them.

### A marketplace index lists installable plugins

An index is a `striked.index.toml` at the root of a public GitHub repository, fetched at a ref exactly like a plugin: a full commit SHA, a tag or a branch name, resolved through the same unauthenticated GitHub REST API before the index file itself is downloaded and size-bounded. The index root carries its own format version, separate from a manifest's; an index declaring anything but the version Striked understands rejects with a version mismatch instead of an unknown-field error. Its `[[plugins]]` entries each declare an id, a repository, a ref, and the same optional author and summary a manifest can declare; an unknown field or a duplicate id rejects the whole index. An entry is a pointer, not a package: none of its fields is trusted beyond shape until the plugin it names is itself fetched and reviewed through the existing install flow.

The plugin screen's `SOURCES` tab adds and removes an index by repository and ref; Striked ships no default source. Its `BROWSE` tab lists every entry across every added source, naming a source that failed to load separately from the entries that did; with no entries and no failures it offers `ADD SOURCE`, which switches to `SOURCES`. Selecting an entry opens the same review sheet `ADD` uses, with its repository and ref already filled in; an entry whose id matches an installed plugin opens that plugin's installed detail instead, offering `UPDATE`.

### A debug build can point plugin and index fetches at a local origin

A build define replaces the GitHub raw-content base for both plugin and index fetches with an arbitrary HTTP origin, letting an author serve a package from a local directory while developing it instead of publishing to GitHub first. The override reads only in a debug build; a release or profile build ignores it and always fetches from GitHub. Under the override a ref is used exactly as given, with no GitHub ref-to-commit resolution, since a local origin has no such API to resolve against; the served layout mirrors GitHub raw content's own, owner then repository then ref then path. `UPDATE`'s `USE LATEST` also has no such API to resolve a release or default branch against, so it refuses under the override instead of reaching GitHub.

### Manifests and dependencies have separate versions

`manifest_version` is the manifest format's integer version. `version` is the plugin's semantic release version. `striked_api` is its required API version range. Striked rejects unsupported manifest versions, unknown fields, unsupported capabilities and incompatible API ranges before running code. Retained incompatible revisions stay listed, disabled, with their original source and grants; they cannot execute until a compatible update is reviewed. The manifest's release version cannot change the meaning of its format.

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

Striked caps source size, VM allocation, result size, pending requests and resident VMs. Execution checks a deadline and a safe-point count inside the interpreter; a Dart timeout alone is insufficient. These are cooperative execution limits, not a separate OS process or a hard real-time guarantee. Compilation runs off the UI isolate with bounded source input, but compiler allocations are outside the VM heap budget. Failed invocations discard their VM. Scripts cannot retain live Dart objects, authenticated connections or database handles. The runtime reports cold-load time, execution time and VM memory for profiling.

The dataset session's time budget starts at its first API call, not during compiler or FFI setup. It continues between calls and cannot be reset by catching an error. Call-count and elapsed-time failures are reported separately.

Plugin pages use versioned native UI constructors and a lower-level node and drawing interface. Luau owns page structure, transient state and event handlers. Striked validates bounded descriptions, preserves keyed native controls and renders scrolling and animation without invoking Lua per frame. Plugins can compose layouts rather than selecting a fixed screen template. Host operations are asynchronous effects behind declared, versioned capabilities; scripts receive neither SSH credentials nor arbitrary shell access.

### Plugin colour and layout follow the phone's active theme

A plugin's semantic colours — `accent`, `muted`, `background`, `surface`, `border`, `danger` — resolve against the same `StrikedTokens` a native screen reads, not a fixed palette, so a plugin page matches whatever look the phone is showing rather than the house look alone. A manifest opting into the newer UI API receives a `theme` table on its `mount` event, naming that same instance's brightness and colours as hex strings, for a script that wants to draw canvas content in step with it. A manifest that keeps the original UI API sees no `theme` table and no behaviour change.

The newer UI API adds house layout to the raw node vocabulary: a bordered panel with a header strip, a lighter grouping with no border, a three-column list row, a bordered status pill, and a bracketed label-and-value readout. Striked renders each with the same native widget a built-in screen uses, so a plugin page composes from the app's own look rather than approximating it node by node. Older manifests keep the constructors they already had; nothing already shipped is renamed or removed.

### Agent schedules are managed from a Luau plugin

Agent schedules is a standalone Luau package shipped with the app. It owns its interface and private preferences. A selected host owns schedules, execution and retained run history. Scheduling does not depend on the phone remaining online. The host side is a service the engine exposes and nothing else; setup is explicit, checks what the engine on that machine carries, and touches only the engine's own state. Existing host jobs and other plugins' datasets are not modified. Unsupported hosts show the missing capability instead of a simulated schedule.

The plugin manages one-shot and daily runs with an explicit timezone, repository directory, installed agent, prompt and timeout. It can inspect, pause and resume schedules, start a run on demand and read bounded run output. Occurrence identities prevent duplicate launches when a timer or connection retries. Failed and interrupted executions remain visible. The host uses the agent's existing authentication and permission configuration.

Disabling the plugin preserves preferences, schedules and history. Host-owned future runs are paused through the host API. An unreachable host leaves a visible pending pause until the host acknowledges it; the app never claims offline cancellation has completed. Already-running agents are not silently killed.

Struck: a host adapter of this plugin's own, written in Python and installed as a systemd user timer on Linux. It is a second artifact on the machine in a second language, put there for one plugin, and what a plugin has on a host is settled below as the engine and nothing else. Schedules reach a machine the way everything else does, through a service the engine exposes, and a machine whose engine does not carry that service reports the capability missing rather than simulating a schedule — which is the answer this section already gives an unsupported host.

What a schedule fires on while the phone is away is settled already, under Routines: a timer on the machine, put there when the thing is armed and taken off when it is disarmed, because a clock on a sleeping phone cannot buy a reliability it does not have. Striking the adapter does not touch that ruling — it changes what puts the timer there. The engine exits when it has answered, so it is not the thing waiting for three in the morning; it is the thing that arms what does. A timer set through a service of a binary the machine's owner already declared is a call the engine answers, not a second artifact the app left behind, and it comes off the same way it went on.

### A plugin's host side is a program the user installs, and the app never puts it there

There is one host artifact and it is one binary, the engine. A plugin that has work on a machine calls the engine and calls nothing else: what it can reach over there is a service the engine exposes, never a line a shell reads, and the app grows no second thing to install.

**It is not a daemon.** Nothing is resident and nothing listens. A hook the engine is run as is held open by the agent that ran it, never by the engine: the one wait it takes is an approval's, bounded at a minute. A call is an exec over the ssh connection the app already holds: the engine starts, reads its request, writes its answer and exits. That costs a process per call, which is what the quoted script under `sh -c` it replaces already costs, and it is why the engine never stands in for anything herdr's socket already answers — what it answers about agents is what they say of themselves, which no socket carries. The agent panel keeps its held channels for events and its roster poll on a thirty-second clock, because no method lists sessions and a program on the host does not make one. A resident engine would be a second thing to keep alive on the machine, and the poll it could not remove would still be running beside it.

Narrowed for one service and no other. A shell tab on a machine whose engine carries `shell/1` is served by the engine itself: the call that starts it forks one server for that tab, which owns the tab's pty, listens on one UDP port for that tab's phone alone, and exits when the shell under it does or when the tab is closed. It exists so that a user does not need Mosh to have the better shell, and it carries what Mosh drops — an image a program draws, the clipboard, a notification — because it ships the pty's own bytes rather than a screen it redrew. It redraws only for a phone that cannot be caught up from bytes: one that asks for a keyframe or has fallen out of what the server still holds is handed a snapshot of the server's own terminal, the images placed on it, and the stream from there. Nothing about the rest of the engine changes: every other service still answers and exits, and no process listens for a tab that is not there. A server outlives its phone, which is the point of it, and does not outlive its tab: a server no phone reached in its first minute leaves, and one whose shell ended leaves once the phone has the exit, or ten minutes later if it never comes for it. The user still installs the binary; a machine without it, or with `shell/1` denied, gets Mosh or SSH exactly as before.

**`shell/1` has three ops.** `start` takes the tab's name, its size in cells and pixels, the command (the account's login shell when empty), `term`, extra environment, the scrollback in lines, a port range and `resume`. It answers the port, the key and the server's pid, and whether it `resumed`. A tab whose server is still running is resumed unless the call says `resume: false`: the server is handed a new key, forgets the old one and the phone it served, and goes on with the shell it has, so a phone that lost its process gets its session back without the old key ever being sent again. `stop` ends a tab's server and its shell and says whether there was one. `list` names the tabs whose servers are running. `teardown` stops every one. The ports are the host's to give: `shellPorts` in the host's config narrows the range a server may bind, 60001–60999 when nothing names one, and a call asking for ports outside it is refused.

**An image sent by name is read on the host.** A program may hand the terminal a kitty image as the name of a file, a temporary file or shared memory rather than as its bytes, and the phone cannot open anything on the host. The server can, so it does: it reads what the command names, as the account it runs as and by the rules kitty reads them by, and sends the command on carrying the bytes, to the phone and to its own terminal alike, so a keyframe redraws that image like any other. What it cannot read goes no further, and the server answers the program itself with the `EBADF` kitty answers, which is how a program such as ranger learns the terminal is elsewhere and sends the bytes itself. One larger than the server keeps an image is refused the same way with `EFBIG`, since a keyframe could not redraw it.

**The user installs it, and the phone finds it.** The engine is declared on the machine by its owner — a Nix module, `services.strikedddd`, being the shape the author of this document uses — and the app calls whatever is there. It never pushes a binary onto a host, never writes one over a shell, and never offers to. The one exception is the Linux the app runs on the phone itself, which is the app's own files and gets the app's own engine. On a machine with no engine declared, a plugin that wanted one is told the capability is missing, the same answer an unsupported host already gives a schedule. A key installed for this app buys a shell on that machine and does not buy the right to leave software on it, and that distance is the whole reason this is the owner's declaration and not a step inside the app.

**A thing that can be installed has to be able to leave.** `teardown` is a call of the engine's own, beside `probe` and `version`, and it takes off what the engine put on the machine and says what it took off. A page of removal instructions for the user to follow by hand is not that: asking to be installed and having no answer to being asked to leave is asking for more than was said at the time of asking.

**The ceiling is the host's.** A plugin declares the capabilities it wants in its manifest and the phone grants them, exactly as it does for everything a plugin touches on this side. The host denies from its own side: `denyCapabilities` names capabilities the engine refuses whatever a manifest asked and whatever a phone granted, and `denyExec` names what `run` will not start. What executes is the intersection of the two, and where they disagree the deny wins. The phone is one device holding a grant; the host is the machine the work actually lands on, and its owner is the one who lives with what ran there.

**Luau on both sides, and only Luau.** A plugin is Luau in the app and Luau on the host: one language, one value representation, and a value that crosses between them is the same value rather than a translation somebody has to keep honest. The manifest carries `[runtime] kind` even though `luau` is the only value it accepts today, because that field is the seam — the day a second runtime is real it arrives as a value in a field that already exists, and not as a change to the format every installed manifest is read by.

### The engine's services are typed, and versioned from the first call

The engine answers named services, each carrying its version in its own name: the lifecycle calls `probe`, `version` and `teardown`, then `fs/1`, `run/1`, `git/1`, `schedule/1`, `agents/1`, `shell/1`, `kv/1` and `batch/1`. The number is on them from the first day rather than added on the day it first hurts. What the engine exposes is a public ABI with a plugin somebody else wrote on the far side of it, and a surface that gets versioned later is a surface that has already broken somebody once. `probe` says which services an engine has and at which version, so the phone asks a machine what is there instead of assuming its own build.

**A call says which owner it is made for.** The engine acts as one account on that machine and the identity travels with the request, so an engine reached on a machine several people use is not a way into another account's files. The owner is that account and nothing else. A plugin that keeps state on a host has a namespace of its own and it travels in the call's arguments, never in the owner field: one of the two is checked against the account the engine is running as, the other is a name a plugin chose, and a surface that let the second be written where the first is read would be asking the engine to verify a value it was handed.

**`run/1` cuts the output on the machine that produced it.** head, tail, grep and a limit are arguments to the call and are applied on the host, so what crosses the tunnel is what the plugin asked for and not a log the phone carries in full to discard the bulk of. The file is already over there, and a phone on a mobile radio pays for every byte twice, once to receive it and once to hold it.

**What ships first is the binary, the framing, the owner, the lifecycle, `fs`, `run`, `schedule`, `agents` and `shell`.** `agents` is there because the agents' own word about themselves has to be written down on the machine while nobody is looking, which is the same reason `schedule` is. The first two are the ones the app already needs and today gets by quoting a script under `sh -c` with every value the user or the host supplied quoted into it. `schedule` is on that list because the section above leaves it nowhere else to be: a schedule has to fire while the phone is away, and the timer it arms and the agent it starts are work on a machine whose one host artifact is the engine. A scheduled run goes through the same supervisor `run` uses rather than a second one of its own, so a run started by a timer is watched, bounded and cancellable exactly like a run started by a person. The rest — `git/1`, `kv/1` and `batch/1` — are named here so the shape of the ABI is settled while it is cheap to settle, not because they exist: a service that is named and not built is absent from what `probe` answers, and a plugin asking for it is told so rather than finding out inside a call.

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
