import 'dart:convert';

import 'package:striked/platform/shell/remote_shell.dart';

/// `RS`, which git never writes: a marker made of ordinary characters would eventually
/// be a line of somebody's diff.
const workspaceRecord = '\u001e';

/// `US`, for the reason [workspaceRecord] is `RS`: a subject holds whatever a person
/// typed into it, tabs and pipes included.
const workspaceField = '\u001f';

const workspaceFrame = '\u0000\u001e';

const workspaceNoDirectory = 20;

const workspaceNoRepository = 21;

/// Every one of them is a single `sh -c`, because the cost of asking a machine on the
/// other side of a phone's radio is the round trip and not the bytes: a screen that
/// wants three answers asks for them at once and splits on [workspaceRecord]. Nothing
/// here writes.
abstract final class WorkspaceCommands {
  static String _enter(String directory) =>
      '${shellCd(directory)} 2>/dev/null || exit $workspaceNoDirectory\n'
      'top=\$(git rev-parse --show-toplevel 2>/dev/null) && cd "\$top" '
      '|| exit $workspaceNoRepository\n';

  /// The checkout a directory is inside: a shell three directories deep is still standing
  /// in the whole repository. A directory inside none exits non-zero.
  static String repository(String directory) => underSh(
    '${_enter(directory)}'
    'exec git rev-parse --show-toplevel\n',
  );

  static String overview(String directory) => underSh(
    '${_enter(directory)}'
    'git -c core.quotePath=false status --porcelain=v2 --branch '
    '--untracked-files=all\n'
    "printf '\\036\\n'\n"
    'git worktree list --porcelain\n'
    "printf '\\036\\n'\n"
    'git -c core.quotePath=false diff --numstat HEAD\n'
    'rc=\$?\n'
    "printf '\\036\\n'\n"
    '$_cap'
    '${_untracked('-c')}'
    "printf '\\036\\n'\n"
    '${_untracked('-L')}'
    'exit \$rc\n',
  );

  /// BSD `head` has no `-z`, so a Mac host caps with perl, and a host with neither is not
  /// capped at all.
  static const _cap =
      "if printf 'a\\0' | head -z -n 1 >/dev/null 2>&1; then "
      'cap() { head -z -n $untrackedCounted; }\n'
      'elif command -v perl >/dev/null 2>&1; then '
      "cap() { perl -0ne 'print if \$. <= $untrackedCounted'; }\n"
      'else cap() { cat; }\n'
      'fi\n';

  static String _untracked(String flag) =>
      'git -c core.quotePath=false ls-files -z --others --exclude-standard | '
      'cap | '
      'xargs -0 -r git --literal-pathspecs -c core.quotePath=false '
      "grep --no-index -I $flag '' -- "
      '2>/dev/null\n';

  static const untrackedCounted = 200;

  /// `head` cuts bytes and will cut a line in half; the reader is told what the cap was
  /// and drops the file it landed in rather than drawing half of one.
  static const diffBytes = 524288;

  /// The round trip is the cost, not the bytes: a commit of twenty files asked for one at
  /// a time is twenty handshakes' worth of latency on a radio.
  static String sourceDiff(String directory) => underSh(
    '${_enter(directory)}'
    'git --no-pager diff --no-color HEAD | head -c $diffBytes\n',
  );

  static String commitDiffAll(String directory, String sha) => underSh(
    '${_enter(directory)}'
    'git --no-pager show --no-color --first-parent --format= '
    '${shellQuote(sha)} | head -c $diffBytes\n',
  );

  /// `HEAD` and not the index, so a file staged and then edited again reads as the one
  /// change the user made rather than as two.
  static String fileDiff(String directory, String path) => underSh(
    '${_enter(directory)}'
    'git --no-pager diff --no-color HEAD -- ${shellQuote(path)} '
    '| head -c $diffBytes\n',
  );

  /// `--no-index` exits 1 when the two sides differ, which here is always, so the code is
  /// thrown away rather than read as a failure.
  static String newFileDiff(String directory, String path) => underSh(
    '${_enter(directory)}'
    'git --no-pager diff --no-color --no-index -- /dev/null '
    '${shellQuote(path)} | head -c $diffBytes\n'
    'exit 0\n',
  );

  static const textBytes = 524288;

  static const textBudget = 1048576;

  /// Linux refuses an argument past 128 KiB, and the texts command names every file in
  /// one: the files past this many bytes of it are left to their hunks.
  static const textsArgument = 98304;

  static List<(String, String?)> textsCarried(List<(String, String?)> files) {
    var spent = 0;
    for (var index = 0; index < files.length; index++) {
      final (path, origin) = files[index];
      spent += _argumentCost(path) + _argumentCost(origin ?? '') + 160;
      if (spent > textsArgument) return files.sublist(0, index);
    }
    return files;
  }

  static int _argumentCost(String path) {
    var cost = 0;
    for (final byte in utf8.encode(path)) {
      cost += byte == 0x27 ? 40 : (byte < 0x20 ? 10 : 4);
    }
    return cost;
  }

