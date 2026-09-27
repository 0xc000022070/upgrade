import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../app/static_surface.dart';
import '../../application/agents.dart';
import '../../data/repositories/key_repository.dart';
import '../../design/components/field_panel.dart';
import '../../design/components/solid_action_bar.dart';
import '../../design/spacing.dart';
import '../../design/tokens.dart';
import '../screen_scaffold.dart';

void openNewKey(BuildContext context) {
  Navigator.of(
    context,
    rootNavigator: true,
  ).push(MaterialPageRoute<void>(builder: (_) => const NewKeyScreen()));
}

class NewKeyScreen extends ConsumerStatefulWidget {
  const NewKeyScreen({super.key});

  @override
  ConsumerState<NewKeyScreen> createState() => _NewKeyScreenState();
}

class _NewKeyScreenState extends ConsumerState<NewKeyScreen> {
  final _name = TextEditingController();
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _name.text.trim();
    if (name.isEmpty || _submitting) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    final id = const Uuid().v4();
    try {
      final generated = await ref
          .read(ed25519KeysProvider)
          .generate(id: id, name: name);
      await ref
          .read(keyRepositoryProvider)
          .save(
            ManagedKey(
              id: id,
              name: name,
              publicKey: generated.publicKey,
              fingerprint: generated.fingerprint,
              createdAt: DateTime.now(),
            ),
          );
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not create key. Try again.');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_submitting,
      child: Scaffold(
        resizeToAvoidBottomInset: true,
        body: StaticSurface(
          child: ScreenScaffold(
            title: 'NEW KEY',
            breadcrumb: '/ PERSONAL CONTROL PLANE / HOSTS / KEYS',
            onBack: _submitting ? null : () => Navigator.of(context).pop(),
            children: [
              Text(
                'Create an Ed25519 SSH key on this device. Add its public key to your host before connecting.',
                style: context.tokens.value,
              ),
              const SizedBox(height: Spacing.lg),
              FieldPanel(
                label: '[ NAME ]',
                controller: _name,
                hint: 'key name',
                enabled: !_submitting,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: Spacing.xl),
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: _name,
                builder: (context, value, _) => SolidActionBar(
                  label: _submitting ? 'CREATING KEY' : 'CREATE KEY',
                  enabled: value.text.trim().isNotEmpty && !_submitting,
                  onTap: _submit,
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: Spacing.md),
                Text(
                  _error!,
                  style: context.tokens.value.copyWith(
                    color: context.tokens.warning,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
