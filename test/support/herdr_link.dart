import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:upgrade/platform/herdr_socket.dart';

class FakeHerdrLink {
  FakeHerdrLink({Stream<Uint8List>? scripted}) {
    _outgoing.stream.listen((bytes) => _written.write(utf8.decode(bytes)));
    if (scripted != null) {
      unawaited(_incoming.addStream(scripted).then((_) => endStream()));
    }
  }

  /// A `StreamController<List<int>>` here would widen the runtime type argument back and
  /// hide a missing cast in the client.
  final StreamController<Uint8List> _incoming = StreamController<Uint8List>();
  final StreamController<List<int>> _outgoing = StreamController<List<int>>();
  final _written = StringBuffer();

  var _shut = false;

  /// A herdr connection is destroyed rather than half-closed, so the test asks about this
  /// and not about a closed sink.
  bool get shut => _shut;

  HerdrLink get link => HerdrLink(
    incoming: _incoming.stream,
    outgoing: _outgoing.sink,
    shut: () async {
      _shut = true;
      await dispose();
    },
  );

  List<Map<String, Object?>> get sent => [
    for (final line in const LineSplitter().convert(_written.toString()))
      if (line.trim().isNotEmpty) jsonDecode(line) as Map<String, Object?>,
  ];

  void say(Object? message) =>
      _incoming.add(utf8.encode('${jsonEncode(message)}\n'));

  void feed(String raw) => _incoming.add(utf8.encode(raw));

  Future<void> endStream() async {
    if (!_incoming.isClosed) await _incoming.close();
  }

  Future<void> dispose() async {
    await endStream();
    if (!_outgoing.isClosed) await _outgoing.close();
  }
}

Map<String, Object?> herdrResult(
  Map<String, Object?> result, {
  String id = 'upgrade:0',
}) => {'id': id, 'result': result};

Map<String, Object?> herdrError(
  String code, {
  String message = '',
  String id = 'upgrade:0',
}) => {
  'id': id,
  'error': {'code': code, 'message': message},
};

Map<String, Object?> agentListResult(
  String pane, {
  String agent = 'claude',
  String status = 'working',
  int seq = 1,
  String title = 'upgrade',
  String cwd = '/home/dev/Projects/fixture',
}) => {
  'type': 'agent_list',
  'agents': [
    {
      'agent': agent,
      'agent_status': status,
      'cwd': cwd,
      'pane_id': pane,
      'state_change_seq': seq,
      'terminal_title_stripped': title,
      'workspace_id': pane.split(':').first,
    },
  ],
};
