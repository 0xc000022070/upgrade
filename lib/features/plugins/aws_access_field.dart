import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/application/hosts/host_providers.dart';
import 'package:upgrade/application/plugins/aws_access.dart';
import 'package:upgrade/design/components/action_block.dart';
import 'package:upgrade/design/components/panel_sheet.dart';
import 'package:upgrade/design/components/upgrade_field.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/platform/aws/aws_billing.dart';

const _guide = [
  '1. In IAM, create a user with no console access, or pick the identity a host\'s aws CLI already signs in as.',
  '2. Give it the read-only policy below as an inline policy. COPY POLICY puts it on the clipboard.',
  '3. Keys on this phone: on that user, Security credentials, Create access key, Application running outside AWS. Paste both halves here.',
  '4. A host instead: sign its aws CLI in once (aws login, aws sso login or a profile), then choose the host here. Its credentials stay on the host.',
  '5. Open Cost Explorer once in the AWS console so AWS starts preparing the data; the first numbers can take a day.',
];

class AwsAccessField extends ConsumerStatefulWidget {
  const AwsAccessField({super.key});
  @override
  ConsumerState<AwsAccessField> createState() => _AwsAccessFieldState();
}

class _AwsAccessFieldState extends ConsumerState<AwsAccessField> {
  final _id = TextEditingController();
  final _secret = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _id.dispose();
    _secret.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() work) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await work();
      _id.clear();
      _secret.clear();
    } on Exception catch (error) {
      _error = '$error';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final access = ref.watch(awsAccessProvider).value;
    final hosts = ref.watch(hostsProvider).value ?? const [];
    final tokens = context.tokens;
    final status = switch (access) {
      null => 'NONE CHOSEN',
      AwsPhoneKeys(:final keys) =>
        'KEYS ON THIS PHONE · ${keys.id.substring(0, 4)}…${keys.id.substring(keys.id.length - 4)}',
      AwsHostCli(:final host) =>
        'AWS CLI ON ${hosts.where((h) => h.id == host).firstOrNull?.name.toUpperCase() ?? 'A REMOVED HOST'}',
    };
    Widget field(String label, TextEditingController controller, bool hide) =>
        UpgradeField(
          semanticLabel: label,
          controller: controller,
          hint: label,
          obscureText: hide,
          suggest: false,
          enabled: !_busy,
          contentPadding: const EdgeInsets.symmetric(vertical: Spacing.md),
        );
    Widget note(String text) => Padding(
      padding: const EdgeInsets.only(top: Spacing.sm),
      child: Text(text, style: tokens.rowSubtitle),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.lg),
      child: SheetField(
        label: 'AWS ACCESS',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(status, style: tokens.rowTitle),
            for (final step in _guide) note(step),
            const SizedBox(height: Spacing.sm),
            Wrap(
              spacing: Spacing.md,
              children: [
                ActionBlock(
                  label: 'COPY POLICY',
                  onTap: () => Clipboard.setData(
                    const ClipboardData(text: awsBillingPolicy),
                  ),
                ),
                if (access != null)
                  ActionBlock(
                    label: 'FORGET ACCESS',
                    onTap: _busy
                        ? null
                        : () => _run(() => forgetAwsAccess(ref)),
                  ),
              ],
            ),
            note('FROM A HOST'),
            if (hosts.isEmpty) note('No hosts in MACHINES yet.'),
            Wrap(
              spacing: Spacing.md,
              children: [
                for (final host in hosts)
                  ActionBlock(
                    label: host.name.toUpperCase(),
                    tone: tokens.accent,
                    filled: access is AwsHostCli && access.host == host.id,
                    onTap: _busy
                        ? null
                        : () => _run(() => useAwsHost(ref, host.id)),
                  ),
              ],
            ),
            note('OR KEYS ON THIS PHONE'),
            field('ACCESS KEY ID', _id, false),
            field('SECRET ACCESS KEY', _secret, true),
            if (_error != null)
              Text(
                _error!,
                style: tokens.rowSubtitle.copyWith(color: tokens.danger),
              ),
            const SizedBox(height: Spacing.sm),
            Align(
              alignment: Alignment.centerLeft,
              child: ActionBlock(
                label: 'SAVE KEYS',
                tone: tokens.accent,
                onTap: _busy
                    ? null
                    : () =>
                          _run(() => saveAwsKeys(ref, _id.text, _secret.text)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
