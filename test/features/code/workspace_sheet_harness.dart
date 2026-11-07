import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/app/upgrade_app.dart';
import 'package:upgrade/application/agents/agents.dart';
import 'package:upgrade/application/providers.dart';
import 'package:upgrade/data/database.dart';
import 'package:upgrade/data/repositories/settings_repository.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/data/repositories/path_repository.dart';
import 'package:upgrade/design/components/list_row.dart';
import 'package:upgrade/features/code/diff_sheet.dart';
import 'package:upgrade/features/code/workspace_sheet.dart';
import 'package:upgrade/platform/herdr/herdr_client.dart';
import 'package:upgrade/platform/ssh/keys.dart';
import 'package:upgrade/platform/workspace/workspace_client.dart';
import 'package:upgrade/platform/workspace/workspace_commands.dart';

import '../../support/platform_channels.dart';
import '../../support/themed_app.dart';

export 'package:drift/native.dart';
export 'package:flutter/material.dart';
export 'package:flutter/services.dart';
export 'package:flutter_riverpod/flutter_riverpod.dart';
export 'package:upgrade/app/upgrade_app.dart';
export 'package:upgrade/application/agents/agents.dart';
export 'package:upgrade/application/shell/pane_share.dart';
export 'package:upgrade/application/providers.dart';
export 'package:upgrade/data/database.dart';
export 'package:upgrade/data/repositories/settings_repository.dart';
export 'package:upgrade/data/repositories/host_repository.dart';
export 'package:upgrade/data/repositories/path_repository.dart';
export 'package:upgrade/design/components/list_row.dart';
export 'package:upgrade/design/components/panel.dart';
export 'package:upgrade/design/components/path_line.dart';
export 'package:upgrade/design/colors.dart';
export 'package:upgrade/design/icons/upgrade_icon.dart';
export 'package:upgrade/design/icons/upgrade_icons.dart';
export 'package:upgrade/design/layout.dart';
export 'package:upgrade/design/spacing.dart';
export 'package:upgrade/design/tokens.dart';
export 'package:upgrade/features/code/diff_map.dart';
export 'package:upgrade/features/code/diff_key.dart';
export 'package:upgrade/features/code/explorer.dart';
export 'package:upgrade/features/code/diff_lists.dart';
export 'package:upgrade/features/code/diff_sheet.dart';
export 'package:upgrade/features/code/file_icons.dart';
export 'package:upgrade/features/code/workspace_sheet.dart';
export 'package:upgrade/platform/herdr/herdr_client.dart';
export 'package:upgrade/platform/ssh/keys.dart';
export 'package:upgrade/platform/workspace/workspace_client.dart';
export 'package:upgrade/platform/workspace/workspace_commands.dart';

export '../../support/platform_channels.dart';
export '../../support/themed_app.dart';

/// The point of the fake is the round trips: it records every command, and the tests
/// assert on how many there were as much as on what came back.

const gitStatus = '''
# branch.head main
# branch.upstream origin/main
# branch.ab +1 -0
1 .M N... 100644 100644 100644 aaa bbb lib/main.dart
? scratch.txt
''';

const gitWorktrees = '''
worktree /home/alex/src/upgrade
HEAD 1a2b
branch refs/heads/main

worktree /home/alex/src/upgrade-fix
HEAD 5e6f
branch refs/heads/fix/paths

''';

const gitNumstat = '3\t1\tlib/main.dart\n';

String get gitOverview =>
    '$gitStatus$workspaceRecord\n$gitWorktrees$workspaceRecord\n$gitNumstat';

/// A line wider than the pane, so the text has somewhere to go sideways.
const wideLine =
    "const banner = 'the line a terminal wraps and a phone cannot, which is "
    "what the rail under the pane is there to admit';";

/// Indented the way a file that uses tabs is, which the pane measures as eight columns
/// and the face draws as one.
const tabbedLine = '\tif (err != null) {';

const gitDiff =
    '''
diff --git a/lib/main.dart b/lib/main.dart
@@ -1,3 +1,3 @@ void main() {
-const port = 22;
+const port = 357;
 $wideLine
 $tabbedLine
''';

String get _log =>
    '1a2b3c4d5e${workspaceField}1a2b3c${workspaceField}Alex'
    '${workspaceField}3 days ago${workspaceField}fix(shell): the font\n'
    '5e6f7a8b9c${workspaceField}5e6f7a${workspaceField}Alex'
    '${workspaceField}2 weeks ago${workspaceField}docs(spec): rulings\n';

