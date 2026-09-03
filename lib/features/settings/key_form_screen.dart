import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../app/static_surface.dart';
import '../../application/agents.dart';
import '../../data/repositories/key_repository.dart';
import '../../design/components/field_panel.dart';
import '../../design/components/solid_action_bar.dart';
import '../../design/spacing.dart';
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

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _name.text.trim();
    if (name.isEmpty || _submitting) return;
    setState(() => _submitting = true);
    final id = const Uuid().v4();
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
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: StaticSurface(
        child: ScreenScaffold(
          title: 'NEW KEY',
          breadcrumb: '/ HOTLINE / SYS / KEYS',
          onBack: () => Navigator.of(context).pop(),
          children: [
            FieldPanel(
              label: '[ NAME ]',
              controller: _name,
              hint: 'key name',
              autofocus: true,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: Spacing.xl),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _name,
              builder: (context, value, _) => value.text.trim().isEmpty
                  ? const SizedBox(height: TapTargets.minHeight)
                  : SolidActionBar(label: 'CREATE KEY', onTap: _submit),
            ),
          ],
        ),
      ),
    );
  }
}
