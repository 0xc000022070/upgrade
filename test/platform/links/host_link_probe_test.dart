import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/features/hosts/link_probes.dart';
import 'package:upgrade/platform/links/host_link_probe.dart';

const _pine = Host(
  id: 'h1',
  name: 'pine',
  address: '127.0.0.1',
  port: 22,
  user: 'alex',
  keyId: 'key-1',
);

const _short = Duration(milliseconds: 400);

void main() {
  test(
    'a machine that identifies itself answers with software and a time',
    () async {
      final server = await ServerSocket.bind('127.0.0.1', 0);
      addTearDown(server.close);
      server.listen((socket) {
        socket.write('SSH-2.0-OpenSSH_9.9p1 Debian-3\r\n');
        socket.flush();
      });

      final result = await probeLink(
        '127.0.0.1',
        server.port,
        deadline: _short,
      );

      expect(result.status, LinkStatus.up);
      expect(result.software, 'OpenSSH_9.9p1');
      expect(result.latency, isNotNull);
      expect(linkWord(result), startsWith('OPENSSH_9.9P1 · '));
      expect(linkWord(result), endsWith(' MS'));
      expect(linkFailed(result), isFalse);
    },
  );

  test(
    'a port that accepts and then says nothing is a tarpit, not a shell',
    () async {
      final server = await ServerSocket.bind('127.0.0.1', 0);
      addTearDown(server.close);
      // Held open and silent, which is what the LAN address on the user's own network does.
      final held = <Socket>[];
      server.listen(held.add);
      addTearDown(() {
        for (final socket in held) {
          socket.destroy();
        }
      });

      final result = await probeLink(
        '127.0.0.1',
        server.port,
        deadline: _short,
      );

      expect(result.status, LinkStatus.noBanner);
      expect(linkWord(result), 'NO BANNER');
      expect(linkFailed(result), isTrue);
    },
  );

  test(
    'something that answers with anything else has no banner either',
    () async {
      final server = await ServerSocket.bind('127.0.0.1', 0);
      addTearDown(server.close);
      server.listen((socket) {
        socket.write('HTTP/1.1 400 Bad Request\r\n');
        socket.flush();
      });

      final result = await probeLink(
        '127.0.0.1',
        server.port,
        deadline: _short,
      );

      expect(result.status, LinkStatus.noBanner);
    },
  );

  test('a closed port is refused', () async {
    final server = await ServerSocket.bind('127.0.0.1', 0);
    final port = server.port;
    await server.close();

    final result = await probeLink('127.0.0.1', port, deadline: _short);

    expect(result.status, LinkStatus.refused);
    expect(linkWord(result), 'REFUSED');
  });

  test('a name that does not resolve says so', () async {
    final result = await probeLink('oak.upgrade.invalid', 22, deadline: _short);

    expect(result.status, LinkStatus.unresolved);
    expect(linkWord(result), 'UNRESOLVED');
  });

  test('the identification line is read down to its software token', () {
    expect(identificationSoftware('SSH-2.0-OpenSSH_9.9'), 'OpenSSH_9.9');
    expect(
      identificationSoftware('SSH-2.0-OpenSSH_9.9p1 Debian-3'),
      'OpenSSH_9.9p1',
    );
    expect(
      identificationSoftware('SSH-1.99-dropbear_2022.83'),
      'dropbear_2022.83',
    );
    expect(identificationSoftware('HTTP/1.1 400'), isNull);
    expect(identificationSoftware('SSH-2.0-'), isNull);
  });

  test('a host is not probed again inside the cache window, and a tap probes it anyway', () async {
    var calls = 0;
    var now = DateTime.utc(2026, 9, 3, 12);
    final probes = LinkProbes(
      probe: (_, _) async {
        calls++;
        return const LinkResult(LinkStatus.up, software: 'OpenSSH_9.9');
      },
      now: () => now,
    );

    await probes.refresh([_pine]);
    await probes.refresh([_pine]);
    expect(calls, 1);

    await probes.probe(_pine, force: true);
    expect(calls, 2);

    now = now.add(linkProbeMaxAge + const Duration(seconds: 1));
    await probes.refresh([_pine]);
    expect(calls, 3);
  });

  test(
    'a probe in flight reads as PROBING and its answer replaces it',
    () async {
      final answer = Completer<LinkResult>();
      final probes = LinkProbes(probe: (_, _) => answer.future);

      final pending = probes.probe(_pine);
      expect(linkWord(probes.forHost(_pine.id)), 'PROBING');

      answer.complete(const LinkResult(LinkStatus.noRoute));
      await pending;
      expect(linkWord(probes.forHost(_pine.id)), 'NO ROUTE');
    },
  );

  test('rows on one address and port share one connection', () async {
    var calls = 0;
    final answer = Completer<LinkResult>();
    final probes = LinkProbes(
      probe: (_, _) {
        calls++;
        return answer.future;
      },
    );
    const twin = Host(
      id: 'h2',
      name: 'pine root',
      address: '127.0.0.1',
      port: 22,
      user: 'root',
      keyId: 'key-1',
    );

    final pending = probes.refresh([_pine, twin]);
    answer.complete(const LinkResult(LinkStatus.up, software: 'OpenSSH_9.9'));
    await pending;

    expect(calls, 1);
    expect(
      linkWord(probes.forHost(twin.id)),
      linkWord(probes.forHost(_pine.id)),
    );
  });

  test('a host nobody has probed reads as a dash', () {
    expect(linkWord(LinkProbes().forHost(_pine.id)), '—');
  });
}
