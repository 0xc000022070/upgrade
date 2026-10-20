import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:striked/platform/plugins/bindings.dart';
import 'package:striked/platform/plugins/manifest.dart';
import 'package:striked/platform/plugins/store.dart';
import 'package:striked/platform/plugins/ui.dart';
import 'package:striked_luau/striked_luau.dart';
import 'package:striked_luau/ui_sdk.dart';

PluginPackage kanbanPackage() => PluginPackage(
  manifest: PluginManifest.parse(
    File('plugins/kanban/striked.plugin.toml').readAsStringSync(),
  ),
  source: File('plugins/kanban/main.luau').readAsStringSync(),
  origin: 'bundled:striked.kanban',
  revision: '1.0.0',
);

class KanbanHarness {
  KanbanHarness(this.worker, this.package);
  final LuauWorker worker;
  final PluginPackage package;
  Map<String, Object?>? state;
  late PluginUiNode view;
  late Map<String, Object?> raw;
  List<Map<String, Object?>> effects = const [];

  Future<void> send(Map<String, Object?> event, {String? widget}) async {
    final plugin = InstalledPlugin(package, package.manifest.permissions);
    final result = await worker.invoke(
      key: package.digest,
      source: '$luauUiSdk\n${package.source}',
      action: widget == null ? 'frame' : 'card',
      input: {
        'state': state,
        'widget': ?widget,
        'event': {'token': 'seed', ...event},
      },
      data: bindPluginData(plugin.id, [plugin]),
    );
    final response = result.value! as Map<String, Object?>;
    state = response['state']! as Map<String, Object?>;
    raw = response['view']! as Map<String, Object?>;
    effects = [
      for (final effect in uiList(response['effects']))
        effect! as Map<String, Object?>,
    ];
    view = PluginUiNode.parse(
      raw,
      allowCanvas: false,
      card: widget != null,
      allowAwake: true,
      pages: const {'main'},
    );
  }

  Future<void> listed(Map<String, Object?> value, {String? widget}) => send({
    'type': 'result',
    'id': 'list',
    'ok': true,
    'value': value,
  }, widget: widget);

  Future<void> action(
    String id, {
    Object? value,
    Map<String, Object?>? args,
    Map<String, Object?> fields = const {},
    String? widget,
  }) => send({
    'type': 'action',
    'id': id,
    'value': ?value,
    'args': ?args,
    'fields': fields,
  }, widget: widget);
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

PluginUiNode keyed(PluginUiNode node, String key) =>
    walk(node).firstWhere((entry) => entry.key == key);

List<String> lanes(PluginUiNode node) => [
  for (final lane in keyed(node, 'board').children)
    lane.children.first.children.first.children.first.props['text']! as String,
];

List<String> lane(PluginUiNode node, String id) => [
  for (final card in keyed(node, 'l_${id}cards').children)
    if (card.kind == 'box') card.props['key']! as String,
];

Map<String, Object?> item(
  String id,
  String state, {
  String host = 'h1',
  String hostName = 'nyx',
  String agent = 'claude',
  String title = '',
  String workspace = 'striked',
  String message = '',
  Map<String, Object?>? approval,
}) => {
  'id': id,
  'host': host,
  'host_name': hostName,
  'agent': agent,
  'state': state,
  'title': title,
  'workspace': workspace,
  'directory': '/home/dev/$workspace',
  'question': '',
  'message': message,
  'source': 'engine',
  'seq': 1,
  'approval': ?approval,
};

final feed = <String, Object?>{
  'ready': true,
  'hosts': [
    {'id': 'h1', 'name': 'nyx', 'ok': true, 'read_ago': 4},
    {'id': 'h2', 'name': 'rose', 'ok': true, 'read_ago': 75},
    {'id': 'h3', 'name': 'faraday', 'ok': false, 'reason': 'unreachable'},
  ],
  'items': [
    item('a', 'working', title: 'refactor parser'),
    item(
      'b',
      'blocked',
      title: 'deploy',
      approval: {'id': 'ap1', 'tool': 'bash', 'line': 'bash · rm -rf build'},
    ),
    item('c', 'done', host: 'h2', hostName: 'rose', agent: 'codex'),
    {
      ...item('e', 'idle', host: 'h2', hostName: 'rose', workspace: ''),
      'directory': '/home/dev/tools/',
    },
    item(
      'd',
      'idle',
      host: 'h2',
      hostName: 'rose',
      workspace: 'fixture',
      message: 'flaky test fixed',
    ),
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late LuauWorker worker;
  late KanbanHarness app;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('striked-kanban-');
    worker = LuauWorker(dataDirectory: root.path);
    app = KanbanHarness(worker, kanbanPackage());
  });
  tearDown(() async {
    await worker.close();
    await root.delete(recursive: true);
  });

