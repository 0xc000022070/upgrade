import 'support/native_plugins.dart';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dazzle/application/drop_selection.dart';
import 'package:dazzle/data/database.dart';
import 'package:dazzle/data/repositories/activity_repository.dart';
import 'package:dazzle/data/repositories/goal_repository.dart';
import 'package:dazzle/data/repositories/project_repository.dart';
import 'package:dazzle/design/colors.dart';
import 'package:dazzle/design/components/action_block.dart';
import 'package:dazzle/design/components/keyboard_toolbar.dart';
import 'package:dazzle/design/components/dazzle_field.dart';
import 'package:dazzle/features/home/capture_bar.dart';

import 'support/platform_channels.dart';
import 'support/themed_app.dart';

Future<void> _drain(
  WidgetTester tester, {
  Duration step = Duration.zero,
}) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(step);
  }
}

Future<void> _ready(WidgetTester tester) =>
    _drain(tester, step: const Duration(milliseconds: 100));

Finder _glyph(ToolbarGlyph glyph) => find.byWidgetPredicate(
  (widget) => widget is Icon && widget.icon == glyph.icon,
);

/// The strip lives in the root overlay rather than under the bar, so the two fields are
/// told apart by which side of that split they are on.
final _line = find.descendant(
  of: find.byType(KeyboardToolbar),
  matching: find.byType(TextField),
);

final _capture = find.descendant(
  of: find.byType(CaptureBar),
  matching: find.byType(TextField),
);

