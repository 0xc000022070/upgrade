import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/alerts.dart';
import '../../application/providers.dart';
import '../../data/repositories/settings_repository.dart';
import '../../design/components/panel.dart';
import '../../design/components/picker_row.dart';
import '../../platform/agent_watcher.dart';

class AlertsSettingsBlock extends ConsumerWidget {
  const AlertsSettingsBlock({super.key, this.requestPermission});

  /// Injected so the row can be driven in a widget test, which has no OS to ask.
  final Future<bool> Function()? requestPermission;

  Future<void> _toggle(WidgetRef ref, AlertsRow row) async {
    final settings = ref.read(settingsRepositoryProvider);
    if (row == AlertsRow.on) {
      await settings.setFlag(SettingsRepository.alertsBlockedAgents, false);
      return;
    }
    // The refusal is not written to the settings row: the OS is the record, and it can be
    // granted from outside the app.
    final granted =
        await (requestPermission ?? AgentWatcher.requestPermission)();
    ref.read(alertsDeniedProvider.notifier).state = !granted;
    if (!granted) return;
    await settings.setFlag(SettingsRepository.alertsBlockedAgents, true);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final row = ref.watch(alertsRowProvider);
    return Panel(
      title: '[ ALERTS ]',
      bodyPadding: panelRowsPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PickerRow(
            label: 'BLOCKED AGENTS',
            value: 'OFF',
            subtitle: row.subtitle,
            selected: row == AlertsRow.on,
            dim: !row.interactive,
            onTap: row.interactive ? () => _toggle(ref, row) : () {},
          ),
        ],
      ),
    );
  }
}
