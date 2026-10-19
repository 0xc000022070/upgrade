import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:striked/application/agents/agent_usage.dart';
import 'package:striked/data/repositories/host_repository.dart';
import 'package:striked/design/components/panel.dart';
import 'package:striked/design/tokens.dart';
import 'package:striked/features/home/agent_mark.dart';
import 'package:striked/features/home/usage_panel.dart';
import 'package:striked/platform/herdr/engine_agents.dart';

import '../../support/themed_app.dart';

const _nyx = Host(
  id: 'h1',
  name: 'nyx',
  address: '100.64.0.1',
  port: 22,
  user: 'dev',
  keyId: 'key-1',
);

final _now = DateTime(2026, 10, 18, 12);

Future<void> _pump(WidgetTester tester, List<HostUsage> usages) =>
    tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: testTheme,
          home: Scaffold(
            body: UsagePanel(usages: usages, now: _now),
          ),
        ),
      ),
    );

AgentUsage _codex({
  double fiveHour = 12,
  bool reached = false,
  String? error,
}) => AgentUsage(
  agent: 'codex',
  account: 'fixture@localhost',
  plan: 'pro',
  captured: _now.subtract(const Duration(minutes: 2)),
  error: error,
  limits: [
    UsageLimit(
      id: 'codex',
      reached: reached,
      windows: [
        UsageWindow(
          usedPercent: fiveHour,
          minutes: 300,
          resetsAt: _now.add(const Duration(hours: 4)),
        ),
        UsageWindow(
          usedPercent: 34,
          minutes: 10080,
          resetsAt: _now.add(const Duration(days: 1)),
        ),
      ],
    ),
  ],
);

void main() {
  testWidgets('no account, no panel', (tester) async {
    await _pump(tester, const []);

    expect(find.byType(Panel), findsNothing);
  });

  testWidgets('an account shows its plan, host and every window', (
    tester,
  ) async {
    await _pump(tester, [(host: _nyx, usage: _codex())]);

    expect(find.byType(Panel), findsOneWidget);
    expect(find.text('CODEX · PRO'), findsOneWidget);
    expect(find.text('NYX · 2m ago'), findsOneWidget);
    expect(find.text('fixture@localhost'), findsOneWidget);
    expect(find.byType(AgentMark), findsOneWidget);
    expect(find.text('5H'), findsOneWidget);
    expect(find.text('12%'), findsOneWidget);
    expect(find.text('↻ 4H'), findsOneWidget);
    expect(find.text('WEEK'), findsOneWidget);
    expect(find.text('↻ 1D'), findsOneWidget);
    expect(
      find.descendant(of: find.byType(UsageRing), matching: find.text('34%')),
      findsOneWidget,
    );
    expect(find.text('34%'), findsNWidgets(2));
  });

  testWidgets('accounts pair up only when two columns fit', (tester) async {
    final both = [
      (host: _nyx, usage: _codex()),
      (host: _nyx, usage: _codex(fiveHour: 50)),
    ];
    double top(int index) =>
        tester.getTopLeft(find.byType(UsageRing).at(index)).dy;

    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _pump(tester, both);
    expect(top(1), greaterThan(top(0)));

    tester.view.physicalSize = const Size(900, 900);
    await _pump(tester, both);
    expect(top(1), top(0));
  });

  testWidgets('a failed read keeps the last windows and says why', (
    tester,
  ) async {
    await _pump(tester, [
      (host: _nyx, usage: _codex(error: 'failed to fetch codex rate limits')),
    ]);

    expect(find.text('12%'), findsOneWidget);
    expect(find.text('failed to fetch codex rate limits'), findsOneWidget);
  });

  testWidgets('a window that reads 90% is in danger', (tester) async {
    await _pump(tester, [(host: _nyx, usage: _codex(fiveHour: 89.6))]);
    final tokens = tester.element(find.byType(UsagePanel)).tokens;
    Color? colour(String text) =>
        tester.widget<Text>(find.text(text).last).style?.color;

    expect(colour('90%'), tokens.danger);
    expect(colour('34%'), isNot(tokens.danger));
  });

  test('a reached limit lands on the window that is full', () {
    const five = UsageWindow(usedPercent: 100, minutes: 300);
    const week = UsageWindow(usedPercent: 40, minutes: 10080);
    const limit = UsageLimit(id: 'codex', reached: true, windows: [five, week]);

    expect(limitHit(limit, five), isTrue);
    expect(limitHit(limit, week), isFalse);
    const unnamed = UsageLimit(id: 'codex', reached: true, windows: [week]);
    expect(limitHit(unnamed, week), isTrue);
    expect(
      limitHit(const UsageLimit(id: 'codex', windows: [five]), five),
      isFalse,
    );
  });

  test('pace is how far the window has run', () {
    final window = UsageWindow(
      usedPercent: 50,
      minutes: 300,
      resetsAt: _now.add(const Duration(hours: 4)),
    );

    expect(windowPace(window, _now), closeTo(0.2, 1e-9));
    expect(
      windowPace(const UsageWindow(usedPercent: 1, minutes: 300), _now),
      isNull,
    );
  });

  test('a window is named by its length', () {
    expect(windowLabel(300), '5H');
    expect(windowLabel(10080), 'WEEK');
    expect(windowLabel(1440), '1D');
    expect(windowLabel(45), '45M');
    expect(windowLabel(null), isEmpty);
  });
}
