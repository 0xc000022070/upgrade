@Tags(['host'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:striked/platform/links/link_probe.dart';

import 'fixture.dart';

/// Every one of the four silences is an operating system's answer rather than a branch in
/// this code: a refusal carries errno 111, a dropped packet carries nothing until the
/// deadline, and a tarpit carries a connection and no line.
void main() {
  test('the guest sshd answers with its identification line', () async {
    final result = await probeLink(hostVm.address, hostVm.port);

    expect(result.status, LinkStatus.up);
    expect(result.software, startsWith('OpenSSH_'));
    expect(result.latency, isNotNull);
    expect(linkWord(result), startsWith('OPENSSH_'));
  });

  test('a port nothing is listening on is refused', () async {
    final result = await probeLink(hostVm.address, hostVmDeadPort);

    expect(result.status, LinkStatus.refused);
    expect(linkWord(result), 'REFUSED');
  });

  test('a name with no address behind it is unresolved', () async {
    final result = await probeLink('no-such-host.invalid', 22);

    expect(result.status, LinkStatus.unresolved);
    expect(linkWord(result), 'UNRESOLVED');
  });

  test('a port that accepts and never speaks is no banner', () async {
    // Something answers the port and is not a shell, which a connect-only probe calls up.
    final tarpit = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final held = <Socket>[];
    tarpit.listen(held.add);
    addTearDown(() async {
      for (final socket in held) {
        socket.destroy();
      }
      await tarpit.close();
    });

    final result = await probeLink(
      tarpit.address.address,
      tarpit.port,
      deadline: const Duration(milliseconds: 300),
    );

    expect(result.status, LinkStatus.noBanner);
    expect(linkWord(result), 'NO BANNER');
  });

  test('a port that accepts and hangs up is refused', () async {
    final slammer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    slammer.listen((socket) => socket.destroy());
    addTearDown(slammer.close);

    final result = await probeLink(slammer.address.address, slammer.port);

    expect(result.status, LinkStatus.refused);
  });
}