void main() {
  late AppDatabase db;
  late ProjectRepository projects;
  late GoalRepository goals;

  setUp(() async {
    stubDeviceChannels();
    stubClipboard(null);
    db = AppDatabase(NativeDatabase.memory());
    projects = ProjectRepository(db, ActivityRepository(db));
    goals = GoalRepository(db, ActivityRepository(db));
  });

  tearDown(() => db.close());

  Widget host() => ProviderScope(
    overrides: [...featureTestOverrides(db)],
    child: MaterialApp(
      theme: testTheme,
      home: Scaffold(body: CaptureBar(scope: DropSelection.homeScope)),
    ),
  );

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  testWidgets('the strip is not there until the field is', (tester) async {
    await tester.pumpWidget(host());
    await _ready(tester);

    expect(find.byType(KeyboardToolbar), findsNothing);

    await tester.tap(find.byType(TextField));
    await _ready(tester);

    expect(find.byType(KeyboardToolbar), findsOneWidget);
    expect(_glyph(ToolbarGlyph.link), findsOneWidget);
    expect(_glyph(ToolbarGlyph.image), findsOneWidget);
    expect(_glyph(ToolbarGlyph.more), findsOneWidget);
    expect(_glyph(ToolbarGlyph.target), findsNothing);
    expect(_glyph(ToolbarGlyph.done), findsNothing);

    await unmount(tester);
  });

  testWidgets('`+` swaps the row for the extras and `back` returns', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await _ready(tester);
    await tester.tap(find.byType(TextField));
    await _ready(tester);

    await tester.tap(_glyph(ToolbarGlyph.more));
    await _ready(tester);

    expect(_glyph(ToolbarGlyph.back), findsOneWidget);
    expect(_glyph(ToolbarGlyph.target), findsOneWidget);
    expect(_glyph(ToolbarGlyph.next), findsNothing);
    expect(_glyph(ToolbarGlyph.block), findsNothing);
    expect(_glyph(ToolbarGlyph.link), findsNothing);

    await tester.tap(_glyph(ToolbarGlyph.back));
    await _ready(tester);

    expect(_glyph(ToolbarGlyph.link), findsOneWidget);
    expect(_glyph(ToolbarGlyph.target), findsNothing);

    await unmount(tester);
  });

  testWidgets('a tap on the scrim drops focus, and the row snaps back', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await _ready(tester);
    await tester.tap(find.byType(TextField));
    await _ready(tester);
    await tester.tap(_glyph(ToolbarGlyph.more));
    await _ready(tester);
    expect(_glyph(ToolbarGlyph.target), findsOneWidget);

    await tester.tapAt(const Offset(10, 10));
    await _ready(tester);

    expect(find.byType(KeyboardToolbar), findsNothing);

    await tester.tap(find.byType(TextField));
    await _ready(tester);

    expect(_glyph(ToolbarGlyph.target), findsNothing);
    expect(_glyph(ToolbarGlyph.more), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('the target icon aims the capture and only then shows a chip', (
    tester,
  ) async {
    final project = await projects.create(name: 'Infra personal');

    await tester.pumpWidget(host());
    await _ready(tester);
    await tester.tap(find.byType(TextField));
    await _ready(tester);

    expect(find.text('[ DROPS ]'), findsNothing);
    expect(
      KeyboardAccessory.reservedHeight.value,
      KeyboardToolbar.heightFor(chips: false),
    );

    await tester.tap(_glyph(ToolbarGlyph.more));
    await _ready(tester);
    await tester.tap(_glyph(ToolbarGlyph.target));
    await _ready(tester);
    expect(find.text('CAPTURE INTO'), findsWidgets);

    await tester.tap(find.text('INFRA PERSONAL'));
    await _ready(tester);
    expect(find.text('[ INFRA PERSONAL ]'), findsOneWidget);
    expect(
      KeyboardAccessory.reservedHeight.value,
      KeyboardToolbar.heightFor(chips: true),
    );

    await tester.enterText(find.byType(TextField), 'revisar pgbouncer');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _ready(tester);

    final rows = await tester.runAsync(() => db.select(db.tasks).get());
    expect(rows!.single.title, 'revisar pgbouncer');
    expect(rows.single.projectId, project);
    expect(find.text('[ INFRA PERSONAL ]'), findsNothing);
    expect(find.text('[ DROPS ]'), findsNothing);

    await unmount(tester);
  });

  testWidgets('the x on the target chip goes back to DROPS', (tester) async {
    await projects.create(name: 'Infra personal');

    await tester.pumpWidget(host());
    await _ready(tester);
    await tester.tap(find.byType(TextField));
    await _ready(tester);
    await tester.tap(_glyph(ToolbarGlyph.more));
    await _ready(tester);
    await tester.tap(_glyph(ToolbarGlyph.target));
    await _ready(tester);
    await tester.tap(find.text('INFRA PERSONAL'));
    await _ready(tester);
    expect(find.text('[ INFRA PERSONAL ]'), findsOneWidget);

    await tester.tap(find.text('[ INFRA PERSONAL ]'));
    await _ready(tester);

    expect(find.text('[ INFRA PERSONAL ]'), findsNothing);
    expect(find.text('[ DROPS ]'), findsNothing);

    await tester.enterText(find.byType(TextField), 'sin proyecto');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _ready(tester);

    final rows = await tester.runAsync(() => db.select(db.tasks).get());
    expect(rows!.single.projectId, isNull);

    await unmount(tester);
  });

  testWidgets('submitting closes the form instead of holding the keyboard', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await _ready(tester);
    await tester.tap(find.byType(TextField));
    await _ready(tester);
    expect(find.byType(KeyboardToolbar), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'cerrar el form');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _ready(tester);

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    expect(find.byType(KeyboardToolbar), findsNothing);
    expect(KeyboardAccessory.reservedHeight.value, 0);
    expect(tester.testTextInput.isVisible, isFalse);

    final rows = await tester.runAsync(() => db.select(db.tasks).get());
    expect(rows!.single.title, 'cerrar el form');

    await unmount(tester);
  });

  testWidgets('a URL typed into the line stays text and files nothing', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await _ready(tester);

    await tester.enterText(find.byType(TextField), 'revisar https://min.io');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _ready(tester);

    final tasks = await tester.runAsync(() => db.select(db.tasks).get());
    final links = await tester.runAsync(() => db.select(db.attachments).get());
    expect(tasks!.single.title, 'revisar https://min.io');
    expect(links, isEmpty);

    await unmount(tester);
  });

  testWidgets(
    'a line that is only a URL is titled by it and attaches nothing',
    (tester) async {
      await tester.pumpWidget(host());
      await _ready(tester);

      await tester.enterText(find.byType(TextField), 'https://min.io');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await _ready(tester);

      final tasks = await tester.runAsync(() => db.select(db.tasks).get());
      final links = await tester.runAsync(
        () => db.select(db.attachments).get(),
      );
      expect(tasks!.single.title, 'https://min.io');
      expect(links, isEmpty);

      await unmount(tester);
    },
  );

  testWidgets('a goal target names its project in the chip', (tester) async {
    final project = await projects.create(name: 'Rommy');
    await goals.create(projectId: project, title: 'Ship MVP');

    await tester.pumpWidget(host());
    await _ready(tester);
    await tester.tap(find.byType(TextField));
    await _ready(tester);
    await tester.tap(_glyph(ToolbarGlyph.more));
    await _ready(tester);
    await tester.tap(_glyph(ToolbarGlyph.target));
    await _ready(tester);
    await tester.tap(find.text('Ship MVP'));
    await _ready(tester);

    expect(find.text('[ ROMMY / SHIP MVP ]'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('the capture line grows to the cap and stops there', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await _ready(tester);

    final one = tester.getSize(_capture).height;

    await tester.enterText(_capture, List.filled(6, 'x').join('\n'));
    await tester.pump();
    final six = tester.getSize(_capture).height;

    await tester.enterText(_capture, List.filled(12, 'x').join('\n'));
    await tester.pump();

    expect(six, greaterThan(one));
    expect(tester.getSize(_capture).height, six);

    await unmount(tester);
  });

  testWidgets('the newline glyph breaks the line the keyboard commits', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await _ready(tester);
    await tester.tap(find.byType(TextField));
    await _ready(tester);

    final field = tester.widget<TextField>(_capture);
    expect(field.maxLines, DazzleField.bodyLines);
    expect(field.textInputAction, TextInputAction.done);

    await tester.enterText(_capture, 'revisar pgbouncer');
    await tester.tap(_glyph(ToolbarGlyph.newline));
    await _ready(tester);

    expect(
      tester.widget<TextField>(_capture).controller!.text,
      'revisar pgbouncer\n',
    );

    await unmount(tester);
  });

  testWidgets('the link glyph raises its own line and leaves the capture', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await _ready(tester);
    await tester.tap(find.byType(TextField));
    await _ready(tester);

    await tester.enterText(find.byType(TextField), 'revisar pgbouncer');
    await tester.tap(_glyph(ToolbarGlyph.link));
    await _ready(tester);

    expect(_line, findsOneWidget);
    expect(find.text('LINK'), findsOneWidget);
    expect(find.text('https://'), findsOneWidget);
    expect(
      tester.widget<TextField>(_capture).controller!.text,
      'revisar pgbouncer',
    );
    expect(
      KeyboardAccessory.reservedHeight.value,
      KeyboardToolbar.heightFor(chips: false, field: true),
    );

    await tester.enterText(_line, 'min.io/docs');
    await _ready(tester);
    await tester.tap(find.text('ATTACH'));
    await _ready(tester);

    expect(_line, findsNothing);
    expect(find.text('[ min.io ]'), findsOneWidget);
    expect(
      tester.widget<TextField>(_capture).controller!.text,
      'revisar pgbouncer',
    );

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _ready(tester);

    final tasks = await tester.runAsync(() => db.select(db.tasks).get());
    final links = await tester.runAsync(() => db.select(db.attachments).get());
    expect(tasks!.single.title, 'revisar pgbouncer');
    expect(links!.single.value, 'https://min.io/docs');

    await unmount(tester);
  });

  testWidgets('a clipboard URL arrives in the line and waits there', (
    tester,
  ) async {
    stubClipboard('https://garagehq.deuxfleurs.fr');

    await tester.pumpWidget(host());
    await _ready(tester);
    await tester.tap(find.byType(TextField));
    await _ready(tester);

    await tester.enterText(find.byType(TextField), 'object storage');
    await tester.tap(_glyph(ToolbarGlyph.link));
    await _ready(tester);

    expect(
      tester.widget<TextField>(_line).controller!.text,
      'https://garagehq.deuxfleurs.fr',
    );
    expect(find.text('[ garagehq.deuxfleurs.fr ]'), findsNothing);

    await tester.tap(find.text('ATTACH'));
    await _ready(tester);

    expect(find.text('[ garagehq.deuxfleurs.fr ]'), findsOneWidget);

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _ready(tester);

    final links = await tester.runAsync(() => db.select(db.attachments).get());
    expect(links!.single.value, 'https://garagehq.deuxfleurs.fr');

    await unmount(tester);
  });

  testWidgets('ATTACH is inert until the line reads as a URL', (tester) async {
    await tester.pumpWidget(host());
    await _ready(tester);
    await tester.tap(find.byType(TextField));
    await _ready(tester);
    await tester.tap(_glyph(ToolbarGlyph.link));
    await _ready(tester);

    await tester.enterText(_line, 'esto no es un link');
    await _ready(tester);

    final blocked = tester.widget<ActionBlock>(find.byType(ActionBlock));
    expect(blocked.onTap, isNull);
    expect(blocked.tone, DazzleColors.textDisabled);

    await tester.tap(find.text('ATTACH'));
    await _ready(tester);
    expect(_line, findsOneWidget);
    expect(
      tester.widget<TextField>(_line).controller!.text,
      'esto no es un link',
    );

    await tester.enterText(_line, 'min.io');
    await _ready(tester);
    expect(
      tester.widget<ActionBlock>(find.byType(ActionBlock)).tone,
      DazzleColors.accent,
    );

    await unmount(tester);
  });

  testWidgets('the x takes the line down and attaches nothing', (tester) async {
    stubClipboard('https://min.io');

    await tester.pumpWidget(host());
    await _ready(tester);
    await tester.tap(find.byType(TextField));
    await _ready(tester);
    await tester.enterText(find.byType(TextField), 'revisar pgbouncer');
    await tester.tap(_glyph(ToolbarGlyph.link));
    await _ready(tester);
    expect(_line, findsOneWidget);

    await tester.tap(find.byIcon(Icons.close));
    await _ready(tester);

    expect(_line, findsNothing);
    expect(find.text('[ min.io ]'), findsNothing);
    expect(
      tester.widget<TextField>(_capture).controller!.text,
      'revisar pgbouncer',
    );
    expect(
      KeyboardAccessory.reservedHeight.value,
      KeyboardToolbar.heightFor(chips: false),
    );

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _ready(tester);

    final links = await tester.runAsync(() => db.select(db.attachments).get());
    expect(links, isEmpty);

    await unmount(tester);
  });

  testWidgets('the scrim takes the line down with the keyboard', (
    tester,
  ) async {
    stubClipboard('https://min.io');

    await tester.pumpWidget(host());
    await _ready(tester);
    await tester.tap(find.byType(TextField));
    await _ready(tester);
    await tester.enterText(find.byType(TextField), 'revisar pgbouncer');
    await tester.tap(_glyph(ToolbarGlyph.link));
    await _ready(tester);
    expect(_line, findsOneWidget);

    await tester.tapAt(const Offset(10, 10));
    await _ready(tester);

    expect(find.byType(KeyboardToolbar), findsNothing);
    expect(KeyboardAccessory.reservedHeight.value, 0);
    expect(tester.testTextInput.isVisible, isFalse);
    expect(find.text('[ min.io ]'), findsNothing);

    await unmount(tester);
  });

  testWidgets('the field paints the URL in the line, and only it', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await _ready(tester);
    await tester.tap(find.byType(TextField));
    await _ready(tester);

    await tester.enterText(
      find.byType(TextField),
      'mirar https://min.io/docs manana',
    );
    await _ready(tester);

    final painted = _spans(tester);
    expect(painted.where((span) => span.$2).map((span) => span.$1), [
      'https://min.io/docs',
    ]);
    expect(
      painted.map((span) => span.$1).join(),
      'mirar https://min.io/docs manana',
    );

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _ready(tester);
    final rows = await tester.runAsync(() => db.select(db.attachments).get());
    expect(rows, isEmpty);
    final items = await tester.runAsync(() => db.select(db.tasks).get());
    expect(items!.single.title, 'mirar https://min.io/docs manana');

    await unmount(tester);
  });

  testWidgets('a field with no URL in it is painted flat', (tester) async {
    await tester.pumpWidget(host());
    await _ready(tester);
    await tester.tap(find.byType(TextField));
    await _ready(tester);

    await tester.enterText(find.byType(TextField), 'revisar pgbouncer.conf');
    await _ready(tester);

    expect(_spans(tester).any((span) => span.$2), isFalse);

    await unmount(tester);
  });
}

/// The editable's span is the only place the mark exists — a style on a range, not a
/// widget anyone can find.
List<(String, bool)> _spans(WidgetTester tester) {
  final span = tester
      .widget<EditableText>(find.byType(EditableText))
      .controller
      .buildTextSpan(
        context: tester.element(find.byType(EditableText)),
        style: const TextStyle(),
        withComposing: false,
      );
  final out = <(String, bool)>[];
  span.visitChildren((child) {
    final piece = child as TextSpan;
    if (piece.text != null) {
      out.add((piece.text!, piece.style?.backgroundColor != null));
    }
    return true;
  });
  if (out.isEmpty && span.text != null) out.add((span.text!, false));
  return out;
}
