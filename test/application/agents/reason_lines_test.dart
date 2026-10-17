import 'package:flutter_test/flutter_test.dart';
import 'package:striked/application/agents/agents.dart';
import 'package:striked/application/agents/reason_lines.dart';
import 'package:striked/data/repositories/host_repository.dart';
import 'package:striked/platform/herdr/herdr_client.dart';
import 'package:striked/platform/ssh/host_keys.dart';
import 'package:striked/platform/shell/shell_connection.dart';
import 'package:striked/platform/vnc/vnc_failure.dart';

const nyx = Host(
  id: 'nyx',
  name: 'NYX',
  address: '100.118.60.77',
  port: 22,
  user: 'luisnquin',
  keyId: 'k1',
);

void main() {
  group('the vocabulary', () {
    test('only the two lines about reaching a machine name one', () {
      expect(ReasonLine.unreachable.on('NYX'), 'nyx unreachable');
      expect(ReasonLine.unresolved.on('NYX'), 'nyx unresolved');
      expect(ReasonLine.keyRejected.on('NYX'), 'key rejected');
      expect(ReasonLine.streamClosed.on('NYX'), 'stream closed');
      expect(ReasonLine.hostKeyChanged.on('NYX'), 'host key changed');
    });

    test('the header word is the line without the host, uppercased', () {
      for (final line in ReasonLine.values) {
        expect(line.short, line.words.toUpperCase());
        expect(line.short, isNot(contains('NYX')));
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
      expect(const HerdrKeyRejected().reason('NYX'), line);
      expect(const VncKeyRejected().reason('NYX'), line);
      expect(ShellFailureKind.keyRejected.line.on('NYX'), line);
      expect(
        const HostOutcome(host: nyx, kind: AgentOutcomeKind.keyRejected).reason,
        line,
      );
    });

    test('a machine that did not answer', () {
      const line = 'nyx unreachable';
      expect(const HerdrUnreachable().reason('NYX'), line);
      expect(const VncUnreachable().reason('NYX'), line);
      expect(ShellFailureKind.unreachable.line.on('NYX'), line);
      expect(
        const HostOutcome(host: nyx, kind: AgentOutcomeKind.unreachable).reason,
        line,
      );
    });

    test('a host key that is not the one pinned for it', () {
      const line = 'host key changed';
      expect(const HerdrHostKeyChanged().reason('NYX'), line);
      expect(const VncHostKeyChanged().reason('NYX'), line);
      expect(ShellFailureKind.hostKeyChanged.line.on('NYX'), line);
      expect(HostKeyRefusal.changed.line.words, line);
      expect(
        const HostOutcome(
          host: nyx,
          kind: AgentOutcomeKind.hostKeyChanged,
        ).reason,
        line,
      );
    });

    test('a protocol the app does not speak', () {
      expect(const HerdrProtocolMismatch(3).reason('NYX'), 'protocol 3');
      expect(
        const HostOutcome(
          host: nyx,
          kind: AgentOutcomeKind.protocolMismatch,
          protocol: 3,
        ).reason,
        'protocol 3',
      );
    });

    test('a host with no herdr on its path', () {
      const line = 'no herdr';
      expect(const HerdrMissing().reason('NYX'), line);
      expect(
        const HostOutcome(host: nyx, kind: AgentOutcomeKind.noHerdr).reason,
        line,
      );
    });

    test('a snapshot is not a failure and has no line', () {
      expect(
        const HostOutcome(host: nyx, kind: AgentOutcomeKind.snapshot).reason,
        '',
      );
    });
  });

  group('the one surface that shows a failure and counts the rest', () {
    test('writes the host in once, whatever the line already carries', () {
      for (final kind in AgentOutcomeKind.values) {
        if (kind == AgentOutcomeKind.snapshot) continue;
        final named = HostOutcome(
          host: nyx,
          kind: kind,
          protocol: 3,
        ).namedReason;
        expect(
          'nyx'.allMatches(named).length,
          1,
          reason: '$kind reads "$named"',
        );
      }
    });

    test('asks the line rather than the kind', () {
      expect(
        const HostOutcome(
          host: nyx,
          kind: AgentOutcomeKind.unreachable,
        ).namedReason,
        'nyx unreachable',
      );
      expect(
        const HostOutcome(
          host: nyx,
          kind: AgentOutcomeKind.keyRejected,
        ).namedReason,
        'nyx · key rejected',
      );
      expect(
        const HostOutcome(
          host: nyx,
          kind: AgentOutcomeKind.protocolMismatch,
          protocol: 3,
        ).namedReason,
        'nyx · protocol 3',
      );
    });

    test('a snapshot is no failure and is not prefixed into one', () {
      expect(
        const HostOutcome(
          host: nyx,
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
      expect(ShellFailureKind.shellRefused.line.on('NYX'), 'shell refused');
      expect(ShellFailureKind.streamClosed.line.short, 'STREAM CLOSED');
    });

    test('the screen route words its own three beside the ssh ones', () {
      expect(const VncTunnelRefused().reason('NYX'), 'tunnel refused');
      expect(const VncAuthUnsupported().reason('NYX'), 'auth unsupported');
      expect(const VncUsernameNeeded().reason('NYX'), 'VNC username missing');
      expect(const VncPasswordNeeded().reason('NYX'), 'VNC password missing');
      expect(const VncAuthRejected().reason('NYX'), 'VNC credentials rejected');
      expect(const VncStreamClosed().reason('NYX'), 'stream closed');
      expect(const VncUnresolved().reason('NYX'), 'nyx unresolved');
      expect(const VncHostKeyUnverified().reason('NYX'), 'host key unverified');
    });

    test('the poll words the rest of the herdr failures', () {
      expect(const HerdrUnresolved().reason('NYX'), 'nyx unresolved');
      expect(
        const HerdrHostKeyUnverified().reason('NYX'),
        'host key unverified',
      );
    });
  });
}
