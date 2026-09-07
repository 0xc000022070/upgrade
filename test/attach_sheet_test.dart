/// The `?` on the attach sheet: the copy that says where a picture goes, off
/// until it is asked for and gone again on a second tap.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spectacle/application/clips.dart';
import 'package:spectacle/data/repositories/host_repository.dart';
import 'package:spectacle/design/colors.dart';
import 'package:spectacle/design/components/panel.dart';
import 'package:spectacle/features/shell/attach_sheet.dart';
import 'package:spectacle/features/shell/shell_sessions.dart';

import 'support/fake_shell.dart';
import 'support/platform_channels.dart';

const _nyx = Host(
  id: 'h2',
  name: 'nyx',
  address: '100.64.0.2',
  port: 22,
  user: 'luis',
  keyId: 'key-1',
);

void main() {
  setUp(stubDeviceChannels);

  late Directory directory;
  late ClipStore clips;
  late FakeShellTransport transport;
  late ShellSessions sessions;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('spectacle-attach-test');
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

  /// The sheet over a live shell, opened the way the key bar opens it.
  Future<void> openSheet(WidgetTester tester) async {
    final session = sessions.open(_nyx)!;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          shellSessionsProvider.overrideWithValue(sessions),
          clipStoreProvider.overrideWithValue(clips),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => GestureDetector(
              onTap: () => showAttachSheet(
                context,
                session: session,
                pick: () async => [],
              ),
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
    expect(inkOf(tester), SpectacleColors.textMuted);
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
    expect(inkOf(tester), SpectacleColors.accent);

    await tester.tap(help);
    await tester.pumpAndSettle();
    expect(inkOf(tester), SpectacleColors.textMuted);
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

    expect(connection.execs, isEmpty);
    expect(connection.writes, isEmpty);
    expect(clips.count, 0);
  });
}
