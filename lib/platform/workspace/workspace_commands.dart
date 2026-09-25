import '../shell/remote_shell.dart';

/// `RS`, which git never writes: a marker made of ordinary characters would eventually
/// be a line of somebody's diff.
const workspaceRecord = '\u001e';

/// `US`, for the reason [workspaceRecord] is `RS`: a subject holds whatever a person
/// typed into it, tabs and pipes included.
const workspaceField = '\u001f';

const workspaceNoDirectory = 20;

const workspaceNoRepository = 21;

/// Every one of them is a single `sh -c`, because the cost of asking a machine on the
/// other side of a phone's radio is the round trip and not the bytes: a screen that
/// wants three answers asks for them at once and splits on [workspaceRecord]. Nothing
/// here writes.
abstract final class WorkspaceCommands {
  static String _enter(String directory) =>
      '${shellCd(directory)} 2>/dev/null || exit $workspaceNoDirectory\n'
      'git rev-parse --git-dir >/dev/null 2>&1 || exit $workspaceNoRepository\n';

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

  /// [path] is relative to the workspace root, and the empty string is the root itself.
  static String listing(String directory, String path) {
    final target = path.isEmpty ? directory : '$directory/$path';
    return underSh(
      '${shellCd(target)} 2>/dev/null || exit $workspaceNoDirectory\n'
      "LC_ALL=C find . -mindepth 1 -maxdepth 1 -printf '%y\\t%s\\t%f\\n' "
      '2>/dev/null\n',
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
