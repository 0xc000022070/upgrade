import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:striked/app/static_surface.dart';
import 'package:striked/application/agents/agents.dart';
import 'package:striked/data/repositories/key_repository.dart';
import 'package:striked/design/tokens.dart';
import 'package:striked/design/components/list_row.dart';
import 'package:striked/design/components/panel.dart';
import 'package:striked/design/components/panel_sheet.dart';
import 'package:striked/design/spacing.dart';
import 'package:striked/design/components/screen_scaffold.dart';
import 'package:striked/platform/shell/remote_shell.dart';

String keyInstallLine(String publicKey) {
  final key = shellQuote(publicKey.trim());
  const file = '~/.ssh/authorized_keys';
  // The leading newline keeps a file that ends without one from running its last key
  // into this one.
  return 'mkdir -p ~/.ssh && chmod 700 ~/.ssh && '
      'grep -qxF $key $file 2>/dev/null || '
      "printf '\\n%s\\n' $key >> $file; chmod 600 $file";
}

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
                Panel(
                  title: '[ NAME ]',
                  child: Text(keyRecord.name, style: context.tokens.rowTitle),
                ),
                Panel(
                  title: '[ TYPE ]',
                  child: Text('ed25519', style: context.tokens.rowTitle),
                ),
                Panel(
                  title: '[ PUBLIC ]',
                  affordance: PanelAffordance(
                    'COPY',
                    key: const ValueKey('key-public-copy'),
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
                  title: '[ INSTALL ]',
                  affordance: PanelAffordance(
                    'COPY',
                    key: const ValueKey('key-install-copy'),
                    showIcon: false,
                    onTap: () => Clipboard.setData(
                      ClipboardData(text: keyInstallLine(keyRecord.publicKey)),
                    ),
                  ),
                  child: SelectableText(
                    keyInstallLine(keyRecord.publicKey),
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
