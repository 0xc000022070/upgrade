import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:striked/app/static_surface.dart';
import 'package:striked/application/agents/agents.dart';
import 'package:striked/design/components/list_row.dart';
import 'package:striked/design/components/panel.dart';
import 'package:striked/design/components/panel_text_action.dart';
import 'package:striked/design/components/section.dart';
import 'package:striked/design/components/screen_scaffold.dart';
import 'package:striked/features/settings/key_detail_screen.dart';
import 'package:striked/features/settings/key_form_screen.dart';

void openKeys(BuildContext context) {
  Navigator.of(
    context,
    rootNavigator: true,
  ).push(MaterialPageRoute<void>(builder: (_) => const KeysScreen()));
}

class KeysScreen extends ConsumerWidget {
  const KeysScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final keys = ref.watch(managedKeysProvider);
    return Scaffold(
      body: StaticSurface(
        child: ScreenScaffold(
          title: 'KEYS',
          breadcrumb: '/ PERSONAL CONTROL PLANE / HOSTS',
          onBack: () => Navigator.of(context).pop(),
          children: [
            PanelStack(
              children: [
                Panel(
                  title: 'SSH KEYS',
                  bodyPadding: panelRowsPadding,
                  child: AsyncSection(
                    value: keys,
                    empty: 'no keys',
                    builder: (items) => ListRowGroup(
                      children: [
                        for (final key in items)
                          ListRow(
                            title: key.name,
                            subtitle: shortFingerprint(key.fingerprint),
                            node: true,
                            onTap: () => openKeyDetail(context, key),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            PanelTextAction(label: 'ADD KEY', onTap: () => openNewKey(context)),
          ],
        ),
      ),
    );
  }
}

String shortFingerprint(String fingerprint) {
  const limit = 28;
  if (fingerprint.length <= limit) return fingerprint;
  return '${fingerprint.substring(0, limit)}…';
}
