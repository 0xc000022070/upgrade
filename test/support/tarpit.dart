import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

typedef Tarpit = ({String address, int port, Completer<void> closedByPeer});

Future<Tarpit> openTarpit() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final held = <Socket>[];
  final closedByPeer = Completer<void>();
  void hungUp() {
    if (!closedByPeer.isCompleted) closedByPeer.complete();
  }

  server.listen((socket) {
    held.add(socket);
    socket.listen((_) {}, onDone: hungUp, onError: (Object _) => hungUp());
  });
  addTearDown(() async {
    for (final socket in held) {
      socket.destroy();
    }
    await server.close();
  });
  return (
    address: server.address.address,
    port: server.port,
    closedByPeer: closedByPeer,
  );
}
