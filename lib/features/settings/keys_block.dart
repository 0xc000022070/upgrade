import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/agents.dart';
import '../../data/repositories/key_repository.dart';
import '../../design/components/list_row.dart';
import '../../design/components/panel.dart';
import '../../design/components/section.dart';
import '../../design/icons/hotline_icons.dart';
import 'key_detail_screen.dart';
import 'key_form_screen.dart';

class KeysSettingsBlock extends ConsumerWidget {
  const KeysSettingsBlock({super.key, this.onNew, this.onOpen});

  final VoidCallback? onNew;
  final ValueChanged<ManagedKey>? onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final keys = ref.watch(managedKeysProvider);
    return Panel(
      title: '[ KEYS ]',
      affordance: PanelAffordance(
        'NEW',
        icon: HotlineIcons.add,
        onTap: onNew ?? () => openNewKey(context),
      ),
      bodyPadding: panelRowsPadding,
      child: AsyncSection(
        value: keys,
        empty: 'no keys',
        builder: (items) => ListRowGroup(
          children: [
            for (final key in items)
              ListRow(
                title: key.name,
                subtitle: _shortFingerprint(key.fingerprint),
                node: true,
                onTap: () {
                  final callback = onOpen;
                  if (callback == null) {
                    openKeyDetail(context, key);
                  } else {
                    callback(key);
                  }
                },
              ),
          ],
        ),
      ),
    );
  }
}

String _shortFingerprint(String fingerprint) {
  const limit = 28;
  if (fingerprint.length <= limit) return fingerprint;
  return '${fingerprint.substring(0, limit)}…';
}
