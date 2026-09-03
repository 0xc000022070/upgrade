import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../app/static_surface.dart';
import '../../application/agents.dart';
import '../../data/enums.dart';
import '../../data/repositories/host_repository.dart';
import '../../design/colors.dart';
import '../../design/components/field_panel.dart';
import '../../design/components/panel.dart';
import '../../design/components/panel_sheet.dart';
import '../../design/components/picker_row.dart';
import '../../design/components/solid_action_bar.dart';
import '../../design/spacing.dart';
import '../screen_scaffold.dart';

void openHostForm(BuildContext context, {Host? host}) {
  Navigator.of(
    context,
    rootNavigator: true,
  ).push(MaterialPageRoute<void>(builder: (_) => HostFormScreen(host: host)));
}

class HostFormScreen extends ConsumerStatefulWidget {
  const HostFormScreen({super.key, this.host});

  final Host? host;

  @override
  ConsumerState<HostFormScreen> createState() => _HostFormScreenState();
}

class _HostFormScreenState extends ConsumerState<HostFormScreen> {
  late final TextEditingController _name;
  late final TextEditingController _address;
  late final TextEditingController _user;
  String? _keyId;
  bool _submitting = false;

  /// Null until the host's rows are read back; an existing host must not have
  /// its integrations rewritten from a set that has not loaded yet.
  Set<IntegrationKind>? _integrations;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.host?.name ?? '');
    _address = TextEditingController(text: widget.host?.address ?? '');
    _user = TextEditingController(text: widget.host?.user ?? '');
    _keyId = widget.host?.keyId;
    final host = widget.host;
    if (host == null) {
      _integrations = <IntegrationKind>{};
    } else {
      unawaited(_loadIntegrations(host.id));
    }
  }

  Future<void> _loadIntegrations(String hostId) async {
    final current = await ref.read(hostIntegrationsProvider(hostId).future);
    if (mounted) setState(() => _integrations = current.toSet());
  }

  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    _user.dispose();
    super.dispose();
  }

  bool get _valid =>
      _name.text.trim().isNotEmpty &&
      _address.text.trim().isNotEmpty &&
      _user.text.trim().isNotEmpty &&
      _keyId != null;

  Future<void> _submit() async {
    if (!_valid || _submitting) return;
    setState(() => _submitting = true);
    final host = Host(
      id: widget.host?.id ?? const Uuid().v4(),
      name: _name.text.trim(),
      address: _address.text.trim(),
      user: _user.text.trim(),
      keyId: _keyId!,
    );
    final hosts = ref.read(hostRepositoryProvider);
    await hosts.save(host);
    // §39.21: a host is a machine and its integrations are rows beside it, so
    // the form writes both under one action. The switches are local until here
    // because a new host has no id to hang them on until it is saved.
    final integrations = _integrations;
    if (integrations != null) {
      for (final kind in IntegrationKind.values) {
        await hosts.setIntegration(host.id, kind, integrations.contains(kind));
      }
    }
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    final host = widget.host;
    if (host == null) return;
    final confirmed = await confirmSheet(
      context,
      title: 'DELETE HOST?',
      confirmLabel: 'DELETE',
    );
    if (!confirmed || !mounted) return;
    await ref.read(hostRepositoryProvider).delete(host.id);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final keys = ref.watch(managedKeysProvider).valueOrNull ?? const [];
    final loaded = _integrations != null;
    final integrations = _integrations ?? <IntegrationKind>{};
    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: StaticSurface(
        child: ScreenScaffold(
          title: widget.host == null ? 'NEW HOST' : 'HOST',
          breadcrumb: '/ HOTLINE / SYS / HOSTS',
          onBack: () => Navigator.of(context).pop(),
          children: [
            PanelStack(
              children: [
                FieldPanel(label: '[ NAME ]', controller: _name),
                FieldPanel(label: '[ ADDRESS ]', controller: _address),
                FieldPanel(label: '[ USER ]', controller: _user),
                Panel(
                  title: '[ KEY ]',
                  bodyPadding: panelRowsPadding,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final key in keys)
                        PickerRow(
                          label: key.name.toUpperCase(),
                          subtitle: key.fingerprint,
                          selected: key.id == _keyId,
                          onTap: () => setState(() => _keyId = key.id),
                        ),
                    ],
                  ),
                ),
                Panel(
                  title: '[ INTEGRATIONS ]',
                  bodyPadding: panelRowsPadding,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // §16c.3: the active value is the solid block, so an
                      // integration that is on is the accent row and one that
                      // is off is a plain row reading OFF. HERDR is the only
                      // kind today; the loop is the point of the table.
                      for (final kind in IntegrationKind.values)
                        PickerRow(
                          label: kind.label,
                          value: 'OFF',
                          selected: integrations.contains(kind),
                          onTap: loaded
                              ? () => setState(() {
                                  if (!integrations.remove(kind)) {
                                    integrations.add(kind);
                                  }
                                })
                              : () {},
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: Spacing.xl),
            ListenableBuilder(
              listenable: Listenable.merge([_name, _address, _user]),
              builder: (context, _) => _valid
                  ? SolidActionBar(
                      label: widget.host == null ? 'CREATE HOST' : 'SAVE',
                      onTap: _submit,
                    )
                  : const SizedBox(height: TapTargets.minHeight),
            ),
            if (widget.host != null) ...[
              const SizedBox(height: Spacing.md),
              SolidActionBar(
                label: 'DELETE HOST',
                tone: HotlineColors.warning,
                onTap: _delete,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
