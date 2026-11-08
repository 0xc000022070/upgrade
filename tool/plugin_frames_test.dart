import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/features/plugins/plugin_ui.dart';
import 'package:upgrade_luau/upgrade_luau.dart';

import '../test/support/plugin_packages.dart';
import '../test/plugins/agent_schedules_plugin_test.dart' as schedules;
import '../test/plugins/board_plugin_test.dart' as board;
import '../test/plugins/kanban_plugin_test.dart' as kanban;

final _out = Directory('widgetbook/frames/plugins');
final _index = <Map<String, Object?>>[];

Map<String, Object?> _tree(PluginUiNode node) => {
  'kind': node.kind,
  'props': node.props,
  'children': [for (final child in node.children) _tree(child)],
};

void _write(
  String plugin,
  String frame,
  PluginUiNode view, {
  bool card = false,
  bool canvas = false,
  bool awake = false,
  List<String> pages = const [],
}) {
  final file = File('${_out.path}/$plugin.$frame.json');
  file.writeAsStringSync(
    const JsonEncoder.withIndent(' ').convert(_tree(view)),
  );
  _index.add({
    'plugin': plugin,
    'frame': frame,
    'file': 'frames/plugins/$plugin.$frame.json',
    'card': card,
    'canvas': canvas,
    'awake': awake,
    'pages': pages,
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late LuauWorker worker;

  setUpAll(() {
    if (_out.existsSync()) _out.deleteSync(recursive: true);
    _out.createSync(recursive: true);
  });
  setUp(() async {
    root = await Directory.systemTemp.createTemp('upgrade-frames-');
    worker = LuauWorker(dataDirectory: root.path);
  });
  tearDown(() async {
    await worker.close();
    await root.delete(recursive: true);
  });
  tearDownAll(() {
    File('${_out.path}/index.json')
        .writeAsStringSync(const JsonEncoder.withIndent(' ').convert(_index));
  });

  test('board', () async {
    final app = board.BoardHarness(worker, boardPackage());
    void write(String frame) => _write('board', frame, app.view, canvas: true);
    await app.send({'type': 'mount'});
    write('mounted');
    await app.action('new_board');
    write('empty-board');
    await app.tool('note');
    await app.tap(80, 100, 'note1');
    await app.tap(80, 400, 'note2');
    await app.tool('select');
    await app.tap(80, 110, 'pick');
    await app.send({
      'type': 'action',
      'id': 'save_note',
      'fields': {'note': 'ROUTINE'},
    });
    write('note-selected');
    await app.tool('link');
    await app.tap(80, 110, 'a');
    await app.tap(80, 410, 'link1');
    write('linked');
    await app.action('boards');
    write('boards');
  });

  test('kanban', () async {
    final app = kanban.KanbanHarness(worker, kanbanPackage());
    await app.send({'type': 'mount'});
    _write('kanban', 'waiting', app.view, awake: true, pages: ['main']);
    await app.listed(kanban.feed);
    _write('kanban', 'board', app.view, awake: true, pages: ['main']);
    app.state = null;
    await app.send({'type': 'mount', 'widget': 'inbox'}, widget: 'inbox');
    await app.listed(kanban.feed, widget: 'inbox');
    _write(
      'kanban',
      'inbox-card',
      app.view,
      card: true,
      awake: true,
      pages: ['main'],
    );
  });

  test('agent-schedules', () async {
    final app = schedules.ScheduleHarness(worker, schedulePackage());
    void write(String frame) =>
        _write('agent-schedules', frame, app.view, canvas: true);
    const info = <String, Object?>{
      'installed': true,
      'timer_active': true,
      'supported': true,
      'agents': ['codex', 'claude'],
      'timezone': 'Europe/Paris',
      'features': ['queue', 'cancel', 'summary'],
    };
    await app.send({'type': 'mount'});
    await app.answer('hosts', {'items': []});
    write('no-hosts');
    await app.send({'type': 'mount'});
    await app.answer('hosts', {
      'items': [
        {'id': 'host1', 'name': 'Development'},
      ],
    });
    await app.action('choose_host', {'value': 'host1'});
    await app.answer('inspect', {
      ...info,
      'installed': false,
      'supported': false,
      'reason': 'Linger required',
    });
    write('unsupported');
    await app.answer('inspect', {...info, 'installed': false});
    write('setup');
    await app.answer('inspect', info);
    await app.answer('rows', {
      'items': [
        {
          'id': 'job1',
          'title': 'Review',
          'enabled': true,
          'next_label': '2026-09-14T09:00',
          'agent': 'codex',
          'repeat': 'daily',
        },
      ],
      'offset': 0,
      'more': false,
      'paused': false,
    });
    write('tasks');
    await app.action('new');
    write('composer');
  });
}
