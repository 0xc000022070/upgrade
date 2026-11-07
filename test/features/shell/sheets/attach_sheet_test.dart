import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/application/drops/clips.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/design/colors.dart';
import 'package:upgrade/design/components/panel.dart';
import 'package:upgrade/features/screen/screen_preview.dart';
import 'package:upgrade/features/shell/sheets/attach_sheet.dart';
import 'package:upgrade/features/shell/session/shell_sessions.dart';
import 'package:upgrade/platform/shell/remote_shell.dart';
import 'package:upgrade/application/providers.dart';

import '../../../support/fake_shell.dart';
import '../../../support/platform_channels.dart';
import '../../../support/reasons.dart';
import '../../../support/themed_app.dart';

const _oak = Host(
  id: 'h2',
  name: 'oak',
  address: '100.64.0.2',
  port: 22,
  user: 'alex',
  keyId: 'key-1',
);

void main() {
  setUp(stubDeviceChannels);

  late Directory directory;
  late ClipStore clips;
  late FakeShellTransport transport;
  late ShellSessions sessions;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('upgrade-attach-test');
    clips = ClipStore(directory);
    transport = FakeShellTransport();
    sessions = fakeShellSessions(transport);
  });

  tearDown(() {
    sessions.dispose();
    directory.deleteSync(recursive: true);
  });

  final help = find.byKey(const ValueKey('attach-help'));
  final copy = find.byKey(const ValueKey('attach-help-body'));
  final photos = find.byKey(const ValueKey('attach-photos'));

  Future<void> openSheet(
    WidgetTester tester, {
    PhotoPicker pick = _none,
  }) async {
    final session = sessions.open(intent: testIntent(), _oak)!;
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpWidget(
      ProviderScope(
        retry: noRetry,
        overrides: [
          shellSessionsProvider.overrideWithValue(sessions),
          clipStoreProvider.overrideWithValue(clips),
        ],
        child: MaterialApp(
          theme: testTheme,
          home: Builder(
            builder: (context) => GestureDetector(
              onTap: () =>
                  showAttachSheet(context, session: session, pick: pick),
              child: const Center(child: Text('OPEN')),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('OPEN'));
    await tester.pumpAndSettle();
  }

  Color inkOf(WidgetTester tester) => tester
      .widget<Text>(find.descendant(of: help, matching: find.text('?')))
      .style!
      .color!;

  testWidgets('the strip carries a ? and the sheet opens with no copy', (
    tester,
  ) async {
    await openSheet(tester);

    expect(help, findsOneWidget);
    expect(find.text('CANCEL'), findsOneWidget);
    expect(copy, findsNothing);
    expect(inkOf(tester), UpgradeColors.textMuted);
  });

  testWidgets('a tap raises the copy over PHOTOS and a second takes it away', (
    tester,
  ) async {
    await openSheet(tester);

    await tester.tap(help);
    await tester.pumpAndSettle();
    expect(copy, findsOneWidget);
    expect(
      tester.getBottomLeft(copy).dy,
      lessThan(tester.getTopLeft(photos).dy),
    );

    await tester.tap(help);
    await tester.pumpAndSettle();
    expect(copy, findsNothing);
  });

  testWidgets('the copy names the clipboard, the gallery and what HELD holds', (
    tester,
  ) async {
    await openSheet(tester);
    await tester.tap(help);
    await tester.pumpAndSettle();

    final said = tester
        .widgetList<Text>(
          find.descendant(of: copy, matching: find.byType(Text)),
        )
        .map((text) => text.data!)
        .join(' ');
    expect(said, contains('clipboard'));
    expect(said, contains('gallery'));
    expect(said, contains('SCREEN'));
    expect(said, contains('path'));
  });

  testWidgets('the ? reads accent for as long as the copy is open', (
    tester,
  ) async {
    await openSheet(tester);

    await tester.tap(help);
    await tester.pumpAndSettle();
    expect(inkOf(tester), UpgradeColors.accent);

    await tester.tap(help);
    await tester.pumpAndSettle();
    expect(inkOf(tester), UpgradeColors.textMuted);
  });

  testWidgets('CANCEL still closes the sheet with the copy open', (
    tester,
  ) async {
    await openSheet(tester);
    await tester.tap(help);
    await tester.pumpAndSettle();

    await tester.tap(find.text('CANCEL'));
    await tester.pumpAndSettle();

    expect(find.byType(PanelAffordance), findsNothing);
    expect(photos, findsNothing);
  });

  testWidgets('raising the copy sends nothing to the host', (tester) async {
    await openSheet(tester);
    final connection = transport.opened.single;

    await tester.tap(help);
    await tester.pumpAndSettle();

    // What a live shell runs on its own: the pinentry mark, and one look at what the
    // pinentry holds open.
    expect(connection.execs.map((exec) => exec.command), [
      pinentryMarkCommand(sessions.forHost(_oak.id).single.tab),
      pinentryOpenCommand(),
    ]);
    expect(connection.writes, isEmpty);
    expect(clips.count, 0);
  });

  testWidgets('a run draws a row per photo, lightest first, to its end', (
    tester,
  ) async {
    Uint8List png(int side) => encodePng(
      PreviewFrame(width: side, height: side, rgb: Uint8List(side * side * 3)),
    );
    final heavy = png(16);
    final light = png(2);
    await openSheet(tester, pick: (_) async => [heavy, light]);

    await tester.tap(photos);
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    final rows = find.byWidgetPredicate(
      (widget) =>
          widget.key is ValueKey<String> &&
          (widget.key! as ValueKey<String>).value.startsWith('attach-queued-'),
    );
    expect(rows, findsNWidgets(2));
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('attach-queued-1'))).dy,
      lessThan(
        tester.getTopLeft(find.byKey(const ValueKey('attach-queued-0'))).dy,
      ),
    );
    expect(
      find.descendant(of: rows, matching: find.text('PATH')),
      findsNWidgets(2),
    );
    expect(find.text('UP 0 · QUEUED 0 · LANDED 2'), findsOneWidget);
    await tester.pumpAndSettle(attachSheetLinger);
  });
}

Future<List<Uint8List>> _none(BuildContext _) async => [];
