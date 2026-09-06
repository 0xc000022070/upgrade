import '../shell/remote_shell.dart';

/// What separates the sections of a composed answer. `RS`, which git never
/// writes: a marker made of ordinary characters would eventually be a line of
/// somebody's diff.
const workspaceRecord = '\u001e';

/// The directory named is not there.
const workspaceNoDirectory = 20;

/// It is there and it is not a checkout.
const workspaceNoRepository = 21;

/// The commands a workspace is read with.
///
/// Every one of them is a single `sh -c`, because the cost of asking a machine
/// on the other side of a phone's radio is the round trip and not the bytes:
/// one user action is one command, and a screen that wants three answers asks
/// for them at once and splits the reply on [workspaceRecord].
///
/// Nothing here writes. The whole surface is `status`, `worktree list`, `diff`
/// and a listing — a workspace is read from the phone and changed from the
/// shell.
abstract final class WorkspaceCommands {
  /// `cd` plus the checkout test both answers share, with the two failures the
  /// caller can word given codes of their own.
  static String _enter(String directory) =>
      'cd ${shellQuote(directory)} 2>/dev/null || exit $workspaceNoDirectory\n'
      'git rev-parse --git-dir >/dev/null 2>&1 || exit $workspaceNoRepository\n';

  /// Everything the detail screen opens with: the branch line, the siblings,
  /// and what has changed. Three answers, one trip.
  static String overview(String directory) => underSh(
    '${_enter(directory)}'
    'git status --porcelain=v2 --branch\n'
    "printf '\\036\\n'\n"
    'git worktree list --porcelain\n'
    "printf '\\036\\n'\n"
    'git diff --numstat HEAD\n',
  );

  /// One file's hunks. `HEAD` and not the index, so a file staged and then
  /// edited again reads as the one change the user made rather than as two.
  static String fileDiff(String directory, String path) => underSh(
    '${_enter(directory)}'
    'git --no-pager diff --no-color HEAD -- ${shellQuote(path)}\n',
  );

  /// An untracked file's contents, worded as a diff so one parser reads both.
  /// `--no-index` exits 1 when the two sides differ, which here is always, so
  /// the code is thrown away rather than read as a failure.
  static String newFileDiff(String directory, String path) => underSh(
    '${_enter(directory)}'
    'git --no-pager diff --no-color --no-index -- /dev/null '
    '${shellQuote(path)}\n'
    'exit 0\n',
  );

  /// One directory's entries, type and size and name. [path] is relative to
  /// the workspace root, and the empty string is the root itself.
  static String listing(String directory, String path) {
    final target = path.isEmpty ? directory : '$directory/$path';
    return underSh(
      'cd ${shellQuote(target)} 2>/dev/null || exit $workspaceNoDirectory\n'
      "LC_ALL=C find . -mindepth 1 -maxdepth 1 -printf '%y\\t%s\\t%f\\n' "
      '2>/dev/null\n',
    );
  }

  /// One file's text, capped. A phone is not where a 200 MB log is read, and
  /// the cap is what keeps a mistaken tap from pulling one over the radio.
  static String file(
    String directory,
    String path, {
    int bytes = 262144,
  }) => underSh(
    'cd ${shellQuote(directory)} 2>/dev/null || exit $workspaceNoDirectory\n'
    'head -c $bytes -- ${shellQuote(path)}\n',
  );
}
