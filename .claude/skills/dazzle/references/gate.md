# Gate

You wrote it, so read it as if somebody else had. Do all of this before anything is committed.

1. Read the new code end to end. Look hardest at the seams: constructors, repository interfaces, provider defaults that are right for a test and wrong for the app.
2. `grep -rn '§' lib test` — must be empty. `grep -c '§' design/SPEC.md` — zero; the symbol is gone from the spec too.
3. If there are screenshots, montage them and actually look:
   `nix shell nixpkgs#imagemagick -c magick montage <files> -tile 5x2 -geometry 360x800+4+4 out.png`.
   Crops go in a second montage at `-geometry 700x+4+4`.
4. Stage the files by name. Never `git add -A`, `git add .` or `git add --all`.
5. Prove the staged set stands alone:
   ```
   git checkout-index -a --prefix=<scratch>/idx/
   cd <scratch>/idx
   nix develop path:$PWD -c bash -c 'flutter pub get; flutter pub run build_runner build --delete-conflicting-outputs; flutter analyze; flutter test'
   ```
   `*.g.dart` is gitignored, so codegen is required there. `dart run build_runner` fails outside `flutter pub run` in this shell. A red test here usually means a file left unstaged.
6. Commit, only when the user asked for one. Conventional, lowercase title, body describing concrete code changes. No section numbers.

`flutter test` takes minutes. Run it in the background and never two at once — a second run, or an analyze beside it, and both stall.
