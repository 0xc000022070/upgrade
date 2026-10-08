@Tags(['host'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/platform/herdr_client.dart';
import 'package:upgrade/platform/host_links.dart';

import 'fixture.dart';

/// Relays one connection to the guest and can abort it with an RST, which is what a
/// machine sends for a connection it no longer knows; the guest itself only ever closes.
class ResettingRelay {
  ResettingRelay._(this._server);

  final ServerSocket _server;
  Socket? _near;
  Socket? _far;

  int get port => _server.port;

  static Future<ResettingRelay> start() async {
    final relay = ResettingRelay._(
      await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
    );
    relay._server.listen((near) async {
      final far = await Socket.connect(hostVm.address, hostVm.port);
      relay._near = near;
      relay._far = far;
      near.listen(far.add, onError: (Object _) {}, onDone: far.destroy);
      far.listen(near.add, onError: (Object _) {}, onDone: near.destroy);
    });
    return relay;
  }

  void reset() {
    _near!
      ..setRawOption(
        RawSocketOption(
          RawSocketOption.levelSocket,
          Platform.isLinux ? 13 : 0x80,
          Uint8List.fromList([1, 0, 0, 0, 0, 0, 0, 0]),
        ),
      )
      ..destroy();
    _far!.destroy();
  }

  Future<void> close() => _server.close();
}

void main() {
  test(
    'closing a herdr session the host reset raises nothing unhandled',
    () async {
      final relay = await ResettingRelay.start();
      addTearDown(relay.close);

      final links = HostLinks();
      addTearDown(links.close);
      final session = await HerdrClient(links: links, caller: 'test').connect(
        address: hostVm.address,
        port: relay.port,
        user: hostVm.user,
        privateKey: hostVmPrivateKey(),
        verifier: trustGuest(),
      );
      relay.reset();
      await Future<void>.delayed(const Duration(milliseconds: 300));

      session.close();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    },
  );
}
