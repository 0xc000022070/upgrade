import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/platform/herdr/agent_state.dart';
import 'package:upgrade/application/agents/agents.dart';
import 'package:upgrade/application/hosts/host_providers.dart';
import 'package:upgrade/application/providers.dart';
import 'package:upgrade/data/database.dart';
import 'package:upgrade/data/enums.dart';
import 'package:upgrade/data/repositories/dispatch_repository.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/data/repositories/path_repository.dart';
import 'package:upgrade/features/agents/sent_screen.dart';
import 'package:upgrade/platform/herdr/engine_agents.dart';
import 'package:upgrade/platform/herdr/herdr_client.dart';

import '../../support/native_plugins.dart';
import '../../support/platform_channels.dart';
import '../../support/themed_app.dart';

Dispatch _send(
  String id,
  String text, {
  DispatchStatus status = DispatchStatus.sent,
  String? failure,
  String? engineSession,
  List<SeenState> states = const [],
}) => Dispatch(
  id: id,
  pathId: 'path-1',
  hostId: 'host-1',
  hostName: 'oak',
  label: 'upgrade',
  directory: '~/src/upgrade',
  text: text,
  agent: 'claude',
  paneId: 'p1',
  herdrSession: 'main',
  sentAt: DateTime.now().toUtc().subtract(const Duration(minutes: 5)),
  status: status,
  failure: failure,
  engineSession: engineSession,
  states: states,
);

const _oak = Host(
  id: 'host-1',
  name: 'oak',
  address: '198.51.100.77',
  port: 22,
  user: 'developer',
  keyId: 'k1',
);

AgentSnapshot _agent({AgentApproval? approval, String? question}) =>
    AgentSnapshot(
      session: 'engine',
      paneId: 'claude:s1',
      agent: 'claude',
      state: AgentState.of('working'),
      terminalTitleStripped: '',
      workspaceId: '',
      cwd: '~/src/upgrade',
      stateChangeSeq: 1,
      herdrPane: 'p1',
      approval: approval,
      question: question,
    );

const _run = (
  items: [
    TranscriptItem(index: 0, kind: 'user', text: 'fix the gate'),
    TranscriptItem(index: 1, kind: 'assistant', text: 'the gate passes'),
  ],
  last: 1,
);

