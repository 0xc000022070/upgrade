import '../shell/remote_shell.dart';

/// What separates the sections of a composed answer. `RS`, which git never
/// writes: a marker made of ordinary characters would eventually be a line of
/// somebody's diff.
const workspaceRecord = '\u001e';

/// What separates the fields inside one line of `log`. `US`, for the reason
/// [workspaceRecord] is `RS`: a subject holds whatever a person typed into
/// it, tabs and pipes included.
const workspaceField = '\u001f';

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
/// Nothing here writes. The whole surface is `status`, `worktree list`, `log`,
/// `show`, `diff` and a listing — a workspace is read from the phone and
/// changed from the shell. Reading a commit does not move `HEAD`.
abstract final class WorkspaceCommands {
  /// `cd` plus the checkout test both answers share, with the two failures the
  /// caller can word given codes of their own.
  static String _enter(String directory) =>
      '${shellCd(directory)} 2>/dev/null || exit $workspaceNoDirectory\n'
      'git rev-parse --git-dir >/dev/null 2>&1 || exit $workspaceNoRepository\n';

  /// The checkout a directory is inside, which is what the viewer opens: a
  /// shell three directories deep is still standing in the whole repository.
  /// A directory inside none exits non-zero and says so by saying nothing.
  static String repository(String directory) => underSh(
    '${_enter(directory)}'
    'exec git rev-parse --show-toplevel\n',
  );

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

  /// How much of a diff comes back on one command. A phone is not where a
  /// regenerated lockfile is read line by line, and the cap is what stops a
  /// tap on one from pulling it over the radio. `head` cuts bytes and will cut
  /// a line in half; the reader is told what the cap was and drops the file it
  /// landed in rather than drawing half of one.
  static const diffBytes = 524288;

  /// Every changed file's hunks against `HEAD`, in one command.
  ///
  /// The round trip is the cost, not the bytes: a commit of twenty files asked
  /// for one file at a time is twenty handshakes' worth of latency on a radio,
  /// and the user pays it walking the list. So the whole diff comes back with
  /// the file list and a tap after that draws from what is already here.
  static String sourceDiff(String directory) => underSh(
    '${_enter(directory)}'
    'git --no-pager diff --no-color HEAD | head -c $diffBytes\n',
  );

  /// The same, for one commit.
  static String commitDiffAll(String directory, String sha) => underSh(
    '${_enter(directory)}'
    'git --no-pager show --no-color --first-parent --format= '
    '${shellQuote(sha)} | head -c $diffBytes\n',
  );

  /// One file's hunks. `HEAD` and not the index, so a file staged and then
  /// edited again reads as the one change the user made rather than as two.
  ///
  /// The fallback for a file the whole-diff answer was cut before reaching, and
  /// the only command a file bigger than the cap is ever read by.
  static String fileDiff(String directory, String path) => underSh(
    '${_enter(directory)}'
    'git --no-pager diff --no-color HEAD -- ${shellQuote(path)} '
    '| head -c $diffBytes\n',
  );

  /// An untracked file's contents, worded as a diff so one parser reads both.
  /// `--no-index` exits 1 when the two sides differ, which here is always, so
  /// the code is thrown away rather than read as a failure.
  static String newFileDiff(String directory, String path) => underSh(
    '${_enter(directory)}'
    'git --no-pager diff --no-color --no-index -- /dev/null '
    '${shellQuote(path)} | head -c $diffBytes\n'
    'exit 0\n',
  );

  /// One directory's entries, type and size and name. [path] is relative to
  /// the workspace root, and the empty string is the root itself.
  static String listing(String directory, String path) {
    final target = path.isEmpty ? directory : '$directory/$path';
    return underSh(
      '${shellCd(target)} 2>/dev/null || exit $workspaceNoDirectory\n'
      "LC_ALL=C find . -mindepth 1 -maxdepth 1 -printf '%y\\t%s\\t%f\\n' "
      '2>/dev/null\n',
    );
  }

  /// One file's text, capped. A phone is not where a 200 MB log is read, and
  /// the cap is what keeps a mistaken tap from pulling one over the radio.
  static String file(String directory, String path, {int bytes = 262144}) =>
      underSh(
        '${shellCd(directory)} 2>/dev/null || exit $workspaceNoDirectory\n'
        'head -c $bytes -- ${shellQuote(path)}\n',
      );

  /// The history behind the directory, newest first and capped: a phone is not
  /// where a repository is read whole, and this list is a picker.
  static String commits(String directory, {int count = 100}) => underSh(
    '${_enter(directory)}'
    'git --no-pager log --no-color -n $count '
    "--pretty='format:%H%x1f%h%x1f%an%x1f%ar%x1f%s'\n",
  );

  /// One commit's files, in one trip: the counts, then the letters that say
  /// what happened to each path. `--first-parent` so a merge shows the change
  /// it brought in rather than nothing at all.
  static String commitFiles(String directory, String sha) => underSh(
    '${_enter(directory)}'
    'git --no-pager show --no-color --first-parent --numstat --format= '
    '${shellQuote(sha)}\n'
    "printf '\\036\\n'\n"
    'git --no-pager show --no-color --first-parent --name-status --format= '
    '${shellQuote(sha)}\n',
  );

  /// One file's hunks inside one commit.
  static String commitDiff(String directory, String sha, String path) =>
      underSh(
        '${_enter(directory)}'
        'git --no-pager show --no-color --first-parent --format= '
        '${shellQuote(sha)} -- ${shellQuote(path)} | head -c $diffBytes\n',
      );
}