String get _commitFiles =>
    '2\t0\tlib/shell/shell_header.dart\n'
    '1\t1\tlib/shell/shell_tabs.dart\n'
    '$workspaceRecord\n'
    'M\tlib/shell/shell_header.dart\n'
    'M\tlib/shell/shell_tabs.dart\n';

const gitCommitDiff = '''
diff --git a/lib/shell/shell_header.dart b/lib/shell/shell_header.dart
@@ -1,2 +1,2 @@
-const mark = false;
+const mark = true;
diff --git a/lib/shell/shell_tabs.dart b/lib/shell/shell_tabs.dart
@@ -9,2 +9,2 @@
-const tabs = 4;
+const tabs = 8;
''';

/// An answer `head` stopped at the cap: the same bytes the command asked for, which is
/// how a caller tells a diff that ended from one that was cut.
String cappedDiff(String head) {
  final body = StringBuffer(head);
  final line = ' ${'x' * 200}\n';
  while (body.length < WorkspaceCommands.diffBytes) {
    body.write(line);
  }
  return body.toString();
}

final writesIndex = RegExp(
  r'\bgit(\s+(-[cC]\s+\S+|--\S+))*\s+(add|commit|checkout|switch|restore|reset|stash|rm|mv|push|'
  r'pull|fetch|merge|rebase|apply|clean|branch|tag|worktree\s+(add|remove))\b'
  r'|\b(rm|mv|touch|tee|truncate)\s|\bsed\s+-i|>\s*(?!/dev/null|&)[^\s>&]',
);

class FakeRunner implements WorkspaceRunner {
  FakeRunner({this.overview, this.fail, this.texts = const {}});

  final String? overview;

  final Map<String, (String, String)> texts;

  final HerdrFailure? fail;

  final commands = <String>[];
  var closed = false;

  /// Per-command overrides, keyed by a fragment of the command.
  final answers = <String, WorkspaceReply>{};

  final failures = <String, HerdrFailure>{};

  @override
  Future<WorkspaceReply> run(String command) async {
    commands.add(command);
    if (fail != null) throw fail!;
    for (final entry in failures.entries) {
      if (command.contains(entry.key)) throw entry.value;
    }
    for (final entry in answers.entries) {
      if (command.contains(entry.key)) return entry.value;
    }
    if (command.contains('upgraded') && texts.isNotEmpty) {
      final reply = StringBuffer('S\n');
      for (final match in RegExp(
        r"^tree (\d+) '\\''([^']+)'\\''$",
        multiLine: true,
      ).allMatches(command)) {
        final (old, now) = texts[match[2]] ?? ('', '');
        reply
          ..write('${workspaceFrame}o ${match[1]} T\n$old')
          ..write('${workspaceFrame}n ${match[1]} T\n$now');
      }
      return WorkspaceReply(exitCode: 0, stdout: reply.toString(), stderr: '');
    }
    if (command.contains('git --no-pager log')) {
      return WorkspaceReply(exitCode: 0, stdout: _log, stderr: '');
    }
    if (command.contains('--numstat --format=')) {
      return WorkspaceReply(exitCode: 0, stdout: _commitFiles, stderr: '');
    }
    if (command.contains('status --porcelain')) {
      return WorkspaceReply(
        exitCode: 0,
        stdout: overview ?? gitOverview,
        stderr: '',
      );
    }
    if (command.contains('--first-parent --format=') &&
        !command.contains(' -- ')) {
      return const WorkspaceReply(
        exitCode: 0,
        stdout: gitCommitDiff,
        stderr: '',
      );
    }
    if (command.contains('diff') || command.contains('show')) {
      return const WorkspaceReply(exitCode: 0, stdout: gitDiff, stderr: '');
    }
    if (command.contains('find')) {
      return const WorkspaceReply(
        exitCode: 0,
        stdout: 'd\t4096\tlib\nf\t120\tREADME.md\n',
        stderr: '',
      );
    }
    return const WorkspaceReply(exitCode: 0, stdout: 'file body\n', stderr: '');
  }

  @override
  Future<void> close() async => closed = true;
}

/// The pieces of a drawn line that carry a ground of their own.
List<String> litRuns(WidgetTester tester, Finder line) {
  final runs = <String>[];
  tester.widget<Text>(line).textSpan?.visitChildren((span) {
    if (span is TextSpan && span.style?.backgroundColor != null) {
      runs.add(span.text ?? '');
    }
    return true;
  });
  return runs;
}

