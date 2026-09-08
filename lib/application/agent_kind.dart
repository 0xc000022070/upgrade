/// One coding agent, and everything about it the app has to know apart from
/// the others: how it is started, which models it offers, how its first-run
/// trust dialog reads and is accepted, how it is answered while it is blocked,
/// and which mark is drawn for it.
///
/// Sealed on purpose. Every question below used to be a `switch` on a bare
/// string in a different file, each with its own answer for a name that was
/// neither agent; a case added here is now named by the analyser everywhere it
/// has to be answered for.
sealed class AgentKind {
  const AgentKind();

  /// Every kind the app can start, in the order the picker draws them.
  static const all = <AgentKind>[ClaudeKind(), CodexKind()];

  /// The kind [name] stands for, or null when it is not one of them. herdr
  /// reports whatever the pane happens to be running, so a name off the wire
  /// is a question: the panel draws `?` over an answer of null and the alert
  /// falls back to the keys most TUIs take.
  static AgentKind? lookup(String name) {
    final wanted = name.trim().toLowerCase();
    for (final kind in all) {
      if (kind.name == wanted) return kind;
    }
    return null;
  }

  /// The kind [name] stands for, for a caller about to build a command out of
  /// it. A name that is not an agent has no command, so it throws rather than
  /// reaching the host as one.
  factory AgentKind.of(String name) {
    final kind = lookup(name);
    if (kind == null) throw ArgumentError.value(name, 'name');
    return kind;
  }

  /// What herdr calls it, what the dispatch row stores, and what goes on the
  /// command line behind `--kind`.
  String get name;

  /// The mark under `assets/icons/`, drawn wherever an agent is named. The
  /// file is checked against this by the mark's own test rather than at
  /// runtime — a kind whose file is missing renders an empty box.
  String get markAsset => 'assets/icons/agent-$name.svg';

  /// The flags the agent itself is started with, behind herdr's `--`. Both
  /// kinds are started unattended: the phone is not where a permission prompt
  /// is answered.
  List<String> get startFlags;

  /// The models it offers, when it ships with a fixed list. Null when only the
  /// host can say, and then [modelsArgv] is what asks it.
  List<String>? get bundledModels => null;

  /// The command that lists its models on the host, for a kind that has no
  /// fixed list.
  List<String> get modelsArgv => const [];

  /// The words its first-run trust dialog is recognised by, lowercase. Matched
  /// on what the dialog says rather than on where it says it: the layout moves
  /// between releases and the sentence does not.
  String get trustPhrase;

  /// The keys that accept that dialog. Claude Code opens on `No, exit` and has
  /// to be walked down first; Codex opens on `Yes, continue`.
  List<String> get trustAnswer;

  /// The keys that answer it while a pane is blocked.
  ({String yes, String no}) get answerKeys;

  /// The keys accepting the trust dialog on [screen], or null when the screen
  /// is not that dialog.
  List<String>? trustKeys(String screen) =>
      screen.toLowerCase().contains(trustPhrase) ? trustAnswer : null;

  /// What it prints at the head of the line where it copies back a message the
  /// user sent. The buffer holds what was printed, so this echo is the only
  /// trace a sent message leaves in it.
  String get turnMark;

  /// Where this kind's mark is on [line], or null when the line is not one of
  /// its turns.
  ///
  /// The mark has to open the line — a `>` in the middle of a sentence the
  /// agent printed is not a turn — and something has to follow it, which is
  /// what keeps the empty input box off the list.
  int? turnMarkAt(String line) {
    final at = line.indexOf(turnMark);
    if (at == -1) return null;
    if (line.substring(0, at).trimLeft().isNotEmpty) return null;
    return line.substring(at + turnMark.length).trim().isEmpty ? null : at;
  }
}

class ClaudeKind extends AgentKind {
  const ClaudeKind();

  @override
  String get name => 'claude';

  @override
  List<String> get startFlags => const [
    '--settings',
    '{"skipDangerousModePermissionPrompt":true}',
    '--dangerously-skip-permissions',
  ];

  @override
  List<String> get bundledModels => const ['opus', 'sonnet', 'fable'];

  @override
  String get trustPhrase => 'trust this folder';

  @override
  List<String> get trustAnswer => const ['down', 'enter'];

  @override
  ({String yes, String no}) get answerKeys => (yes: 'enter', no: 'esc');

  @override
  String get turnMark => '> ';
}

class CodexKind extends AgentKind {
  const CodexKind();

  @override
  String get name => 'codex';

  @override
  List<String> get startFlags => const ['--yolo'];

  @override
  List<String> get modelsArgv => const [
    'codex',
    'debug',
    'models',
    '--bundled',
  ];

  @override
  String get trustPhrase => 'trust the contents of this directory';

  @override
  List<String> get trustAnswer => const ['enter'];

  @override
  ({String yes, String no}) get answerKeys => (yes: 'y', no: 'n');

  @override
  String get turnMark => '\u203a ';
}
