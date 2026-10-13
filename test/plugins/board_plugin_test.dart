import 'dart:io';

import 'package:upgrade/platform/plugins/bindings.dart';
import 'package:upgrade/platform/plugins/manifest.dart';
import 'package:upgrade/platform/plugins/store.dart';
import 'package:upgrade/platform/plugins/ui.dart';
import 'package:upgrade_luau/data_api.dart';
import 'package:upgrade_luau/upgrade_luau.dart';
import 'package:upgrade_luau/ui_sdk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';

import '../support/themed_app.dart';

PluginPackage boardPackage() => PluginPackage(
  manifest: PluginManifest.parse(
    File('plugins/board/upgrade.plugin.toml').readAsStringSync(),
  ),
  source: File('plugins/board/main.luau').readAsStringSync(),
  origin: 'bundled:upgrade.board',
  revision: '1.0.0',
);

class BoardHarness {
  BoardHarness(this.worker, this.package);
  final LuauWorker worker;
  final PluginPackage package;
  Map<String, Object?>? state;
  String? back;
  late PluginUiNode view;
  Future<void> send(Map<String, Object?> event) async {
    final plugin = InstalledPlugin(package, package.manifest.permissions);
    final result = await worker.invoke(
      key: package.digest,
      source: '$luauUiSdk\n${package.source}',
      action: 'frame',
      input: {
        'state': state,
        'event': {'token': 'seed', 'now': '2026-09-17T12:00:00', ...event},
      },
      data: bindPluginData(plugin.id, [plugin]),
    );
    final response = result.value! as Map<String, Object?>;
    state = response['state']! as Map<String, Object?>;
    back = response['back'] as String?;
    view = PluginUiNode.parse(response['view'], allowCanvas: true);
  }

  Future<void> action(String id, [Map<String, Object?> event = const {}]) =>
      send({'type': 'action', 'id': id, ...event});
  Future<void> tool(String name) => action('tool', {
    'args': {'tool': name},
  });
  Future<void> tap(double x, double y, String token) => action('tap', {
    'token': token,
    'position': {'x': x, 'y': y},
  });
}

Iterable<PluginUiNode> walk(PluginUiNode node) sync* {
  yield node;
  for (final child in node.children) {
    yield* walk(child);
  }
}

List<String> texts(PluginUiNode node) => [
  for (final entry in walk(node))
    if (entry.kind == 'text') entry.props['text'] as String? ?? '',
];

PluginUiNode surface(PluginUiNode node) =>
    walk(node).firstWhere((entry) => entry.kind == 'canvas');

List<Map<String, Object?>> commands(PluginUiNode node) => [
  for (final command in uiList(surface(node).props['commands']))
    command! as Map<String, Object?>,
];

