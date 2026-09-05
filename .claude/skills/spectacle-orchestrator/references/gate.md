# Gate

Do all of it yourself before anything is reported to the user.

1. Read the evidence README and the migration dumps in the builder's scratchpad `evidence/phaseN/`.
2. Montage the shots and look at them:
   `nix shell nixpkgs#imagemagick -c magick montage <files> -tile 5x2 -geometry 360x800+4+4 out.png`.
   Crops go in a second montage at `-geometry 700x+4+4`.
3. Read the new code. Check the seam between the two agents, not only each half: constructors one agent calls on the other's widgets, repository interfaces, provider defaults that are right for tests and wrong for the app.
4. Stage the checkpoint's files by name. Never `git add -A`. For a shared file that also holds the other agent's hunks, write a filtered patch and `git apply --cached` it. `pubspec.yaml` usually needs this: take the version hunk, leave the dependency hunks to their phase.
5. Prove the staged set stands alone:
   ```
   git checkout-index -a --prefix=<scratch>/idx/
   cd <scratch>/idx
   nix develop path:$PWD -c bash -c 'flutter pub get; flutter pub run build_runner build --delete-conflicting-outputs; flutter analyze; flutter test'
   ```
   `*.g.dart` is gitignored, so codegen is required there. `dart run build_runner` fails outside `flutter pub run` in this shell. A red test here usually means an unstaged file the report mentioned.
6. Commit. Conventional, lowercase, body describes concrete code changes. No trailers, no session links. Never fold codex's in-flight files into the builder's checkpoint.

The export run is the checkpoint's one analyze+test run.

## What to look for in phase 9 code

- The AGENTS feed never fetches without a host that has HERDR on. There is a test that counts fetches.
- A stream generator that `yield*`s an infinite poll never sees the next selection event. Selection belongs in `ref.watch`, so Riverpod cancels the old generator.
- Error and blocked states must be mirrored on every screen that reads the feed, not only the Home panel.
