import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../app/static_surface.dart';
import '../../application/agents.dart';
import '../../data/enums.dart';
import '../../data/repositories/host_repository.dart';
import '../../data/repositories/key_repository.dart';
import '../../design/colors.dart';
import '../../design/components/field_panel.dart';
import '../../design/components/panel.dart';
import '../../design/components/panel_sheet.dart';
import '../../design/components/picker_row.dart';
import '../../design/components/section.dart';
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

  /// What the form opened with. §39.28 asks before dropping a draft, and the
  /// question is whether anything the *user* did is unsaved — so a key the form
  /// preselected on their behalf moves this baseline with it, and an untouched
  /// form on a one-key device still leaves without a word.
  String? _baseKeyId;
  Set<IntegrationKind>? _baseIntegrations;

  /// Set before a pop that has already committed, so the back handler does not
  /// offer to discard what it has just written.
  bool _leaving = false;
  bool _asking = false;

  @override
  void initState() {
    super.initState();
    final host = widget.host;
    _name = TextEditingController(text: host?.name ?? '');
    _address = TextEditingController(text: host?.address ?? '');
    _user = TextEditingController(text: host?.user ?? '');
    _keyId = host?.keyId;
    _baseKeyId = _keyId;
    if (host == null) {
      _integrations = <IntegrationKind>{};
      _baseIntegrations = <IntegrationKind>{};
      // §39.28: one key is not a choice, and a picker holding a single row
      // reads as already chosen. The keys are a stream that has usually not
      // emitted by the time this runs, so the value present now is taken here
      // and every later one through the subscription; the first list holding
      // exactly one key preselects it, two or more preselect nothing.
      _preselect(ref.read(managedKeysProvider).valueOrNull);
      ref.listenManual(managedKeysProvider, (_, next) {
        final before = _keyId;
        _preselect(next.valueOrNull);
        if (_keyId != before) setState(() {});
      });
    } else {
      unawaited(_loadIntegrations(host.id));
    }
  }

  void _preselect(List<ManagedKey>? keys) {
    if (_keyId != null || keys == null || keys.length != 1) return;
    _keyId = keys.single.id;
    _baseKeyId = _keyId;
  }

  Future<void> _loadIntegrations(String hostId) async {
    final current = await ref.read(hostIntegrationsProvider(hostId).future);
    if (!mounted) return;
    setState(() {
      _integrations = current.toSet();
      _baseIntegrations = current.toSet();
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    _user.dispose();
    super.dispose();
  }

  /// §39.28, in field order: the first part of the host that is not there yet.
  /// Null when there is none, which is the same thing as the form being valid.
  String? get _missing {
    if (_name.text.trim().isEmpty) return 'NAME MISSING';
    if (_address.text.trim().isEmpty) return 'ADDRESS MISSING';
    if (_user.text.trim().isEmpty) return 'USER MISSING';
    if (_keyId == null) return 'KEY MISSING';
    return null;
  }

  bool get _valid => _missing == null;

  /// §39.28: anything the user would lose by leaving. Measured against the
  /// values the form opened with, so it reads the same for a new host — whose
  /// baseline is three empty fields — and for one being edited.
  bool get _dirty {
    final host = widget.host;
    if (_name.text.trim() != (host?.name ?? '')) return true;
    if (_address.text.trim() != (host?.address ?? '')) return true;
    if (_user.text.trim() != (host?.user ?? '')) return true;
    if (_keyId != _baseKeyId) return true;
    final base = _baseIntegrations;
    final current = _integrations;
    // An existing host's rows are still in flight until both of these are set,
    // and nothing has been changed against a baseline that has not landed.
    if (base == null || current == null) return false;
    return !setEquals(base, current);
  }

  /// §39.28: the back arrow and the system gesture are one door. [PopScope]
  /// holds the route so both arrive here and the pop is issued once, after the
  /// question when there is one to ask.
  Future<void> _handleBack() async {
    if (_asking) return;
    if (_leaving || !_dirty) {
      Navigator.of(context).pop();
      return;
    }
    _asking = true;
    final discard = await confirmSheet(
      context,
      title: 'DISCARD HOST?',
      confirmLabel: 'DISCARD',
    );
    _asking = false;
    if (discard && mounted) Navigator.of(context).pop();
  }

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
    if (mounted) {
      _leaving = true;
      Navigator.of(context).pop();
    }
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
    if (mounted) {
      _leaving = true;
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final keys = ref.watch(managedKeysProvider);
    final loaded = _integrations != null;
    final integrations = _integrations ?? <IntegrationKind>{};
    return PopScope(
      // Always false: whether this form may leave depends on text the fields
      // own, and a [canPop] read at build time is a keystroke behind. The
      // decision is taken in the callback instead, where it is current.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        unawaited(_handleBack());
      },
      child: Scaffold(
        resizeToAvoidBottomInset: true,
        body: StaticSurface(
          child: ScreenScaffold(
            title: widget.host == null ? 'NEW HOST' : 'HOST',
            breadcrumb: '/ HOTLINE / SYS / HOSTS',
            onBack: _handleBack,
            children: [
              PanelStack(
                children: [
                  FieldPanel(label: '[ NAME ]', controller: _name),
                  FieldPanel(label: '[ ADDRESS ]', controller: _address),
                  FieldPanel(label: '[ USER ]', controller: _user),
                  Panel(
                    title: '[ KEY ]',
                    bodyPadding: panelRowsPadding,
                    // §39.28: a form cannot ask for a key the device does not
                    // have. With none, the body is the one dim line an empty
                    // list gets anywhere else, and it says where one is made.
                    child: AsyncSection<List<ManagedKey>>(
                      value: keys,
                      empty: 'no keys · new + in sys',
                      builder: (items) => Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final key in items)
                            PickerRow(
                              label: key.name.toUpperCase(),
                              subtitle: key.fingerprint,
                              selected: key.id == _keyId,
                              onTap: () => setState(() => _keyId = key.id),
                            ),
                        ],
                      ),
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
                builder: (context, _) {
                  // §39.28: the bar is always drawn. Invalid, it names the part
                  // that is missing and does nothing when tapped.
                  final missing = _missing;
                  return SolidActionBar(
                    label:
                        missing ??
                        (widget.host == null ? 'CREATE HOST' : 'SAVE'),
                    enabled: missing == null,
                    onTap: _submit,
                  );
                },
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
      ),
    );
  }
}