  Future<void> opened() async {
    await app.send({'type': 'mount'});
    await app.listed(feed);
  }

  test(
    'ships disabled and asks for the agents service and nothing native',
    () async {
      final manifest = kanbanPackage().manifest;
      expect(manifest.hostCapabilities['agents']!.service, 'agents');
      expect(manifest.hostCapabilities['agents']!.operations, {
        'list',
        'answer',
        'open',
      });
      expect(
        manifest.permissions.map((permission) => permission.id),
        containsAll(['ui.page', 'ui.widget', 'ui.keep_awake']),
      );
      expect(
        (await PluginStore(root).synchronizeBuiltins([
          kanbanPackage(),
        ], adoptEnabled: true)).single.enabled,
        isFalse,
      );
    },
  );

  test(
    'new sessions land in the first column of the workspace in front',
    () async {
      await app.send({'type': 'mount'});
      expect(app.effects.single, containsPair('operation', 'list'));
      await app.listed(feed);
      expect(app.view.props['fill'], isTrue);
      expect(keyed(app.view, 'board').props['direction'], 'horizontal');
      expect(lanes(app.view), ['INBOX', 'DOING', 'DONE']);
      expect(lane(app.view, '1'), ['c_a', 'c_b', 'c_c', 'c_e', 'c_d']);
      expect(texts(app.view), contains('FARADAY · unreachable'));
      expect(texts(app.view), contains('bash · rm -rf build'));
      final box = keyed(app.view, 'c_d');
      expect(box.props, containsPair('onPress', 'open'));
      expect(box.props, containsPair('drag', 'd'));
      expect(box.props, containsPair('onDrop', 'drop_card'));
      expect(box.props['args'], {'id': 'd'});
      expect(keyed(app.view, 'l_2').props['onDrop'], 'drop_column');
      expect(keyed(app.view, 'ws_1').props['background'], 'accent');
      expect(keyed(app.view, 'ws_new').props['args'], {'ws': 2});
      expect(keyed(app.view, 'ws_new').props['onDrop'], 'drop_ws');
    },
  );

  test('allow answers the approval it sits on, then reads again', () async {
    await opened();
    final allow = keyed(app.view, 'c_ballow');
    expect(allow.props['args'], {'approval': 'ap1'});
    await app.action('allow', args: {'approval': 'ap1'});
    expect(app.effects.single, {
      'capability': 'agents',
      'operation': 'answer',
      'args': {'approval': 'ap1', 'allow': true},
      'id': 'answer',
    });
    await app.send({
      'type': 'result',
      'id': 'answer',
      'ok': true,
      'value': {'answer': 'allowed'},
    });
    expect(texts(app.view), contains('ALLOWED'));
    expect(app.effects.single, containsPair('operation', 'list'));
    await app.listed(feed);
    expect(walk(app.view).where((node) => node.key == 'c_ballow'), isEmpty);
    expect(lane(app.view, '1'), contains('c_b'));
    await app.action('open', args: {'id': 'd'});
    expect(app.effects.single['args'], {'id': 'd'});
  });

  test(
    'a dropped card moves between columns and workspaces, and stays there',
    () async {
      await opened();
      await app.action('drop_column', value: 'a', args: {'col': 2});
      expect(lane(app.view, '2'), ['c_a']);
      await app.action('drop_card', value: 'c', args: {'id': 'a'});
      expect(lane(app.view, '2'), ['c_c', 'c_a']);
      await app.action('drop_card', value: 'a', args: {'id': 'a'});
      expect(lane(app.view, '2'), ['c_c', 'c_a']);
      await app.action('drop_ws', value: 'b', args: {'ws': 3});
      expect(lane(app.view, '1'), ['c_e', 'c_d']);
      expect(keyed(app.view, 'ws_3').props['color'], 'danger');
      expect(keyed(app.view, 'ws_new').props['args'], {'ws': 2});

      await app.action('ws', args: {'ws': 3});
      expect(lane(app.view, '1'), ['c_b']);
      app.state = null;
      await app.send({'type': 'mount'});
      await app.listed({
        ...feed,
        'items': [...feed['items']! as List<Object?>, item('f', 'working')],
      });
      expect(lane(app.view, '1'), ['c_b', 'c_f']);
      await app.action('ws', args: {'ws': 1});
      expect(lane(app.view, '2'), ['c_c', 'c_a']);
      expect(lane(app.view, '1'), ['c_e', 'c_d']);
    },
  );

