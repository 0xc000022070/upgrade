import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/alerts.dart';
import '../../application/providers.dart';
import '../../design/components/panel.dart';
import '../../design/tokens.dart';
import '../../platform/agent_watcher.dart';

class AlertsSettingsBlock extends ConsumerWidget {
  const AlertsSettingsBlock({super.key, this.requestPermission});

  /// Injected so the row can be driven in a widget test, which has no OS to ask.
  final Future<bool> Function()? requestPermission;

  Future<void> _toggle(WidgetRef ref, AlertKind kind, AlertsRow row) async {
    final settings = ref.read(settingsRepositoryProvider);
    if (row == AlertsRow.on) {
      await settings.setFlag(kind.settingsKey, false);
      return;
    }
    // The refusal is not written to the settings row: the OS is the record, and it can be
    // granted from outside the app.
    final granted =
        await (requestPermission ?? AgentWatcher.requestPermission)();
    ref
        .read(alertsDeniedProvider.notifier)
        .update(
          (denied) =>
              granted ? (denied.toSet()..remove(kind)) : {...denied, kind},
        );
    if (!granted) return;
    await settings.setFlag(kind.settingsKey, true);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Panel(
      title: '[ ALERTS ]',
      bodyPadding: panelRowsPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final kind in AlertKind.values)
            Consumer(
              builder: (context, ref, _) {
                final row = ref.watch(alertsRowProvider(kind));
                return Material(
                  type: MaterialType.transparency,
                  child: SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      kind.label,
                      style: context.tokens.rowTitle.copyWith(
                        color: row.interactive
                            ? context.tokens.textPrimary
                            : context.tokens.textMuted,
                      ),
                    ),
                    subtitle: row.subtitle == null
                        ? null
                        : Text(
                            row.subtitle!,
                            style: context.tokens.rowSubtitle,
                          ),
                    value: row == AlertsRow.on,
                    onChanged: row.interactive
                        ? (_) => _toggle(ref, kind, row)
                        : null,
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}
