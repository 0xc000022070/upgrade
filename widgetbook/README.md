# Striked catalog

Striked's design system in [Widgetbook](https://docs.widgetbook.io): tokens,
components with their states, every bundled asset, and a few screens fed by
fixtures. The real widgets, themes and assets: this package depends on
`striked` by path and links `assets/` to the app's own directory.

## Run

From the repository root:

```sh
nix develop
just widgetbook          # http://127.0.0.1:8095, any browser
just widgetbook 9000     # another port
just widgetbook-build    # static site in widgetbook/build/web
just widgetbook-serve    # that site built and served on http://127.0.0.1:8096
just widgetbook-frames   # recapture the plugin frames
```

Without `just`:

```sh
nix develop
just pub-build           # prepares ../.dart_tool/{libghostty,dart_mosh,dartssh2}
cd widgetbook
flutter pub get
flutter run -d web-server --web-hostname 127.0.0.1 --web-port 8095
# or a browser flutter drives itself:
CHROME_EXECUTABLE=$(command -v chromium) flutter run -d chrome
```

`pub-build` has to run once before the first `pub get`: the overrides in
`pubspec.yaml` point at the patched packages it writes under the root
`.dart_tool/`, and it needs the dev shell for `LIBGHOSTTY_REV`.

`r` in the `flutter run` terminal hot reloads, `R` restarts. A new or changed file
under `assets/`, or an edit to the asset or font lists in `pubspec.yaml`, needs
a restart: the bundle is built once per run.

The toolbar on the right switches theme (HOUSE, SYSTEM · DARK,
SYSTEM · LIGHT), viewport (Pixel 7 `pixel_7-api36` first), text scale
(0.85 to 2) and an 8 px grid.

## Layout

| path                     | holds                                             |
|--------------------------|---------------------------------------------------|
| `lib/catalog.dart`       | the tree and the addons                           |
| `lib/notes.dart`         | the note strip over each use case                 |
| `lib/themes.dart`        | the theme addon's entries                         |
| `lib/frame.dart`         | `Stage`, `Specimen`, `SheetStage`                 |
| `lib/foundations/`       | colors, typography, spacing, radii, shadows       |
| `lib/components/`        | one file per category; `knobs.dart` is shared     |
| `lib/assets/gallery.dart`| the asset gallery                                 |
| `lib/screens/`           | screens and `fixtures.dart`                       |
| `lib/plugins/`           | plugin frames drawn by `PluginUi`                 |
| `frames/plugins/`        | captured plugin views and `index.json`            |

## Register

A component is a `WidgetbookComponent` in the list its category file exports
(`actionComponents` in `lib/components/actions.dart`, and so on). A new
category is one more file and one more `WidgetbookCategory` in
`lib/catalog.dart`.

```dart
WidgetbookComponent(
  name: 'ActionBlock',
  useCases: [
    WidgetbookUseCase(
      name: 'Playground',
      builder: (context) => Stage(
        children: [
          ActionBlock(
            label: context.label('Trust'),
            tone: context.tone(),
            filled: context.knobs.boolean(label: 'Filled'),
            onTap: context.tap(),
          ),
        ],
      ),
    ),
  ],
),
```

- Every component gets a line in `lib/notes.dart`, keyed by its path in
  the tree (`components/actions/actionblock`): what it is and where the app
  shows it. A use case can have one too; `Playground`, `States` and
  `Interactive` fall back to a shared line. `test/notes_test.dart` fails on a
  component without a note or a note without a node.
- One use case per thing to play with (`Playground`, all knobs) and one that
  lays every state side by side (`States`), each state a `Specimen`.
- `Stage` paints the theme's background and keeps the app's screen edge and
  column width; `Specimen(label, note:, child:)` titles a state.
- A sheet goes in `SheetStage(open: (context) => showSomething(context))`: it
  opens on its own navigator inside the selected viewport and offers to open
  again once dismissed.
- Shared knobs (`context.tone()`, `context.label()`, `context.tap()`) live in
  `lib/components/knobs.dart`.
- Screens take their data from `lib/screens/fixtures.dart`: fixed values and a
  fixed clock (`fixedNow`), fakes for the ports a screen reads (`DeviceLink`,
  `UsageFeed`), no network and no host. A provider a screen watches is
  overridden in a `ProviderScope` around it.

Assets register themselves. The gallery reads the bundle's `AssetManifest` and
`FontManifest.json`, so a file shows up once its directory is listed under
`flutter: assets:` here (in step with the app's pubspec) and the catalog is
restarted. The kind filter is by extension; files under `assets/sprites/` are
drawn as the mascot.

## Included

- Foundations: every token color with its hex value, in three groups; type
  roles and families; spacing, radii and borders, icon sizes, shadows, motion.
- Components: actions, rows, containers, inputs, feedback, graphics, with
  playgrounds and state boards (normal, selected, disabled, loading, error,
  where the widget has them).
- Assets: search by name or path, filter by kind (SVG, PNG, sprite, font,
  data), tile size knob, a detail panel with path, kind, font family and
  resolution variants.
- Screens: usage panel, host key sheet, hook sheet, device sheet (listed,
  none, no tools, unreachable, loading), link preview card, project icon
  picker, diff stat.
- Plugins: Board, Kanban (page and inbox card) and Agent tasks, each frame a
  view the bundled plugin's Luau returned, drawn by the app's `PluginUi`.

## Plugin frames

A browser cannot run Luau, so the views are captured on the host:
`tool/plugin_frames_test.dart` drives each bundled plugin through the
`LuauWorker` with the flows its tests use and writes every view to
`frames/plugins/`, with the parse flags (card, canvas, awake, pages) in
`index.json`. Rerun `just widgetbook-frames` after a plugin's UI changes; a new
frame is one more `_write` there and one more name in `_frames` in
`lib/plugins/plugins.dart`. Events go nowhere: a tap does not advance the
frame.

## Limitations

- Not in the catalog, because they load native code a browser cannot: the
  terminal and shell (flterm, libghostty), voice (sherpa), the plugin runtime
  and the screens around it (library, management, development, the home
  board), and the main tabs that build those. `DiffBody` is left out:
  it needs a parsed diff document and its jump index.
- `ActionBlock` and `SolidActionBar` draw no pressed state; `PanelAffordance`,
  `KeyCell` and `ToolbarIconAction` show it only while pressed. `ActionBlock`
  has no disabled look: a null `onTap` is all it is. `ListRow` has no state
  flags; its board styles rows the way the feature screens do.
- SYSTEM themes use the fallback scheme a device without Material You gets:
  a browser has no wallpaper to read.
- The device event channels (throttle, network) have an Android side only;
  `lib/platform_stubs.dart` answers them with no events, so `AsciiBackground`
  never sees a throttle.
- Link preview fixtures carry no image URL, so the thumbnail never loads.
- `flutter build web` warns that CupertinoIcons is missing; nothing here uses
  it.
- Two changes to the app made this possible, with no change to how it looks:
  `showSheetRoute` pushes on the nearest navigator instead of the root one
  (the app has one), and `panel_sheet.dart` imports the plugin scope through
  a stub on platforms without `dart:ffi`.
