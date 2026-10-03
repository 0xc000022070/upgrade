import 'support/native_plugins.dart';

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dazzle/application/agent_state.dart';
import 'package:dazzle/application/agents.dart';
import 'package:dazzle/data/database.dart';
import 'package:dazzle/data/repositories/host_repository.dart';
import 'package:dazzle/features/agents/agent_chat_screen.dart';
import 'package:dazzle/platform/engine_agents.dart';
import 'package:dazzle/platform/herdr_client.dart';

import 'support/platform_channels.dart';
import 'support/themed_app.dart';

const nyx = Host(
  id: 'nyx',
  name: 'Nyx',
  address: '100.118.60.77',
  port: 22,
  user: 'luisnquin',
  keyId: 'k1',
);

final claude = AgentSnapshot(
  session: 'engine',
  paneId: 'claude:s1',
  agent: 'claude',
  state: AgentState.of('working'),
  terminalTitleStripped: '',
  workspaceId: '',
  cwd: '/workspace/dazzle',
  stateChangeSeq: 1,
);

class _Session implements HerdrSession {
  @override
  void close() {}

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Engine implements EngineAgents {
  _Engine(this.reads);

  final List<Object> reads;
  var asked = 0;
  var watched = 0;

  @override
  final HerdrSession session = _Session();

  @override
  String get owner => 'luisnquin';

  @override
  Future<EngineWatch> watch({
    int? generation,
    Duration wait = Duration.zero,
  }) async {
    watched++;
    return (generation: 1, agents: [claude]);
  }

  @override
  Future<TranscriptPage> transcript(String key, {int? after}) async {
    final read = reads[asked < reads.length ? asked : reads.length - 1];
    asked++;
    if (read is EngineRefused) throw read;
    return read as TranscriptPage;
  }

  @override
  Future<void> answer(String id, {required bool allow}) async {}

  @override
  Future<List<HookStatus>> hooks() async => const [];

  @override
  Future<void> install(String agent) async {}
}

void main() {
  late AppDatabase db;

  setUp(() {
    stubDeviceChannels();
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() => db.close());

  Future<void> open(WidgetTester tester, _Engine engine) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...featureTestOverrides(db),
          agentsFeedProvider.overrideWith(
            (ref) => Stream.value(const AgentPanelState([])),
          ),
          engineOpenProvider.overrideWithValue((_) async => engine),
        ],
        child: MaterialApp(
          theme: testTheme,
          home: AgentChatScreen(host: nyx, agent: claude),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  testWidgets('a transcript that failed once is read on the next ask', (
    tester,
  ) async {
    final engine = _Engine([
      const EngineRefused('denied', 'permission denied'),
      (
        items: const [
          TranscriptItem(index: 0, kind: 'user', text: 'run the tests'),
        ],
        last: 0,
      ),
    ]);
    await open(tester, engine);

    expect(find.text('NO TRANSCRIPT'), findsNothing);
    expect(find.text('denied'), findsOneWidget);

    await tester.pump(AgentChatScreen.interval);
    await tester.pump();

    expect(engine.asked, 2);
    expect(find.text('run the tests'), findsOneWidget);
    expect(find.text('denied'), findsNothing);
    await unmount(tester);
  });

  testWidgets('an agent with no transcript is not asked again', (tester) async {
    final engine = _Engine([
      const EngineRefused('unsupported', 'opencode keeps no transcript'),
    ]);
    await open(tester, engine);

    expect(find.text('NO TRANSCRIPT'), findsOneWidget);

    await tester.pump(AgentChatScreen.interval);
    await tester.pump();

    expect(engine.asked, 1);
    expect(find.text('NO TRANSCRIPT'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('the chat asks only while it is on screen', (tester) async {
    final engine = _Engine([(items: const <TranscriptItem>[], last: null)]);
    await open(tester, engine);
    final opened = engine.watched;
    expect(opened, greaterThan(0));

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 30));
    expect(engine.watched, opened);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(engine.watched, opened + 1);

    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(builder: (_) => const SizedBox.expand()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    final covered = engine.watched;
    await tester.pump(const Duration(seconds: 30));
    expect(engine.watched, covered);

    navigator.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(engine.watched, covered + 1);
    await unmount(tester);
  });
}
