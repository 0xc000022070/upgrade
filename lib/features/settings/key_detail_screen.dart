import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/static_surface.dart';
import '../../application/agents.dart';
import '../../data/repositories/key_repository.dart';
import '../../design/tokens.dart';
import '../../design/components/list_row.dart';
import '../../design/components/panel.dart';
import '../../design/components/panel_sheet.dart';
import '../../design/spacing.dart';
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
      // The pre-check above is read from a stream; the repository refuses in a transaction
      // against the table itself. A host registered between the two is caught here, and the
      // private key is deliberately not dropped: the row it belongs to still exists.
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
          breadcrumb: '/ PERSONAL CONTROL PLANE / HOSTS / KEYS',
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
                    style: context.tokens.rowTitle,
                  ),
                ),
                Panel(
                  title: '[ USED BY ]',
                  bodyPadding: panelRowsPadding,
                  child: users.isEmpty
                      ? SizedBox(
                          height: RowMetrics.minHeight,
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              'NO HOSTS',
                              style: context.tokens.label,
                            ),
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
            _DeleteBar(
              label: _deleteLabel(users.length),
              enabled: canDelete,
              onTap: () => _delete(context, ref),
            ),
          ],
        ),
      ),
    );
  }
}

String _deleteLabel(int users) => switch (users) {
  0 => 'DELETE',
  1 => 'USED BY 1 HOST',
  _ => 'USED BY $users HOSTS',
};

class _DeleteBar extends StatelessWidget {
  const _DeleteBar({
    required this.label,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tone = enabled ? context.tokens.warning : context.tokens.textDisabled;
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
          label,
          style: context.tokens.valueStrong.copyWith(color: tone),
        ),
      ),
    );
  }
}
