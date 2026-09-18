import 'dart:async';
import 'dart:convert';

import 'package:dazzle/platform/herdr_socket.dart';

/// A stand-in for the `direct-streamlocal@openssh.com` channel: lines in one
/// end, lines out the other, both readable by a test.
///
/// The client under test is the real one — only the ssh channel is scripted,
/// which is the boundary the app cannot cross without a host.
class FakeHerdrLink {
  FakeHerdrLink({Stream<List<int>>? scripted}) {
    _outgoing.stream.listen((bytes) => _written.write(utf8.decode(bytes)));
    if (scripted != null) {
      unawaited(_incoming.addStream(scripted).then((_) => endStream()));
    }
  }

  final StreamController<List<int>> _incoming = StreamController<List<int>>();
  final StreamController<List<int>> _outgoing = StreamController<List<int>>();
  final _written = StringBuffer();

  var _shut = false;

  /// Whether the client let the channel go. A herdr connection is destroyed
  /// rather than half-closed, so the test asks about this and not about a
  /// closed sink.
  bool get shut => _shut;

  HerdrLink get link => HerdrLink(
    incoming: _incoming.stream,
    outgoing: _outgoing.sink,
    shut: () async {
      _shut = true;
      await dispose();
    },
  );

  /// Everything the client has written, one entry per line.
  List<Map<String, Object?>> get sent => [
    for (final line in const LineSplitter().convert(_written.toString()))
      if (line.trim().isNotEmpty) jsonDecode(line) as Map<String, Object?>,
  ];

  /// One line, as a server writes it.
  void say(Object? message) =>
      _incoming.add(utf8.encode('${jsonEncode(message)}\n'));

  void feed(String raw) => _incoming.add(utf8.encode(raw));

  /// The far end going away.
  Future<void> endStream() async {
    if (!_incoming.isClosed) await _incoming.close();
  }

  Future<void> dispose() async {
    await endStream();
    if (!_outgoing.isClosed) await _outgoing.close();
  }
}

/// A herdr response line.
Map<String, Object?> herdrResult(
  Map<String, Object?> result, {
  String id = 'dazzle:0',
}) => {'id': id, 'result': result};

Map<String, Object?> herdrError(
  String code, {
  String message = '',
  String id = 'dazzle:0',
}) => {
  'id': id,
  'error': {'code': code, 'message': message},
};

/// An `agent.list` result for one pane.
Map<String, Object?> agentListResult(
  String pane, {
  String agent = 'claude',
  String status = 'working',
  int seq = 1,
  String title = 'dazzle',
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
