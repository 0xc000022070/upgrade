import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/platform/ssh/host_failure.dart';
import 'package:upgrade/application/agents/agents.dart';
import 'package:upgrade/platform/reason_lines.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/platform/device.dart';
import 'package:upgrade/platform/herdr/herdr_client.dart';
import 'package:upgrade/platform/ssh/host_keys.dart';

const oak = Host(
  id: 'oak',
  name: 'OAK',
  address: '198.51.100.77',
  port: 22,
  user: 'developer',
  keyId: 'k1',
);

void main() {
  group('a tailnet machine on a phone with no vpn', () {
    tearDown(() => Device.vpn = null);

    test('the tailnet ranges and MagicDNS names are tailnet addresses', () {
      for (final address in [
        '100.64.0.1',
        '100.118.60.77',
        '100.127.255.255',
        'fd7a:115c:a1e0::1',
        'nyx.tail1234.ts.net',
        'NYX.TAIL1234.TS.NET.',
      ]) {
        expect(isTailnetAddress(address), isTrue, reason: address);
      }
      for (final address in [
        '100.63.255.255',
        '100.128.0.1',
        '198.51.100.77',
        'fd7a:115c:a1e1::1',
        'nyx.local',
        'ts.net.example.com',
      ]) {
        expect(isTailnetAddress(address), isFalse, reason: address);
      }
    });

    test('says vpn off only when the phone is known to have none', () {
      const tailnet = '100.118.60.77';
      expect(
        ReasonLine.unreachable.on('NYX', address: tailnet),
        'nyx unreachable',
      );
      Device.vpn = true;
      expect(
        ReasonLine.unreachable.on('NYX', address: tailnet),
        'nyx unreachable',
      );
      Device.vpn = false;
      expect(
        ReasonLine.unreachable.on('NYX', address: tailnet),
        'nyx unreachable · vpn off',
      );
      expect(
        const HostFailure(HostFailureKind.unresolved)
            .reason('NYX', address: 'nyx.tail1.ts.net'),
        'nyx unresolved · vpn off',
      );
      expect(
        ReasonLine.unreachable.on('OAK', address: oak.address),
        'oak unreachable',
      );
      expect(
        ReasonLine.keyRejected.on('NYX', address: tailnet),
        'key rejected',
      );
    });
  });

  group('the vocabulary', () {
    test('only the two lines about reaching a machine name one', () {
      expect(ReasonLine.unreachable.on('OAK'), 'oak unreachable');
      expect(ReasonLine.unresolved.on('OAK'), 'oak unresolved');
      expect(ReasonLine.keyRejected.on('OAK'), 'key rejected');
      expect(ReasonLine.streamClosed.on('OAK'), 'stream closed');
      expect(ReasonLine.hostKeyChanged.on('OAK'), 'host key changed');
    });

    test('the one line carrying a number keeps it, and says so with none', () {
      expect(protocolLine(3), 'protocol 3');
      expect(protocolLine(null), 'protocol ?');
    });
  });

  group('one fact, one sentence, whatever layer found it', () {
    test('a key the host rejected', () {
      const line = 'key rejected';
      expect(const HostFailure.keyRejected().reason('OAK'), line);
      expect(HostFailureKind.keyRejected.line.on('OAK'), line);
      expect(
        const HostOutcome(host: oak, kind: AgentOutcomeKind.keyRejected).reason,
        line,
      );
    });

    test('a machine that did not answer', () {
      const line = 'oak unreachable';
      expect(const HostFailure.unreachable().reason('OAK'), line);
      expect(HostFailureKind.unreachable.line.on('OAK'), line);
      expect(
        const HostOutcome(host: oak, kind: AgentOutcomeKind.unreachable).reason,
        line,
      );
    });

    test('a host key that is not the one pinned for it', () {
      const line = 'host key changed';
      expect(
        const HostFailure(HostFailureKind.hostKeyChanged).reason('OAK'),
        line,
      );
      expect(HostFailureKind.hostKeyChanged.line.on('OAK'), line);
      expect(HostKeyRefusal.changed.line.words, line);
      expect(
        const HostOutcome(
          host: oak,
          kind: AgentOutcomeKind.hostKeyChanged,
        ).reason,
        line,
      );
    });

    test('a protocol the app does not speak', () {
      expect(const HostFailure.protocolMismatch(3).reason('OAK'), 'protocol 3');
      expect(
        const HostOutcome(
          host: oak,
          kind: AgentOutcomeKind.protocolMismatch,
          protocol: 3,
        ).reason,
        'protocol 3',
      );
    });

    test('a host with no herdr on its path', () {
      const line = 'no herdr';
      expect(const HostFailure.noHerdr().reason('OAK'), line);
      expect(
        const HostOutcome(host: oak, kind: AgentOutcomeKind.noHerdr).reason,
        line,
      );
    });

    test('every failure reads the same as the outcome made from it', () {
      const failures = <HostFailure>[
        HostFailure.keyRejected(),
        HostFailure.protocolMismatch(3),
        HostFailure(HostFailureKind.unresolved),
        HostFailure.unreachable(),
        HostFailure.busy(),
        HostFailure.noEngine(),
        HostFailure.noHerdr(),
        HostFailure(HostFailureKind.hostKeyUnverified),
        HostFailure(HostFailureKind.hostKeyChanged),
      ];
      for (final failure in failures) {
        final outcome = HostOutcome(
          host: oak,
          kind: AgentOutcomeKind.of(failure),
          protocol: failure.protocol,
        );
        expect(outcome.reason, failure.reason(oak.name, address: oak.address));
      }
    });

    test('a snapshot is not a failure and has no line', () {
      expect(
        const HostOutcome(host: oak, kind: AgentOutcomeKind.snapshot).reason,
        '',
      );
    });
  });

  group('the one surface that shows a failure and counts the rest', () {
    test('writes the host in once, whatever the line already carries', () {
      for (final kind in AgentOutcomeKind.values) {
        if (kind == AgentOutcomeKind.snapshot) continue;
        final named = HostOutcome(
          host: oak,
          kind: kind,
          protocol: 3,
        ).namedReason;
        expect(
          'oak'.allMatches(named).length,
          1,
          reason: '$kind reads "$named"',
        );
      }
    });

    test('asks the line rather than the kind', () {
      expect(
        const HostOutcome(
          host: oak,
          kind: AgentOutcomeKind.unreachable,
        ).namedReason,
        'oak unreachable',
      );
      expect(
        const HostOutcome(
          host: oak,
          kind: AgentOutcomeKind.keyRejected,
        ).namedReason,
        'oak · key rejected',
      );
      expect(
        const HostOutcome(
          host: oak,
          kind: AgentOutcomeKind.protocolMismatch,
          protocol: 3,
        ).namedReason,
        'oak · protocol 3',
      );
    });

    test('a snapshot is no failure and is not prefixed into one', () {
      expect(
        const HostOutcome(
          host: oak,
          kind: AgentOutcomeKind.snapshot,
        ).namedReason,
        '',
      );
    });
  });

  group('every failure has a line', () {
    test('the shell names one per kind and the header word follows it', () {
      for (final kind in HostFailureKind.values) {
        expect(kind.line.short, kind.line.words.toUpperCase());
      }
      expect(HostFailureKind.shellRefused.line.on('OAK'), 'shell refused');
      expect(HostFailureKind.streamClosed.line.short, 'STREAM CLOSED');
    });

    test('the screen route words its own three beside the ssh ones', () {
      expect(
        const HostFailure(HostFailureKind.tunnelRefused).reason('OAK'),
        'tunnel refused',
      );
      expect(
        const HostFailure.authUnsupported().reason('OAK'),
        'auth unsupported',
      );
      expect(
        const HostFailure.usernameNeeded().reason('OAK'),
        'VNC username missing',
      );
      expect(
        const HostFailure.passwordNeeded().reason('OAK'),
        'VNC password missing',
      );
      expect(
        const HostFailure.authRejected().reason('OAK'),
        'VNC credentials rejected',
      );
      expect(const HostFailure.streamClosed().reason('OAK'), 'stream closed');
      expect(
        const HostFailure(HostFailureKind.unresolved).reason('OAK'),
        'oak unresolved',
      );
      expect(
        const HostFailure(HostFailureKind.hostKeyUnverified).reason('OAK'),
        'host key unverified',
      );
    });

    test('the poll words the rest of the herdr failures', () {
      expect(
        const HostFailure(HostFailureKind.unresolved).reason('OAK'),
        'oak unresolved',
      );
      expect(
        const HostFailure(HostFailureKind.hostKeyUnverified).reason('OAK'),
        'host key unverified',
      );
    });
  });
}
