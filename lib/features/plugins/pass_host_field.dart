import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/application/hosts/host_providers.dart';
import 'package:upgrade/application/plugins/pass_access.dart';
import 'package:upgrade/design/components/action_block.dart';
import 'package:upgrade/design/components/panel_sheet.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/design/tokens.dart';

class PassHostField extends ConsumerWidget {
  const PassHostField({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chosen = ref.watch(passHostProvider).value;
    final hosts = ref.watch(hostsProvider).value ?? const [];
    final tokens = context.tokens;
    final status = chosen == null
        ? 'NONE CHOSEN'
        : 'PASS ON ${hosts.where((h) => h.id == chosen).firstOrNull?.name.toUpperCase() ?? 'A REMOVED HOST'}';
    Widget note(String text) => Padding(
      padding: const EdgeInsets.only(top: Spacing.sm),
      child: Text(text, style: tokens.rowSubtitle),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.lg),
      child: SheetField(
        label: 'PASS HOST',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(status, style: tokens.rowTitle),
            note(
              'Its gpg-agent must already decrypt without asking: the app never types a passphrase.',
            ),
            if (hosts.isEmpty) note('No hosts in MACHINES yet.'),
            const SizedBox(height: Spacing.sm),
            Wrap(
              spacing: Spacing.md,
              children: [
                for (final host in hosts)
                  ActionBlock(
                    label: host.name.toUpperCase(),
                    tone: tokens.accent,
                    filled: chosen == host.id,
                    onTap: () => usePassHost(ref, host.id),
                  ),
                if (chosen != null)
                  ActionBlock(
                    label: 'FORGET HOST',
                    onTap: () => forgetPassHost(ref),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
