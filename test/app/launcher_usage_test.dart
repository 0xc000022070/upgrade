import 'package:flutter_test/flutter_test.dart';
import 'package:striked/app/launcher_widget_host.dart';
import 'package:striked/data/repositories/host_repository.dart';
import 'package:striked/platform/herdr/engine_agents.dart';

const _nyx = Host(
  id: 'nyx',
  name: 'nyx',
  address: '100.64.0.1',
  port: 22,
  user: 'dev',
  keyId: 'k1',
);

void main() {
  test('the launcher gets each account with its first limit only', () {
    final resets = DateTime.utc(2026, 10, 18, 15);
    final captured = DateTime.utc(2026, 10, 18, 12);
    final now = DateTime(2026, 10, 18, 13);
    final day = DateTime(2026, 10, 18).millisecondsSinceEpoch;
    final rows = launcherUsage([
      (
        host: _nyx,
        usage: AgentUsage(
          agent: 'codex',
          plan: 'pro',
          captured: captured,
          limits: [
            UsageLimit(
              id: 'codex',
              reached: true,
              windows: [
                UsageWindow(usedPercent: 99.6, minutes: 300, resetsAt: resets),
                const UsageWindow(usedPercent: 40, minutes: 10080),
              ],
            ),
            const UsageLimit(
              id: 'spark',
              windows: [UsageWindow(usedPercent: 5, minutes: 300)],
            ),
          ],
        ),
      ),
      (
        host: _nyx,
        usage: AgentUsage(
          agent: 'claude',
          limits: const [
            UsageLimit(id: 'claude', windows: [UsageWindow(usedPercent: 12)]),
          ],
          history: [
            UsageSample(
              at: now.subtract(const Duration(days: 2)),
              usedPercent: 30,
            ),
            UsageSample(
              at: now.subtract(const Duration(hours: 2)),
              usedPercent: 40.4,
            ),
          ],
        ),
      ),
    ], now);

    expect(rows, [
      {
        'agent': 'codex',
        'name': 'CODEX · PRO',
        'host': 'NYX',
        'captured': captured.millisecondsSinceEpoch,
        'day': day,
        'windows': [
          {
            'label': '5H',
            'used': 100,
            'share': 99.6,
            'minutes': 300,
            'resets': resets.millisecondsSinceEpoch,
            'hit': true,
          },
          {
            'label': 'WEEK',
            'used': 40,
            'share': 40.0,
            'minutes': 10080,
            'hit': false,
          },
        ],
      },
      {
        'agent': 'claude',
        'name': 'CLAUDE',
        'host': 'NYX',
        'day': day,
        'today': 10,
        'yesterday': 0,
        'windows': [
          {'label': '', 'used': 12, 'share': 12.0, 'hit': false},
        ],
      },
    ]);
  });
}
