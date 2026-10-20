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
    'columns by status hold their sessions and the failing host says so',
    () async {
      await app.send({'type': 'mount'});
      expect(app.effects.single, containsPair('operation', 'list'));
      await app.listed(feed);
      expect(app.view.props['fill'], isTrue);
      expect(keyed(app.view, 'board').props['direction'], 'horizontal');
      expect(lanes(app.view), ['BLOCKED', 'WORKING', 'DONE', 'IDLE']);
      expect(lane(app.view, 'blocked'), ['c_b']);
      expect(lane(app.view, 'idle'), ['c_d', 'c_e']);
      expect(texts(app.view), contains('FARADAY · unreachable'));
      expect(texts(app.view), contains('bash · rm -rf build'));
      final box = keyed(app.view, 'c_d');
      expect(box.props['onPress'], 'open');
      expect(box.props['args'], {'id': 'd'});
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
    expect(lane(app.view, 'blocked'), ['c_b']);
    await app.action('open', args: {'id': 'd'});
    expect(app.effects.single['args'], {'id': 'd'});
  });

  test('grouping and filters are remembered; the search is not', () async {
    await opened();
    await app.action('group', args: {'group': 'machine'});
    expect(lanes(app.view), ['NYX', 'ROSE', 'FARADAY']);
    expect([
      for (final host in ['h1', 'h2', 'h3'])
        keyed(app.view, 'l_${host}head').props['border'],
    ], [null, null, 'danger']);
    await app.action('group', args: {'group': 'workspace'});
    expect(lanes(app.view), ['fixture', 'striked', 'tools']);
    await app.action('filter_agent', value: 'claude');
    expect(lane(app.view, 'striked'), ['c_b', 'c_a']);
    await app.action('search', value: 'PARSER');
    expect(lanes(app.view), ['striked']);
    expect(lane(app.view, 'striked'), ['c_a']);
    await app.action('awake', value: true);
    expect(app.view.props['awake'], isTrue);

    app.state = null;
    await opened();
    expect(lanes(app.view), ['fixture', 'striked', 'tools']);
    expect(lane(app.view, 'striked'), ['c_b', 'c_a']);
    expect(app.view.props['awake'], isTrue);
    expect(keyed(app.view, 'search').props['value'], '');
    expect(
      () => PluginUiNode.parse(app.raw, allowCanvas: false, pages: {'main'}),
      throwsA(isA<PluginException>()),
    );
  });

  test(
    'the Home card counts, puts blocked first and opens the board',
    () async {
      await app.send({'type': 'mount', 'widget': 'inbox'}, widget: 'inbox');
      expect(app.effects.single, containsPair('operation', 'list'));
      await app.listed(feed, widget: 'inbox');
      final counts = keyed(app.view, 'counts').children;
      expect(counts.map((label) => label.props['value']), ['1', '1', '1']);
      expect(keyed(app.view, 'b_b').props['onPress'], 'open');
      expect(keyed(app.view, 'b_ballow').props['args'], {'approval': 'ap1'});
      expect(texts(app.view), contains('READ 4s AGO'));
      expect(keyed(app.view, 'open_board').props['opens'], 'main');
      await app.action('deny', args: {'approval': 'ap1'}, widget: 'inbox');
      expect(app.effects.single['args'], {'approval': 'ap1', 'allow': false});
    },
  );
}
