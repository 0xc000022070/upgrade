import 'dart:typed_data';

import 'package:dart_mosh/dart_mosh.dart';

abstract interface class MoshChannel {
  Stream<Uint8List> get output;
  Stream<Object> get errors;
  Future<void> get done;

  void send(Uint8List bytes);
  void resize(int columns, int rows);
  Future<void> rehome();
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
}) async => _DartMoshChannel(
  await MoshSession.connect(
    server: server,
    cipher: MoshPacketCipher.aesOcb(server.key),
    columns: columns,
    rows: rows,
  ),
);

class _DartMoshChannel implements MoshChannel {
  const _DartMoshChannel(this._session);

  final MoshSession _session;

  @override
  Stream<Uint8List> get output => _session.stdout.map(Uint8List.fromList);

  @override
  Stream<Object> get errors => _session.errors;

  @override
  Future<void> get done => _session.done;

  @override
  void send(Uint8List bytes) => _session.send(bytes);

  @override
  void resize(int columns, int rows) => _session.resize(columns, rows);

  @override
  Future<void> rehome() => _session.rehome();

  @override
  Future<void> close() => _session.close();
}