  static String texts(
    String directory,
    List<(String, String?)> files, {
    String? sha,
  }) {
    final request = jsonEncode({
      'commit': sha,
      'files': [
        for (final (path, origin) in files) {'path': path, 'origin': origin},
      ],
      'max_bytes': textBudget,
    });
    final sides = StringBuffer();
    for (var index = 0; index < files.length; index++) {
      final (path, origin) = files[index];
      final before = shellQuote(
        '${sha == null ? 'HEAD' : '$sha^'}:${origin ?? path}',
      );
      sides.write('blob o $index $before\n');
      if (sha == null) {
        sides.write('tree $index ${shellQuote(path)}\n');
      } else {
        sides.write('blob n $index ${shellQuote('$sha:$path')}\n');
      }
    }
    return underSh(
      '${_enter(directory)}'
      'if command -v strikedddd >/dev/null 2>&1 && '
      'case \$PWD in *\'"\'*|*\'\\\'*) false;; esac; then\n'
      '  a=${shellQuote(request)}\n'
      '  r=\$(printf \'{"service":"git/1","op":"diff","owner":"%s","args":{"directory":"%s",%s}\' '
      '"\$(id -un)" "\$PWD" "\${a#\\{}" | strikedddd 2>/dev/null)\n'
      '  case \$r in \'{"ok":true\'*) printf \'E\\n%s\' "\$r"; exit 0;; esac\n'
      'fi\n'
      "printf 'S\\n'\n"
      'total=0\n'
      'put() {\n'
      '  if [ -z "\$3" ]; then printf \'\\0\\036%s %s -\\n\' "\$1" "\$2"; return 1; fi\n'
      '  if [ "\$((\$3))" -gt $textBytes ]; then printf \'\\0\\036%s %s L\\n\' "\$1" "\$2"; return 1; fi\n'
      '  total=\$((total + \$3))\n'
      '  if [ "\$total" -gt $textBudget ]; then printf \'\\0\\036%s %s B\\n\' "\$1" "\$2"; return 1; fi\n'
      '  printf \'\\0\\036%s %s T\\n\' "\$1" "\$2"\n'
      '}\n'
      'blob() { put "\$1" "\$2" "\$(git cat-file -s "\$3" 2>/dev/null)" && git cat-file blob "\$3"; }\n'
      'tree() {\n'
      '  if [ -f "\$2" ]; then put n "\$1" "\$(wc -c < "\$2")" && cat -- "\$2"\n'
      '  else put n "\$1" ""; fi\n'
      '}\n'
      '$sides'
      'exit 0\n',
    );
  }

  /// [path] is relative to the workspace root, and the empty string is the root itself.
  static String listing(String directory, String path) {
    final target = path.isEmpty ? directory : '$directory/$path';
    return underSh(
      '${shellCd(target)} 2>/dev/null || exit $workspaceNoDirectory\n'
      '${listEntries(follow: false)}',
    );
  }

  /// The cap is what keeps a mistaken tap from pulling a 200 MB log over the radio.
  static String file(String directory, String path, {int bytes = 262144}) =>
      underSh(
        '${shellCd(directory)} 2>/dev/null || exit $workspaceNoDirectory\n'
        'head -c $bytes -- ${shellQuote(path)}\n',
      );

  static String commits(String directory, {int count = 100}) => underSh(
    '${_enter(directory)}'
    'git --no-pager log --no-color -n $count '
    "--pretty='format:%H%x1f%h%x1f%an%x1f%ar%x1f%s'\n",
  );

  /// `--first-parent` so a merge shows the change it brought in rather than nothing at
  /// all.
  static String commitFiles(String directory, String sha) => underSh(
    '${_enter(directory)}'
    'git --no-pager show --no-color --first-parent --numstat --format= '
    '${shellQuote(sha)}\n'
    "printf '\\036\\n'\n"
    'git --no-pager show --no-color --first-parent --name-status --format= '
    '${shellQuote(sha)}\n',
  );

  static String commitDiff(String directory, String sha, String path) =>
      underSh(
        '${_enter(directory)}'
        'git --no-pager show --no-color --first-parent --format= '
        '${shellQuote(sha)} -- ${shellQuote(path)} | head -c $diffBytes\n',
      );
}

String listEntries({required bool follow}) => _listEntries
    .replaceAll('@find', follow ? 'find -L' : 'find')
    .replaceAll('@kind', follow ? '%Y' : '%y')
    .replaceAll('@link', follow ? 'false' : '[ -L "\$f" ]');

const _listEntries = r'''
if find . -maxdepth 0 -printf '' >/dev/null 2>&1; then
  LC_ALL=C @find . -mindepth 1 -maxdepth 1 -printf '@kind\t%s\t%f\n' 2>/dev/null
else
  for f in .* *; do
    case $f in .|..) continue ;; esac
    if @link; then printf 'l\t0\t%s\n' "$f"
    elif [ -d "$f" ]; then printf 'd\t0\t%s\n' "$f"
    elif [ -f "$f" ]; then
      s=$(wc -c < "$f" 2>/dev/null)
      printf 'f\t%s\t%s\n' "$((${s:-0}))" "$f"
    elif [ -L "$f" ]; then printf 'f\t0\t%s\n' "$f"
    fi
  done
fi
''';
