import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:striked/application/agents/agents.dart';
import 'package:striked/application/providers.dart';
import 'package:striked/data/enums.dart';
import 'package:striked/data/repositories/dispatch_repository.dart';
import 'package:striked/data/repositories/path_repository.dart';
import 'package:striked/features/agents/sent_screen.dart';

import '../../support/themed_app.dart';

Dispatch _send(
  String id,
  String text, {
  DispatchStatus status = DispatchStatus.sent,
  String? failure,
  List<SeenState> states = const [],
}) => Dispatch(
  id: id,
  pathId: 'path-1',
  hostId: 'host-1',
  hostName: 'nyx',
  label: 'striked',
  directory: '~/src/striked',
  text: text,
  agent: 'claude',
  paneId: 'p1',
  herdrSession: 'main',
  sentAt: DateTime.now().toUtc().subtract(const Duration(minutes: 5)),
  status: status,
  failure: failure,
  states: states,
);

void main() {
  testWidgets('each send is a row with its state, first line and target', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
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
    expect(find.text('nyx · striked · claude'), findsNWidgets(2));
    expect(find.textContaining('DONE'), findsOneWidget);
    expect(find.textContaining('FAILED'), findsOneWidget);
    expect(find.text('KEY REJECTED'), findsOneWidget);
    expect(find.textContaining('5m'), findsNWidgets(2));
  });
}
