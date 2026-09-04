import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/static_surface.dart';
import '../../application/agents.dart';
import '../../data/repositories/key_repository.dart';
import '../../design/colors.dart';
import '../../design/components/list_row.dart';
import '../../design/components/panel.dart';
import '../../design/components/panel_sheet.dart';
import '../../design/spacing.dart';
import '../../design/typography.dart';
import '../screen_scaffold.dart';

void openKeyDetail(BuildContext context, ManagedKey key) {
  Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute<void>(builder: (_) => KeyDetailScreen(keyRecord: key)),
  );
}

class KeyDetailScreen extends ConsumerWidget {
  const KeyDetailScreen({super.key, required this.keyRecord});

  final ManagedKey keyRecord;

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final confirmed = await confirmSheet(
      context,
      title: 'DELETE KEY?',
      confirmLabel: 'DELETE',
    );
    if (!confirmed || !context.mounted) return;
    final hosts = await ref.read(hostRepositoryProvider).all();
    if (hosts.any((host) => host.keyId == keyRecord.id)) return;
    try {
      await ref.read(keyRepositoryProvider).delete(keyRecord.id);
    } on KeyInUseException {
      // The pre-check above is what greys the bar out and is read from a
      // stream; the repository refuses in a transaction against the table
      // itself. A host registered between the two is caught here, and the
      // private key is deliberately not dropped: the row it belongs to still
      // exists.
      return;
    }
    await ref.read(ed25519KeysProvider).delete(keyRecord.id);
    if (context.mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hosts = ref.watch(hostsProvider);
    final users =
        hosts.valueOrNull
            ?.where((host) => host.keyId == keyRecord.id)
            .toList() ??
        const [];
    final canDelete = hosts.hasValue && users.isEmpty;
    return Scaffold(
      body: StaticSurface(
        child: ScreenScaffold(
          title: 'KEY',
          breadcrumb: '/ HOTLINE / HOSTS',
          onBack: () => Navigator.of(context).pop(),
          children: [
            PanelStack(
              children: [
                Panel(title: '[ NAME ]', child: Text(keyRecord.name)),
                const Panel(title: '[ TYPE ]', child: Text('ed25519')),
                Panel(
                  title: '[ PUBLIC ]',
                  affordance: PanelAffordance(
                    'COPY',
                    showIcon: false,
                    onTap: () => Clipboard.setData(
                      ClipboardData(text: keyRecord.publicKey),
                    ),
                  ),
                  child: SelectableText(
                    keyRecord.publicKey,
                    style: HotlineText.rowTitle,
                  ),
                ),
                Panel(
                  title: '[ USED BY ]',
                  bodyPadding: panelRowsPadding,
                  child: users.isEmpty
                      ? const SizedBox(
                          height: RowMetrics.minHeight,
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text('NO HOSTS', style: HotlineText.label),
                          ),
                        )
                      : ListRowGroup(
                          children: [
                            for (final host in users) ListRow(title: host.name),
                          ],
                        ),
                ),
              ],
            ),
            const SizedBox(height: Spacing.xl),
            _DeleteBar(enabled: canDelete, onTap: () => _delete(context, ref)),
          ],
        ),
      ),
    );
  }
}

class _DeleteBar extends StatelessWidget {
  const _DeleteBar({required this.enabled, required this.onTap});

  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tone = enabled ? HotlineColors.warning : HotlineColors.textDisabled;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled ? onTap : null,
      child: Container(
        height: TapTargets.minHeight,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border.all(color: tone),
          borderRadius: BorderRadius.circular(Radii.sharp),
        ),
        child: Text(
          'DELETE',
          style: HotlineText.valueStrong.copyWith(color: tone),
        ),
      ),
    );
  }
}