late MemoryPrivateKeyStore privateKeys;
// The explorer's seams are a preference, so the screen reads a real preferences table
// rather than a stub that would answer the default for every test alike.
late AppDatabase db;
late SettingsRepository settings;

void setUpWorkspaceSheet() {
  setUp(() async {
    stubDeviceChannels();
    privateKeys = MemoryPrivateKeyStore();
    await privateKeys.write('key-1', 'PEM');
    db = AppDatabase(NativeDatabase.memory());
    settings = SettingsRepository(db);
  });

  tearDown(() => db.close());
}

const host = Host(
  id: 'host-1',
  name: 'oak',
  address: '100.64.0.1',
  port: 357,
  user: 'alex',
  keyId: 'key-1',
);

final path = AgentPath(
  id: 'path-1',
  hostId: 'host-1',
  directory: '/home/alex/src/upgrade',
  label: 'upgrade',
  createdAt: DateTime(2026, 9, 3),
);

Widget app(FakeRunner runner) => ProviderScope(
  retry: noRetry,
  overrides: [
    privateKeyStoreProvider.overrideWithValue(privateKeys),
    databaseProvider.overrideWithValue(db),
  ],
  child: MaterialApp(
    theme: testTheme,
    builder: houseText,
    home: WorkspaceSheet(
      path: path,
      host: host,
      open: ({
        required address,
        required port,
        required user,
        required privateKey,
        required verifier,
      }) async => runner,
    ),
  ),
);

Future<void> ready(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<FakeRunner> open(
  WidgetTester tester, {
  FakeRunner? runner,
  Size size = const Size(400, 1600),
}) async {
  final fake = runner ?? FakeRunner();
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(app(fake));
  await ready(tester);
  return fake;
}

Future<void> unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 1));
}

Future<void> tapText(WidgetTester tester, String text) async {
  await tester.tap(find.text(text).last);
  await ready(tester);
}

Future<void> tapMark(WidgetTester tester, String label) async {
  await tester.tap(find.bySemanticsLabel(label).last);
  await ready(tester);
}

/// Only what is on the sheet. The workspace screen it opened over stays mounted
/// underneath, and it says several of the same words.
Finder onSheet(Finder matching) =>
    find.descendant(of: find.byType(DiffSheet), matching: matching);

/// Found by path and not by the words it draws: a path too wide for its row gives up
/// leading directories, and the test font is square, so the fixtures' rows shorten where
/// a device's would not.
Finder fileRow(String path) => onSheet(find.byKey(ValueKey('diff-file-$path')));

Future<void> tapFile(WidgetTester tester, String path) async {
  await tester.tap(fileRow(path));
  await ready(tester);
}

/// How much tape the explorer had already spent when the sheet was asked for, so a count
/// of the viewer's round trips is the viewer's alone.
var spent = 0;

Future<FakeRunner> viewer(
  WidgetTester tester, {
  Size? size,
  FakeRunner? runner,
}) async {
  final opened = await open(
    tester,
    runner: runner,
    size: size ?? const Size(400, 1600),
  );
  await tester.tap(find.textContaining('CHANGED').last);
  await ready(tester);
  await tester.tap(find.widgetWithText(ListRow, 'lib/main.dart'));
  await ready(tester);
  spent = opened.commands.length;
  await tapMark(tester, 'DIFF');
  return opened;
}

Future<void> unfold(WidgetTester tester, String title) async {
  await tester.tap(onSheet(find.text(title)));
  await ready(tester);
}

Future<FakeRunner> panes(WidgetTester tester) async {
  final runner = await viewer(tester);
  await tapText(tester, 'CLOSE');
  await unfold(tester, 'COMMITS');
  return runner;
}

/// Every command that came back with hunks in it.
int diffsAsked(FakeRunner runner) => runner.commands
    .skip(spent)
    .where(
      (command) =>
          command.contains('--no-color HEAD') ||
          (command.contains('--no-index') &&
              !command.contains('status --porcelain')) ||
          command.contains('--first-parent --format='),
    )
    .length;

/// A diff line is laid out at its full width inside an overflow box, so the middle of a
/// long one is off the screen and the press lands on nothing.
Offset onRow(WidgetTester tester, String text) =>
    tester.getTopLeft(onSheet(find.text(text))) + const Offset(4, 4);

const held = '        if (err != null) {';

bool Function(Widget) groundOf(Color color) =>
    (widget) => widget is ColoredBox && widget.color == color;