  test('a session gone from a host that answered leaves; one on a silent host '
      'keeps its place', () async {
    final down = item('g', 'idle', host: 'h3', hostName: 'faraday');
    final items = feed['items']! as List<Object?>;
    await app.send({'type': 'mount'});
    await app.listed({
      ...feed,
      'items': [...items, down],
    });
    await app.action('drop_column', value: 'a', args: {'col': 3});
    await app.action('drop_column', value: 'g', args: {'col': 3});
    expect(lane(app.view, '3'), ['c_a', 'c_g']);
    await app.listed({...feed, 'items': items.skip(1).toList()});
    await app.listed({
      ...feed,
      'items': [...items, down],
    });
    expect(lane(app.view, '3'), ['c_g']);
    expect(lane(app.view, '1').last, 'c_a');
  });

  test(
    'each workspace has its own columns, added, renamed, moved and deleted',
    () async {
      await opened();
      await app.action('drop_column', value: 'a', args: {'col': 2});
      await app.action('add', fields: {'newcol_3': '  Review\n'});
      expect(lanes(app.view), ['INBOX', 'DOING', 'DONE', 'REVIEW']);
      expect(keyed(app.view, 'newcol_4').props['value'], isNull);
      await app.action('add', fields: {'newcol_4': ' '});
      expect(texts(app.view), contains('Name the column first'));
      await app.action('rename', value: 'Todo', args: {'col': 1});
      await app.action('right', args: {'col': 1});
      expect(lanes(app.view), ['DOING', 'TODO', 'DONE', 'REVIEW']);
      await app.action('delete', args: {'col': 2});
      expect(lanes(app.view), ['TODO', 'DONE', 'REVIEW']);
      expect(lane(app.view, '1'), ['c_b', 'c_c', 'c_e', 'c_d', 'c_a']);
      await app.action('drop_ws', value: 'c', args: {'ws': 2});
      await app.action('ws', args: {'ws': 2});
      expect(lanes(app.view), ['INBOX', 'DOING', 'DONE']);
      expect(lane(app.view, '1'), ['c_c']);

      app.state = null;
      await app.send({'type': 'mount'});
      await app.listed(feed);
      await app.action('ws', args: {'ws': 1});
      expect(lanes(app.view), ['TODO', 'DONE', 'REVIEW']);
    },
  );

  test('the search narrows the board and is not remembered', () async {
    await opened();
    await app.action('search', value: 'PARSER');
    expect(lane(app.view, '1'), ['c_a']);
    await app.action('awake', value: true);
    expect(app.view.props['awake'], isTrue);
    app.state = null;
    await opened();
    expect(app.view.props['awake'], isTrue);
    expect(keyed(app.view, 'search').props['value'], '');
    expect(lane(app.view, '1'), hasLength(5));
    expect(
      () => PluginUiNode.parse(app.raw, allowCanvas: false, pages: {'main'}),
      throwsA(isA<PluginException>()),
    );
  });

  test('the Home card is the workspace in front as a small board', () async {
    await opened();
    await app.action('drop_column', value: 'a', args: {'col': 2});
    app.state = null;
    await app.send({'type': 'mount', 'widget': 'inbox'}, widget: 'inbox');
    expect(app.effects.single, containsPair('operation', 'list'));
    await app.listed(feed, widget: 'inbox');
    expect(app.view.props['title'], 'AGENTS · WORKSPACE 1');
    expect(texts(app.view), containsAll(['INBOX 4', 'DOING 1', 'DONE 0']));
    expect(keyed(app.view, 'm_2_a').props['onPress'], 'open');
    expect(keyed(app.view, 'm_2_a').props['args'], {'id': 'a'});
    expect(keyed(app.view, 'm_1_bt').props['color'], 'danger');
    expect(keyed(app.view, 'a_ballow').props['args'], {'approval': 'ap1'});
    expect(keyed(app.view, 'open_board').props['opens'], 'main');
    expect(walk(app.view).where((node) => node.props['drag'] != null), isEmpty);
    await app.action('deny', args: {'approval': 'ap1'}, widget: 'inbox');
    expect(app.effects.single['args'], {'approval': 'ap1', 'allow': false});
    await app.action('ws', args: {'ws': 2}, widget: 'inbox');
    expect(app.view.props['title'], 'AGENTS · WORKSPACE 2');
    expect(texts(app.view), contains('INBOX 0'));
  });
}