class _Session implements HerdrSession {
  @override
  void close() {}

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Engine implements EngineAgents {
  _Engine(this.reads, {List<AgentSnapshot>? agents})
    : agents = agents ?? [_agent()];

  final List<Object> reads;
  List<AgentSnapshot> agents;
  Object? refusal;
  final answers = <(String, bool)>[];
  var asked = 0;
  var watched = 0;

  @override
  final HerdrSession session = _Session();

  @override
  String get owner => 'developer';

  @override
  Future<EngineWatch> watch({
    int? generation,
    Duration wait = Duration.zero,
  }) async {
    watched++;
    return (generation: 1, agents: agents);
  }

  @override
  Future<TranscriptPage> transcript(String key, {int? after}) async {
    final read = reads[asked < reads.length ? asked : reads.length - 1];
    asked++;
    if (read is EngineRefused) throw read;
    return read as TranscriptPage;
  }

  @override
  Future<void> answer(String id, {required bool allow}) async {
    answers.add((id, allow));
    if (refusal case final Object refusal) throw refusal;
  }

  @override
  Future<List<HookStatus>> hooks() async => const [];

  @override
  Future<void> install(String agent) async {}

  @override
  Future<List<AgentUsage>> usage({bool fresh = false}) async => const [];
}

void main() {
  late AppDatabase db;

  setUp(() {
    stubDeviceChannels();
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() => db.close());

  testWidgets('each send is a row with its state, first line and target', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        retry: noRetry,
        overrides: [
          staticEnabledProvider.overrideWith((ref) => Stream.value(false)),
          sendsProvider.overrideWith(
            (ref) => Stream.value([
              _send(
                's2',
                'fix the gate\nthen run it',
                states: [(state: 'done', at: DateTime.utc(2026, 10))],
              ),
              _send(
                's1',
                'read the log',
                status: DispatchStatus.failed,
                failure: 'key rejected',
              ),
            ]),
          ),
          pathTargetsProvider.overrideWith(
            (ref) => Stream.value(const <PathTarget>[]),
          ),
          agentsFeedLiveProvider.overrideWithValue(false),
        ],
        child: MaterialApp(theme: testTheme, home: const SentScreen()),
      ),
    );
    await tester.pump();

    expect(find.text('fix the gate'), findsOneWidget);
    expect(find.text('oak · upgrade · claude'), findsNWidgets(2));
    expect(find.textContaining('DONE'), findsOneWidget);
    expect(find.textContaining('FAILED'), findsOneWidget);
    expect(find.text('KEY REJECTED'), findsOneWidget);
    expect(find.textContaining('5m'), findsNWidgets(2));
  });

  group('run screen', () {
    Future<void> open(
      WidgetTester tester,
      _Engine engine, {
      String? engineSession = 'claude:s1',
    }) async {
      final send = _send('s1', 'fix the gate', engineSession: engineSession);
      await tester.pumpWidget(
        ProviderScope(
          retry: noRetry,
          overrides: [
            ...featureTestOverrides(db),
            staticEnabledProvider.overrideWith((ref) => Stream.value(false)),
            sendProvider('s1').overrideWith((ref) => Stream.value(send)),
            hostIntegrationsProvider('host-1')
                .overrideWith((ref) => Stream.value({IntegrationKind.agents})),
            registeredHostProvider('host-1').overrideWith((ref) => _oak),
            agentsFeedLiveProvider.overrideWithValue(false),
            engineOpenProvider.overrideWithValue((_) async => engine),
          ],
          child: MaterialApp(
            theme: testTheme,
            home: const RunScreen(sendId: 's1'),
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

    testWidgets('the linked session transcript shows as steps', (tester) async {
      final engine = _Engine([_run]);
      await open(tester, engine);

      expect(find.text('STEPS'), findsOneWidget);
      expect(find.text('the gate passes'), findsOneWidget);
      expect(find.text('CONVERSATION'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('an unlinked send finds its session by the first prompt', (
      tester,
    ) async {
      final engine = _Engine([
        _run,
        (items: const <TranscriptItem>[], last: 1),
      ]);
      await open(tester, engine, engineSession: null);

      expect(find.text('the gate passes'), findsOneWidget);
      expect(engine.asked, 2);
      await unmount(tester);
    });

    testWidgets('the run asks only while it is on screen', (tester) async {
      final engine = _Engine([_run]);
      await open(tester, engine);
      final opened = engine.watched;
      expect(opened, greaterThan(0));

      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pump(const Duration(seconds: 30));
      expect(engine.watched, opened);

      for (final state in [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
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

    testWidgets('ALLOW answers the approval and says so', (tester) async {
      const approval = AgentApproval(id: 'a1', tool: 'Bash', summary: 'rm x');
      final engine = _Engine([_run], agents: [_agent(approval: approval)]);
      await open(tester, engine);

      expect(find.text('Bash · rm x'), findsOneWidget);
      await tester.tap(find.text('ALLOW'));
      await tester.pump();
      await tester.pump();

      expect(engine.answers, [('a1', true)]);
      expect(find.text('ALLOWED'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('DENY on an answered approval says it was answered', (
      tester,
    ) async {
      const approval = AgentApproval(id: 'a1', tool: 'Bash', summary: '');
      final engine = _Engine([_run], agents: [_agent(approval: approval)])
        ..refusal = const EngineRefused('not_found', 'gone');
      await open(tester, engine);

      await tester.tap(find.text('DENY'));
      await tester.pump();
      await tester.pump();

      expect(engine.answers, [('a1', false)]);
      expect(find.text('ALREADY ANSWERED'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('the bar shows the question the agent is asking', (
      tester,
    ) async {
      final engine = _Engine(
        [_run],
        agents: [_agent(question: 'Which branch should I push?')],
      );
      await open(tester, engine);

      expect(find.text('Which branch should I push?'), findsOneWidget);
      expect(find.text('ALLOW'), findsNothing);
      await unmount(tester);
    });

    testWidgets('a session the host no longer lists is gone for good', (
      tester,
    ) async {
      final engine = _Engine([
        const EngineRefused('not_found', 'no session'),
      ], agents: []);
      await open(tester, engine);

      expect(find.text('SESSION GONE'), findsOneWidget);
      expect(find.text('CONVERSATION'), findsNothing);
      final watched = engine.watched;
      await tester.pump(RunScreen.interval * 3);
      await tester.pump();
      expect(engine.watched, watched);
      await unmount(tester);
    });

    testWidgets('a listed session without a transcript keeps being asked', (
      tester,
    ) async {
      final engine = _Engine([const EngineRefused('not_found', 'no file')]);
      await open(tester, engine);

      expect(find.text('NO TRANSCRIPT YET'), findsOneWidget);
      final watched = engine.watched;
      await tester.pump(RunScreen.interval);
      await tester.pump();
      expect(engine.watched, watched + 1);
      await unmount(tester);
    });

    testWidgets('an agent that keeps no transcript stops the asking', (
      tester,
    ) async {
      final engine = _Engine([const EngineRefused('unsupported', 'none')]);
      await open(tester, engine);

      expect(find.textContaining('KEEPS NO TRANSCRIPT'), findsOneWidget);
      final watched = engine.watched;
      await tester.pump(RunScreen.interval * 3);
      await tester.pump();
      expect(engine.watched, watched);
      await unmount(tester);
    });
  });
}
