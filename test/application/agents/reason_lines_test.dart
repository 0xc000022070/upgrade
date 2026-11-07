import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/application/agents/agents.dart';
import 'package:upgrade/application/agents/reason_lines.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/platform/herdr/herdr_client.dart';
import 'package:upgrade/platform/ssh/host_keys.dart';
import 'package:upgrade/platform/shell/shell_connection.dart';
import 'package:upgrade/platform/vnc/vnc_failure.dart';

const oak = Host(
  id: 'oak',
  name: 'OAK',
  address: '198.51.100.77',
  port: 22,
  user: 'luisnquin',
  keyId: 'k1',
);

void main() {
  group('the vocabulary', () {
    test('only the two lines about reaching a machine name one', () {
      expect(ReasonLine.unreachable.on('OAK'), 'oak unreachable');
      expect(ReasonLine.unresolved.on('OAK'), 'oak unresolved');
      expect(ReasonLine.keyRejected.on('OAK'), 'key rejected');
      expect(ReasonLine.streamClosed.on('OAK'), 'stream closed');
      expect(ReasonLine.hostKeyChanged.on('OAK'), 'host key changed');
    });

    test('the header word is the line without the host, uppercased', () {
      for (final line in ReasonLine.values) {
        expect(line.short, line.words.toUpperCase());
        expect(line.short, isNot(contains('OAK')));
      }
    });

    test('the one line carrying a number keeps it, and says so with none', () {
      expect(protocolLine(3), 'protocol 3');
      expect(protocolLine(null), 'protocol ?');
    });
  });

  group('one fact, one sentence, whatever layer found it', () {
    test('a key the host rejected', () {
      const line = 'key rejected';
      expect(const HerdrKeyRejected().reason('OAK'), line);
      expect(const VncKeyRejected().reason('OAK'), line);
      expect(ShellFailureKind.keyRejected.line.on('OAK'), line);
      expect(
        const HostOutcome(host: oak, kind: AgentOutcomeKind.keyRejected).reason,
        line,
      );
    });

    test('a machine that did not answer', () {
      const line = 'oak unreachable';
      expect(const HerdrUnreachable().reason('OAK'), line);
      expect(const VncUnreachable().reason('OAK'), line);
      expect(ShellFailureKind.unreachable.line.on('OAK'), line);
      expect(
        const HostOutcome(host: oak, kind: AgentOutcomeKind.unreachable).reason,
        line,
      );
    });

    test('a host key that is not the one pinned for it', () {
      const line = 'host key changed';
      expect(const HerdrHostKeyChanged().reason('OAK'), line);
      expect(const VncHostKeyChanged().reason('OAK'), line);
      expect(ShellFailureKind.hostKeyChanged.line.on('OAK'), line);
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
      expect(const HerdrProtocolMismatch(3).reason('OAK'), 'protocol 3');
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
      expect(const HerdrMissing().reason('OAK'), line);
      expect(
        const HostOutcome(host: oak, kind: AgentOutcomeKind.noHerdr).reason,
        line,
      );
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
      for (final kind in ShellFailureKind.values) {
        expect(kind.line.short, kind.line.words.toUpperCase());
      }
      expect(ShellFailureKind.shellRefused.line.on('OAK'), 'shell refused');
      expect(ShellFailureKind.streamClosed.line.short, 'STREAM CLOSED');
    });

    test('the screen route words its own three beside the ssh ones', () {
      expect(const VncTunnelRefused().reason('OAK'), 'tunnel refused');
      expect(const VncAuthUnsupported().reason('OAK'), 'auth unsupported');
      expect(const VncUsernameNeeded().reason('OAK'), 'VNC username missing');
      expect(const VncPasswordNeeded().reason('OAK'), 'VNC password missing');
      expect(const VncAuthRejected().reason('OAK'), 'VNC credentials rejected');
      expect(const VncStreamClosed().reason('OAK'), 'stream closed');
      expect(const VncUnresolved().reason('OAK'), 'oak unresolved');
      expect(const VncHostKeyUnverified().reason('OAK'), 'host key unverified');
    });

    test('the poll words the rest of the herdr failures', () {
      expect(const HerdrUnresolved().reason('OAK'), 'oak unresolved');
      expect(
        const HerdrHostKeyUnverified().reason('OAK'),
        'host key unverified',
      );
    });
  });
}
