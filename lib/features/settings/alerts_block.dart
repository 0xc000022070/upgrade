import 'dart:async';

import 'package:upgrade_shade/upgrade_shade.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/application/alerts.dart';
import 'package:upgrade/application/providers.dart';
import 'package:upgrade/design/components/panel.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/platform/agent_watcher.dart';
import 'package:upgrade/platform/pin_notifications.dart';

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
          const _DndRow(),
        ],
      ),
    );
  }
}

class _DndRow extends StatefulWidget {
  const _DndRow();

  @override
  State<_DndRow> createState() => _DndRowState();
}

class _DndRowState extends State<_DndRow> with WidgetsBindingObserver {
  bool _granted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_refresh());
  }

  Future<void> _refresh() async {
    final granted = await _ask(UpgradeShade.dndAccess) ?? false;
    if (granted && !_granted) await PinNotifications.createChannel();
    if (mounted && granted != _granted) setState(() => _granted = granted);
  }

  static Future<T?> _ask<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on Object catch (error) {
      debugPrint('upgrade.dnd: $error');
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: SwitchListTile.adaptive(
        contentPadding: EdgeInsets.zero,
        title: Text(
          'PASSPHRASES IN DO NOT DISTURB',
          style: context.tokens.rowTitle,
        ),
        subtitle: _granted
            ? null
            : Text(
                'SILENT UNDER DO NOT DISTURB',
                style: context.tokens.rowSubtitle,
              ),
        value: _granted,
        onChanged: (_) => unawaited(_ask(UpgradeShade.askDndAccess)),
      ),
    );
  }
}