List<Map<String, Object?>> links(PluginUiNode node) => [
  for (final command in commands(node))
    if (command['op'] == 'line' && command['color'] == 'accent') command,
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late LuauWorker worker;
  late BoardHarness app;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('upgrade-board-');
    worker = LuauWorker(dataDirectory: root.path);
    app = BoardHarness(worker, boardPackage());
  });
  tearDown(() async {
    await worker.close();
    await root.delete(recursive: true);
  });
  Future<void> opened() async {
    await app.send({'type': 'mount'});
    await app.action('new_board');
  }

  test('bundled release owns its data and asks for no host service', () async {
    final manifest = app.package.manifest;
    expect(manifest.formatVersion, 5);
    expect(manifest.uiVersion, 2);
    expect(manifest.dependencies, isEmpty);
    expect(manifest.hostCapabilities, isEmpty);
    expect(manifest.capabilities['boards']!.dataset, 'boards');
    expect(manifest.capabilities['boards']!.operations, {
      DataOperation.get,
      DataOperation.query,
      DataOperation.put,
      DataOperation.delete,
    });
    expect(manifest.datasets['boards']!.schemaVersion, 1);
    final store = PluginStore(root);
    expect(
      (await store.synchronizeBuiltins([
        app.package,
      ], adoptEnabled: true)).single.enabled,
      isFalse,
    );
    await store.setEnabled(manifest.id, true);
    await expectLater(
      store.remove(manifest.id),
      throwsA(isA<PluginException>()),
    );
  });

  test(
    'a note lands where the board was tapped and survives a reopen',
    () async {
      await opened();
      await app.tool('note');
      await app.tap(160, 720, 'note1');
      final placed = commands(app.view).where((c) => c['op'] == 'text').single;
      expect(placed['y'], 720 - 64 / 2 + 8);
      expect(surface(app.view).props['height'], greaterThan(720));
      await app.action('boards');
      final boardId = app.state!['boardId'];
      await app.action('open_board', {
        'args': {'id': boardId},
      });
      final reopened = commands(app.view)
          .where((c) => c['op'] == 'text')
          .single;
      expect(reopened['y'], placed['y']);
      expect(texts(app.view), contains('BOARD 1 / 1 NOTES / 0 LINKS'));
    },
  );

  test('select, edit, link and erase run through the same tap', () async {
    await opened();
    await app.tool('note');
    await app.tap(80, 100, 'note1');
    await app.tap(80, 400, 'note2');
    await app.tool('select');
    await app.tap(80, 110, 'pick');
    expect(app.state!['selected'], 'note1');
    await app.send({
      'type': 'action',
      'id': 'save_note',
      'fields': {'note': 'ROUTINE'},
    });
    expect(commands(app.view).any((c) => c['text'] == 'ROUTINE'), isTrue);
    await app.tool('link');
    await app.tap(80, 110, 'a');
    await app.tap(80, 410, 'link1');
    expect(links(app.view), hasLength(1));
    expect(texts(app.view), contains('BOARD 1 / 2 NOTES / 1 LINKS'));
    await app.tool('move');
    await app.tool('select');
    await app.tap(80, 110, 'pick2');
    await app.tool('move');
    await app.tap(200, 900, 'moved');
    final moved = commands(app.view).where((c) => c['op'] == 'text').first;
    expect(moved['y'], 900 - 64 / 2 + 8);
    await app.tool('erase');
    await app.tap(200, 910, 'gone');
    expect(links(app.view), isEmpty);
    expect(texts(app.view), contains('BOARD 1 / 1 NOTES / 0 LINKS'));
  });

  test('a board is renamed and keeps the name it was given', () async {
    await opened();
    await app.action('boards');
    final boardId = app.state!['boardId']! as String;
    await app.send({
      'type': 'action',
      'id': 'rename_board',
      'args': {'id': boardId},
      'fields': {'bn_$boardId': 'ROUTES'},
    });
    await app.action('open_board', {
      'args': {'id': boardId},
    });
    expect(texts(app.view), contains('ROUTES / 0 NOTES / 0 LINKS'));
    await app.send({
      'type': 'action',
      'id': 'rename_board',
      'args': {'id': boardId},
      'fields': {'bn_$boardId': ''},
    });
    expect(
      texts(app.view),
      contains('A board keeps its name until a new one is typed.'),
    );
    await app.action('boards');
    await app.action('open_board', {
      'args': {'id': boardId},
    });
    expect(texts(app.view), contains('ROUTES / 0 NOTES / 0 LINKS'));
  });

  test('the board keeps its place when a note is selected', () async {
    await opened();
    await app.tool('note');
    await app.tap(80, 300, 'note1');
    final placed = surface(app.view).props['height'];
    await app.tool('select');
    await app.tap(4000, 4000, 'nothing');
    expect(app.state!['selected'], '');
    expect(surface(app.view).props['height'], placed);
    expect(
      walk(app.view).where((entry) => entry.kind == 'input').map((e) => e.key),
      isEmpty,
    );
  });

  test(
    'canvas fills the viewport and editor appears only for selection',
    () async {
      await opened();
      expect(surface(app.view).props['interactive'], isTrue);
      expect(surface(app.view).props['flex'], 1);
      expect(surface(app.view).props['width'], 4096);
      expect(app.back, 'boards');
      expect(walk(app.view).where((entry) => entry.kind == 'input'), isEmpty);
      await app.tool('note');
      await app.tap(800, 100, 'wide-note');
      expect(app.back, 'close_note');
      final drawn = commands(app.view)
          .firstWhere((entry) => entry['op'] == 'text');
      expect(drawn['x'], 800 - 132 / 2 + 8);
      expect(
        walk(app.view).where((entry) => entry.key == 'note_wide-note'),
        hasLength(1),
      );
      final secondary = walk(app.view)
          .firstWhere((entry) => entry.key == 'note_more');
      expect(secondary.kind, 'disclosure');
      expect(walk(secondary).any((entry) => entry.key == 'erase_note'), isTrue);
      await app.action('close_note');
      expect(app.state!['selected'], '');
      expect(app.state!['tool'], 'select');
      expect(app.back, 'boards');
      expect(walk(app.view).where((entry) => entry.kind == 'input'), isEmpty);
    },
  );

  test('each note has its own editor field and saved text', () async {
    await opened();
    await app.tool('note');
    await app.tap(80, 100, 'first');
    await app.action('save_note', {
      'fields': {'note_first': 'First note'},
    });
    await app.tap(240, 100, 'second');
    expect(
      walk(app.view).where((entry) => entry.kind == 'input').single.key,
      'note_second',
    );
    await app.action('save_note', {
      'fields': {'note_first': 'First note', 'note_second': 'Second note'},
    });
    expect(
      commands(app.view)
          .where((entry) => entry['op'] == 'text')
          .map((entry) => entry['text']),
      ['First note', 'Second note'],
    );
  });

  test(
    'closing and changing selection retain drafts without saving them',
    () async {
      await opened();
      await app.tool('note');
      await app.tap(80, 100, 'first');
      await app.action('tap', {
        'token': 'second',
        'position': {'x': 240, 'y': 100},
        'fields': {'note_first': 'First draft'},
      });
      await app.action('close_note', {
        'fields': {'note_second': 'Second draft'},
      });
      await app.tap(80, 100, 'select-first');
      expect(
        walk(app.view)
            .where((entry) => entry.kind == 'input')
            .single
            .props['value'],
        'First draft',
      );
      await app.action('boards', {
        'fields': {'note_first': 'Revised first draft'},
      });
      await app.action('open_board', {
        'args': {'id': app.state!['boardId']},
      });
      expect(
        commands(app.view)
            .where((entry) => entry['op'] == 'text')
            .map((entry) => entry['text']),
        ['EMPTY', 'EMPTY'],
      );
      await app.tap(80, 100, 'select-first-again');
      expect(
        walk(app.view)
            .where((entry) => entry.kind == 'input')
            .single
            .props['value'],
        'Revised first draft',
      );
      await app.tap(240, 100, 'select-second');
      expect(
        walk(app.view)
            .where((entry) => entry.kind == 'input')
            .single
            .props['value'],
        'Second draft',
      );
      await app.action('save_note', {
        'fields': {'note_second': 'Second saved'},
      });
      expect((app.state!['drafts']! as Map<String, Object?>).values, [
        'Revised first draft',
      ]);
      await app.tap(80, 100, 'select-first-delete');
      await app.action('erase_note');
      expect(app.state!['drafts'], isEmpty);
    },
  );

  testWidgets(
    'interactive canvas fills narrow and wide viewports and preserves tap coordinates',
    (tester) async {
      for (final width in [360.0, 850.0]) {
        await tester.binding.setSurfaceSize(Size(width, 800));
        final events = <Map<String, Object?>>[];
        const canvas = PluginUiNode('canvas', {
          'key': 'board',
          'width': 4096,
          'height': 1200,
          'interactive': true,
          'flex': 1,
          'onPress': 'tap',
          'commands': <Object?>[],
        }, []);
        await tester.pumpWidget(
          MaterialApp(
            theme: testTheme,
            home: Scaffold(
              body: PluginUi(
                node: const PluginUiNode(
                  'screen',
                  {'key': 'screen', 'padding': 16},
                  [canvas],
                ),
                values: {},
                busy: false,
                onEvent: events.add,
              ),
            ),
          ),
        );
        expect(tester.takeException(), isNull);
        final viewport = find.byType(InteractiveViewer);
        expect(tester.getSize(viewport).width, width - 32);
        final origin = tester.getTopLeft(viewport);
        await tester.tapAt(origin + const Offset(100, 100));
        expect(events.single['position'], {'x': 100.0, 'y': 100.0});
        events.clear();
        await tester.drag(viewport, const Offset(-80, -120));
        await tester.pumpAndSettle();
        await tester.tapAt(origin + const Offset(100, 100));
        final position = events.single['position']! as Map<String, Object?>;
        expect(position['x'], greaterThan(100));
        expect(position['y'], greaterThan(100));
        await tester.pumpWidget(const SizedBox.shrink());
      }
      await tester.binding.setSurfaceSize(null);
    },
  );

  test('moving with nothing selected explains itself', () async {
    await opened();
    await app.tool('move');
    await app.tap(40, 40, 'nothing');
    expect(texts(app.view), contains('Select a note before moving it.'));
  });

  test('a filled board refuses the next note instead of dropping it', () async {
    await opened();
    await app.tool('note');
    for (var index = 0; index < 60; index++) {
      await app.tap(40 + (index % 2) * 140, 40 + index * 8, 'note$index');
    }
    expect(texts(app.view), contains('BOARD 1 / 60 NOTES / 0 LINKS'));
    await app.tap(40, 200, 'overflow');
    expect(texts(app.view), contains('This board holds no more notes.'));
    expect(texts(app.view), contains('BOARD 1 / 60 NOTES / 0 LINKS'));
    expect(commands(app.view).length, lessThanOrEqualTo(256));
  });

  test('a note breaks its lines between words, not inside them', () async {
    await opened();
    await app.tool('note');
    await app.tap(80, 300, 'note1');
    await app.send({
      'type': 'action',
      'id': 'save_note',
      'fields': {'note': 'Ship the board plugin to faraday'},
    });
    final drawn =
        commands(app.view).firstWhere((c) => c['op'] == 'text')['text']!
            as String;
    expect(drawn.split('\n'), ['Ship the board', 'plugin to faraday']);
    await app.send({
      'type': 'action',
      'id': 'save_note',
      'fields': {
        'note': 'unbreakablewordthatrunspastthenote and then some more words',
      },
    });
    final cut =
        commands(app.view).firstWhere((c) => c['op'] == 'text')['text']!
            as String;
    expect(cut.split('\n').first, 'unbreakablewordth');
    expect(cut, endsWith('…'));
  });

  test('the board is drawn under whatever is put on it', () async {
    await opened();
    final ground = commands(app.view).first;
    expect(ground['op'], 'rect');
    expect(ground['color'], 'surface');
    expect(ground['width'], surface(app.view).props['width']);
    expect(ground['height'], surface(app.view).props['height']);
    final rules = commands(app.view).where((c) => c['color'] == 'border');
    expect(rules, isNotEmpty);
    expect(rules.every((c) => c['op'] == 'line'), isTrue);
  });
}
