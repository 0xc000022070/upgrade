# Gate

You wrote it, so read it as if somebody else had. Do all of this before anything is committed.

1. Read the new code end to end. Look hardest at the seams: constructors, repository interfaces, provider defaults that are right for a test and wrong for the app.
2. `grep -rn '§' lib test` — must be empty. `grep -c '§' docs/SPEC.md` — zero; the symbol is gone from the spec too.
3. If there are screenshots, montage them and actually look:
   `nix shell nixpkgs#imagemagick -c magick montage <files> -tile 5x2 -geometry 360x800+4+4 out.png`.
   Crops go in a second montage at `-geometry 700x+4+4`.
4. Stage the files by name. Never `git add -A`, `git add .` or `git add --all`.
5. Prove the staged set stands alone. `git status --porcelain -- lib test assets plugins packages tool pubspec.yaml` must list nothing unstaged or untracked, so the tree under test is the index. Then `just gen`, `just analyze` and `just test`, once, on that tree. `just test` hashes what its result depends on (lib, test, packages, assets, plugins, tool, pubspec, the Flutter and libghostty versions), records the hash when it passes, and answers a rerun on the same hash from that record. A change outside those inputs, docs or the spec, costs no run; a reviewer reads the printed `test: inputs <hash>` instead of rerunning. `UPGRADE_TEST_FORCE=1` reruns, and only a suspected environment fault justifies it.
   When `pubspec.yaml`, `pubspec.lock`, `packages/*/patches` or a native hook changes, the run is from scratch instead, since resolution itself is what changed:
   ```
   git checkout-index -a --prefix=<scratch>/idx/
   cd <scratch>/idx
   nix develop path:$PWD -c bash -c 'flutter pub get && flutter pub run build_runner build --delete-conflicting-outputs && just analyze && just test'
   ```
   `*.g.dart` is gitignored, so codegen is required there. `dart run build_runner` fails outside `flutter pub run` in this shell.
6. Commit, only when the user asked for one. Conventional, lowercase title, body describing concrete code changes. No section numbers.

The full `just test` is the validation; never a subset picked from the change. While fixing a red file, `just test <file>` is debugging, and the next full run is the evidence. A file that fails in the run and passes alone is a flake: name it in the report, do not rerun the suite for it. Real transport changes add `just test-host`, `engine/` adds `just engine-gate` (which also runs the live engine channel tests against the built `upgraded`), patches add `just pub-verify`.

Run it in the background. `just test` and `just analyze` share `.dart_tool/test.lock`, so a second one waits for the first instead of stalling both; it is still a wait, not a reason to start one.
