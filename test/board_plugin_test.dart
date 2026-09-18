import 'dart:io';

import 'package:dazzle/platform/plugins/bindings.dart';
import 'package:dazzle/platform/plugins/manifest.dart';
import 'package:dazzle/platform/plugins/store.dart';
import 'package:dazzle/platform/plugins/ui.dart';
import 'package:dazzle_luau/data_api.dart';
import 'package:dazzle_luau/dazzle_luau.dart';
import 'package:dazzle_luau/ui_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

PluginPackage boardPackage() => PluginPackage(
  manifest: PluginManifest.parse(
    File('plugins/board/dazzle.plugin.toml').readAsStringSync(),
  ),
  source: File('plugins/board/main.luau').readAsStringSync(),
  origin: 'bundled:dazzle.board',
  revision: '1.0.0',
);

class BoardHarness {
  BoardHarness(this.worker, this.package);
  final LuauWorker worker;
  final PluginPackage package;
  Map<String, Object?>? state;
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late LuauWorker worker;
  late BoardHarness app;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('dazzle-board-');
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
      expect(texts(app.view), contains('1 NOTES / 0 LINKS'));
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
    expect(commands(app.view).any((c) => c['op'] == 'line'), isTrue);
    expect(texts(app.view), contains('2 NOTES / 1 LINKS'));
    await app.tool('move');
    await app.tool('select');
    await app.tap(80, 110, 'pick2');
    await app.tool('move');
    await app.tap(200, 900, 'moved');
    final moved = commands(app.view).where((c) => c['op'] == 'text').first;
    expect(moved['y'], 900 - 64 / 2 + 8);
    await app.tool('erase');
    await app.tap(200, 910, 'gone');
    expect(commands(app.view).any((c) => c['op'] == 'line'), isFalse);
    expect(texts(app.view), contains('1 NOTES / 0 LINKS'));
  });

  test('moving with nothing selected explains itself', () async {
    await opened();
    await app.tool('move');
    await app.tap(40, 40, 'nothing');
    expect(texts(app.view), contains('Select a note before moving it.'));
  });

  test('a filled board refuses the next note instead of dropping it', () async {
    await opened();
    await app.tool('note');
    for (var index = 0; index < 70; index++) {
      await app.tap(40 + (index % 2) * 140, 40 + index * 8, 'note$index');
    }
    expect(texts(app.view), contains('70 NOTES / 0 LINKS'));
    await app.tap(40, 200, 'overflow');
    expect(texts(app.view), contains('This board holds no more notes.'));
    expect(texts(app.view), contains('70 NOTES / 0 LINKS'));
    expect(commands(app.view).length, lessThanOrEqualTo(256));
  });
}
