import 'dart:async';
import 'dart:typed_data';

import 'package:dart_mosh/dart_mosh.dart';

import 'package:striked/platform/shell/udp_path.dart';

abstract interface class MoshChannel {
  Stream<Uint8List> get output;
  Stream<Object> get errors;
  Stream<int> get echoAcks;
  Stream<void> get contacts;

  Future<void> get firstContact;
  Future<void> get done;

  int send(Uint8List bytes);
  int resize(int columns, int rows);
  Future<void> rehome();
  Future<void> suspend();
  Future<void> close();
}

typedef MoshDialer = Future<MoshChannel> Function({
  required MoshServerConfig server,
  required int columns,
  required int rows,
});

Future<MoshChannel> dialMosh({
  required MoshServerConfig server,
  required int columns,
  required int rows,
  Duration contactWindow = const Duration(seconds: 4),
}) async => _DartMoshChannel(
  await MoshSession.connect(
    server: server,
    cipher: MoshPacketCipher.aesOcb(server.key),
    columns: columns,
    rows: rows,
  ),
  server: server,
  contactWindow: contactWindow,
);

class _DartMoshChannel implements MoshChannel {
  _DartMoshChannel(
    this._session, {
    required MoshServerConfig server,
    required Duration contactWindow,
  }) {
    _heard = _session.contacts.listen((_) {
      _contact.hear();
      unawaited(_heard?.cancel());
      _heard = null;
    });
    _contact.arm(contactWindow, address: server.host, port: server.port);
  }

  final MoshSession _session;
  final _contact = UdpContact();
  StreamSubscription<void>? _heard;

  @override
  Stream<Uint8List> get output => _session.stdout.map(
    (bytes) => bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
  );

  @override
  Stream<Object> get errors => _session.errors;

  @override
  Stream<int> get echoAcks => _session.echoAcks;

  @override
  Stream<void> get contacts => _session.contacts;

  @override
  Future<void> get firstContact => _contact.future;

  @override
  Future<void> get done => _session.done;

  @override
  int send(Uint8List bytes) => _session.send(bytes);

  @override
  int resize(int columns, int rows) => _session.resize(columns, rows);

  @override
  Future<void> rehome() => _session.rehome();

  @override
  Future<void> suspend() => _session.suspend();

  @override
  Future<void> close() {
    _contact.cancel();
    unawaited(_heard?.cancel());
    _heard = null;
    return _session.close();
  }
}
