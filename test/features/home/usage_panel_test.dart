import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/application/agents/agent_usage.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/design/colors.dart';
import 'package:upgrade/design/components/panel.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/features/home/agent_mark.dart';
import 'package:upgrade/features/home/usage_panel.dart';
import 'package:upgrade/platform/herdr/engine_agents.dart';

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
  String account = 'fixture@localhost',
  Duration age = const Duration(minutes: 2),
}) => AgentUsage(
  agent: 'codex',
  account: account,
  plan: 'pro',
  captured: _now.subtract(age),
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
    expect(find.text('NYX'), findsNothing);
    expect(find.text('2m ago'), findsOneWidget);
    expect(find.text('fixture@localhost'), findsOneWidget);
    expect(find.byType(AgentMark), findsOneWidget);
    expect(find.text('5H'), findsOneWidget);
    expect(find.text('12%'), findsOneWidget);
    expect(find.text('↻ 4H'), findsOneWidget);
    expect(find.text('WEEK'), findsOneWidget);
    expect(find.text('↻ 1D'), findsOneWidget);
    expect(find.text('34%'), findsOneWidget);
    expect(find.text('TODAY'), findsNothing);
  });

  testWidgets('accounts pair up only when two columns fit', (tester) async {
    final both = [
      (host: _nyx, usage: _codex()),
      (host: _nyx, usage: _codex(fiveHour: 50, account: 'other@localhost')),
    ];
    double top(int index) =>
        tester.getTopLeft(find.byType(AgentMark).at(index)).dy;

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

  testWidgets('a window is in its agent\'s colour until it reads 90%', (
    tester,
  ) async {
    await _pump(tester, [(host: _nyx, usage: _codex(fiveHour: 89.6))]);
    final tokens = tester.element(find.byType(UsagePanel)).tokens;
    Color? colour(String text) =>
        tester.widget<Text>(find.text(text).last).style?.color;

    expect(colour('90%'), tokens.danger);
    expect(colour('34%'), agentBrandColor('codex'));
  });

  testWidgets('the days are what the host saw the week rise by', (
    tester,
  ) async {
    final week = _now.add(const Duration(days: 1));
    final usage = _codex();
    await _pump(tester, [
      (
        host: _nyx,
        usage: AgentUsage(
          agent: usage.agent,
          plan: usage.plan,
          captured: usage.captured,
          limits: usage.limits,
          history: [
            UsageSample(
              at: _now.subtract(const Duration(days: 2)),
              usedPercent: 10,
              resetsAt: week,
            ),
            UsageSample(
              at: _now.subtract(const Duration(hours: 20)),
              usedPercent: 30,
              resetsAt: week,
            ),
            UsageSample(
              at: _now.subtract(const Duration(hours: 1)),
              usedPercent: 34,
              resetsAt: week,
            ),
          ],
        ),
      ),
    ]);

    expect(find.text('TODAY'), findsOneWidget);
    expect(find.text('4%'), findsOneWidget);
    expect(find.text('YESTERDAY'), findsOneWidget);
    expect(find.text('20%'), findsOneWidget);
    final tokens = tester.element(find.byType(UsagePanel)).tokens;
    expect(tester.widget<Text>(find.text('20%')).style?.color, tokens.warning);
  });

  test('a day rises by its own samples and starts over at a reset', () {
    final from = DateTime(2026, 10, 18);
    final to = DateTime(2026, 10, 19);
    final first = DateTime(2026, 10, 20);
    final second = DateTime(2026, 10, 27);
    UsageSample at(int hour, double used, DateTime resets) => UsageSample(
      at: from.add(Duration(hours: hour)),
      usedPercent: used,
      resetsAt: resets,
    );

    expect(usageRise(const [], from, to), isNull);
    expect(usageRise([at(30, 5, first)], from, to), isNull);
    expect(
      usageRise(
        [
          at(-3, 80, first),
          at(2, 90, first),
          at(5, 3, second),
          at(9, 7, second),
          at(26, 20, second),
        ],
        from,
        to,
      ),
      closeTo(10 + 3 + 4, 1e-9),
    );
  });

  test('a reset time that drifts between reads does not start a window', () {
    final from = DateTime(2026, 10, 18);
    final to = DateTime(2026, 10, 19);
    UsageSample at(int minute, double used) {
      final read = from.add(Duration(minutes: minute));
      return UsageSample(
        at: read,
        usedPercent: used,
        resetsAt: read.add(const Duration(days: 1)),
      );
    }

    expect(
      usageRise([at(0, 34), at(1, 34), at(2, 35), at(3, 35)], from, to),
      closeTo(1, 1e-9),
    );
  });

  test('an account read on two hosts is one card, the fresher read', () {
    const rose = Host(
      id: 'h2',
      name: 'rose',
      address: '100.64.0.2',
      port: 22,
      user: 'dev',
      keyId: 'key-1',
    );
    final stale = _codex(age: const Duration(minutes: 9));
    final fresh = _codex(fiveHour: 40);
    final other = _codex(account: 'other@localhost');

    expect(
      usageAccounts([
        (host: _nyx, usage: stale),
        (host: rose, usage: fresh),
        (host: rose, usage: other),
      ]),
      [fresh, other],
    );
    final failed = fresh.failing('NOT REACHED');
    expect(
      usageAccounts([(host: _nyx, usage: failed), (host: rose, usage: fresh)]),
      [fresh],
    );
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
