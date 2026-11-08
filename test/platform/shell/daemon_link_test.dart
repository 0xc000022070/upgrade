import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/platform/shell/daemon_link.dart';

class _Link implements DaemonLink {
  final failures = <DaemonFailed>[];
  var calls = 0;

  @override
  Future<int> attach({
    required String host,
    required int port,
    required String cert,
    required String token,
    required String tab,
  }) => throw UnimplementedError();

  @override
  Future<String> call({
    required String host,
    required int port,
    required String cert,
    required String token,
    required String body,
  }) async {
    calls++;
    if (failures.isNotEmpty) throw failures.removeAt(0);
    return 'ran $body on $port';
  }
}

void main() {
  late _Link link;
  late DateTime clock;
  late EngineDaemons daemons;
  late List<Map<String, Object?>?> starts;
  var asked = 0;

  Future<String?> call() => daemons.call(
    address: 'nyx',
    user: 'me',
    body: 'b',
    timeout: const Duration(seconds: 1),
    start: () async {
      asked++;
      return starts.isEmpty ? null : starts.removeAt(0);
    },
  );

  const daemon = {'port': 7, 'cert': 'c', 'token': 't'};

  setUp(() {
    link = _Link();
    clock = DateTime(2026);
    daemons = EngineDaemons(link, now: () => clock);
    starts = [daemon, daemon];
    asked = 0;
  });

  test('no link means ssh and no start', () async {
    final none = EngineDaemons(null);
    expect(
      await none.call(
        address: 'nyx',
        user: 'me',
        body: 'b',
        timeout: const Duration(seconds: 1),
        start: () => throw StateError('asked'),
      ),
      isNull,
    );
  });

  test('a daemon is asked for once and kept', () async {
    expect(await call(), 'ran b on 7');
    expect(await call(), 'ran b on 7');
    expect(asked, 1);
  });

  test('a host with no daemon is left to ssh until it cools', () async {
    starts = [null, daemon];
    expect(await call(), isNull);
    expect(await call(), isNull);
    expect(asked, 1);
    clock = clock.add(const Duration(minutes: 5));
    expect(await call(), 'ran b on 7');
    expect(asked, 2);
  });

  test('a kept daemon that fails unsent is asked for again once', () async {
    expect(await call(), 'ran b on 7');
    link.failures.add(const DaemonFailed('gone', sent: false));
    expect(await call(), 'ran b on 7');
    expect(asked, 2);
  });

  test('a fresh daemon that fails unsent sends the call to ssh', () async {
    link.failures.add(const DaemonFailed('unreachable', sent: false));
    expect(await call(), isNull);
    expect(await call(), isNull);
    expect(asked, 1);
  });

  test(
    'a failure after sending is thrown and the daemon asked again',
    () async {
      link.failures.add(const DaemonFailed('lost', sent: true));
      await expectLater(call(), throwsA(isA<DaemonFailed>()));
      expect(await call(), 'ran b on 7');
      expect(asked, 2);
    },
  );
}
