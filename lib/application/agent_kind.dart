sealed class AgentKind {
  const AgentKind();

  static const all = <AgentKind>[ClaudeKind(), CodexKind()];

  static AgentKind? lookup(String name) {
    final wanted = name.trim().toLowerCase();
    for (final kind in all) {
      if (kind.name == wanted) return kind;
    }
    return null;
  }

  factory AgentKind.of(String name) {
    final kind = lookup(name);
    if (kind == null) throw ArgumentError.value(name, 'name');
    return kind;
  }

  String get name;

  bool matchesForegroundProcess(
    String command,
    String executable,
    String script,
  );

  String get markAsset => 'assets/icons/agent-$name.svg';

  List<String> get startFlags;

  List<String>? get bundledModels => null;

  List<String> get modelsArgv => const [];

  String get trustPhrase;

  /// Claude Code opens on `No, exit` and has to be walked down first; Codex opens on `Yes, continue`.
  List<String> get trustAnswer;

  ({String yes, String no}) get answerKeys;

  List<String>? trustKeys(String screen) =>
      screen.toLowerCase().contains(trustPhrase) ? trustAnswer : null;
}

class ClaudeKind extends AgentKind {
  const ClaudeKind();

  @override
  String get name => 'claude';

  @override
  bool matchesForegroundProcess(
    String command,
    String executable,
    String script,
  ) {
    final process = command.split('/').last;
    final binary = executable.split('/').last;
    final nodeCli = script.endsWith('/@anthropic-ai/claude-code/cli.js');
    if (process == name &&
        (binary == name ||
            binary == '.$name-wrapped' ||
            (binary == 'node' && nodeCli) ||
            executable.contains('/.local/share/claude/versions/'))) {
      return true;
    }
    return (process == 'node' || process == 'bun') &&
        binary == process &&
        nodeCli;
  }

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
}

class CodexKind extends AgentKind {
  const CodexKind();

  @override
  String get name => 'codex';

  @override
  bool matchesForegroundProcess(
    String command,
    String executable,
    String script,
  ) {
    final process = command.split('/').last;
    final binary = executable.split('/').last;
    if ((process == name || process == '.codex-wrapped') &&
        (binary == name || binary == '.codex-wrapped')) {
      return true;
    }
    return (process == 'node' || process == 'bun') &&
        binary == process &&
        script.endsWith('/@openai/codex/bin/codex.js');
  }

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
}
