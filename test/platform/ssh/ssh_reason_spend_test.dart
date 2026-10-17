import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:striked/platform/ssh/host_keys.dart';
import 'package:striked/platform/ssh/host_links.dart';
import 'package:striked/platform/ssh/connection_supervisor.dart';

import '../../support/host_links.dart';
import '../../support/reasons.dart';

final _vm = PinnedHostKey(
  type: 'ssh-ed25519',
  fingerprint: 'SHA256:vm',
  pinnedAt: DateTime(2026),
);

Future<ConnectionSupervisor> _tab(SshConnector connector, OpenReason reason) =>
    connector.establish(
      address: '10.0.0.2',
      port: 22,
      user: 'dev',
      privateKey: 'key',
      verifier: HostKeyVerifier.pinnedOnly(_vm),
      reason: reason,
      startup: (supervisor) async => supervisor,
    );

final class _Box<T> {
  _Box(this.value);

  final T value;
}

extension on UserIntent {
  UserIntent get kept => this;
}

void main() {
  late FakeDial dial;
  late HostLinks links;
  late SshConnector connector;
  late List<String> printed;
  late DebugPrintCallback saved;
  var now = Duration.zero;

  setUp(() {
    dial = FakeDial();
    links = HostLinks(dial: dial.call);
    connector = SshConnector(
      links: links,
      timeout: const Duration(seconds: 10),
    );
    now = Duration.zero;
    UserIntent.clock = () => now;
    printed = [];
    saved = debugPrint;
    debugPrint = (message, {wrapWidth}) => printed.add(message ?? '');
  });

  tearDown(() {
    debugPrint = saved;
    UserIntent.clock = null;
    links.close();
  });

  Matcher refused(String type, String why) => contains(
    allOf(startsWith('striked.ssh '), contains('refused $type: $why')),
  );

  test(
    'a second reason from one intent is refused and dials nothing',
    () async {
      final intent = testIntent();
      UserAction(intent);

      await expectLater(
        _tab(connector, UserAction(intent)),
        throwsA(isA<AssertionError>()),
      );
      expect(dial.dials, 0);
      expect(printed, refused('UserAction', 'its intent was spent before'));
    },
  );

  test('a close and an open from one intent: the second is refused', () async {
    final tab = await _tab(connector, UserAction(testIntent()));
    final intent = testIntent();
    UserClosed(intent);

    expect(() => tab.open(UserAction(intent)), throwsA(isA<AssertionError>()));
    expect(dial.dials, 1);
    await tab.drop(UserClosed(testIntent()));
  });

  test(
    'a second reason from one signal is refused and drops nothing',
    () async {
      final tab = await _tab(connector, UserAction(testIntent()));
      final signal = testSignal();
      AppResumed(signal);

      expect(
        () => tab.drop(AppSuspended(signal)),
        throwsA(isA<AssertionError>()),
      );
      expect(dial.clients.single.isClosed, isFalse);
      expect(
        () => tab.open(NetworkChanged(signal)),
        throwsA(isA<AssertionError>()),
      );
      expect(dial.dials, 1);
      expect(printed, refused('AppSuspended', 'its signal was spent before'));
      await tab.drop(UserClosed(testIntent()));
    },
  );

  test('an intent spent past its window is refused', () async {
    final intent = testIntent();
    now = UserIntent.window + const Duration(milliseconds: 1);

    await expectLater(
      _tab(connector, UserAction(intent)),
      throwsA(isA<AssertionError>()),
    );
    expect(dial.dials, 0);
    expect(printed, refused('UserAction', 'its intent is 5001 ms old'));
  });

  test('an intent spent at the edge of its window is not', () async {
    final intent = testIntent();
    now = UserIntent.window;

    final tab = await _tab(connector, UserAction(intent));
    expect(dial.dials, 1);
    await tab.drop(UserClosed(testIntent()));
  });

  test(
    'a signal has no window: a deferred network change still opens',
    () async {
      final tab = await _tab(connector, UserAction(testIntent()));
      final signal = testSignal();
      now = const Duration(minutes: 5);

      final change = NetworkChanged(signal);
      await tab.drop(change);
      expect(await tab.open(change), isNotNull);
      expect(dial.dials, 2);
      await tab.drop(UserClosed(testIntent()));
    },
  );

  test('one reason is reused as often as it is passed', () async {
    final action = UserAction(testIntent());
    final first = await _tab(connector, action);
    final second = await _tab(connector, action);
    expect(await first.open(action), isNotNull);

    final closed = UserClosed.by(action);
    await first.drop(closed);
    await second.drop(closed);
    expect(dial.dials, 1);
    expect(printed.where((line) => line.contains('refused')), isEmpty);
  });

  test('a close built with a refused action is refused with it', () async {
    final tab = await _tab(connector, UserAction(testIntent()));
    final intent = testIntent();
    UserAction(intent);

    expect(
      () => tab.drop(UserClosed.by(UserAction(intent))),
      throwsA(isA<AssertionError>()),
    );
    expect(dial.clients.single.isClosed, isFalse);
    await tab.drop(UserClosed(testIntent()));
  });

  test('a supervisor accepts only the end it minted', () async {
    final first = await _tab(connector, UserAction(testIntent()));
    final second = await _tab(connector, UserAction(testIntent()));

    for (final end in [second.terminalEnded(), ShellEnded.unbound()]) {
      expect(first.accepts(end), isFalse);
      expect(() => first.drop(end), throwsArgumentError);
    }
    expect(first.accepts(first.terminalEnded()), isTrue);
    expect(dial.clients.single.isClosed, isFalse);
    await first.drop(UserClosed(testIntent()));
    await second.drop(UserClosed(testIntent()));
  });

  group('a token kept past its gesture', () {
    test('in a box of Object, then spent later, is refused', () async {
      late final _Box<Object> box;
      UserIntent.onGesture((intent) => box = _Box<Object>(intent))();
      now = const Duration(seconds: 6);

      await expectLater(
        _tab(connector, UserAction(box.value as UserIntent)),
        throwsA(isA<AssertionError>()),
      );
      expect(dial.dials, 0);
    });

    test('in a record local, then spent twice, is refused', () async {
      late final ({UserIntent intent, int at}) held;
      UserIntent.onGesture((intent) => held = (intent: intent, at: 0))();

      final tab = await _tab(connector, UserAction(held.intent));
      expect(
        () => tab.open(UserAction(held.intent)),
        throwsA(isA<AssertionError>()),
      );
      expect(dial.dials, 1);
      await tab.drop(UserClosed(testIntent()));
    });

    test('through an extension handing back itself, is refused', () async {
      final intent = testIntent();
      final tab = await _tab(connector, UserAction(intent));

      expect(
        () => tab.drop(UserClosed(intent.kept)),
        throwsA(isA<AssertionError>()),
      );
      expect(dial.clients.single.isClosed, isFalse);
      await tab.drop(UserClosed(testIntent()));
    });

    test('through Function.apply, twice, is refused', () async {
      final intent = testIntent();
      UserAction build(UserIntent intent) => UserAction(intent);
      final first = Function.apply(build, [intent]) as UserAction;
      final second = Function.apply(build, [intent]) as UserAction;

      final tab = await _tab(connector, first);
      expect(() => tab.open(second), throwsA(isA<AssertionError>()));
      expect(dial.dials, 1);
      await tab.drop(UserClosed(testIntent()));
    });
  });
}
