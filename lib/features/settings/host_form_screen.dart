import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../app/static_surface.dart';
import '../../application/agents.dart';
import '../../application/formatting.dart';
import '../../data/enums.dart';
import '../../data/repositories/host_repository.dart';
import '../../data/repositories/key_repository.dart';
import '../../design/tokens.dart';
import '../../design/components/action_block.dart';
import '../../design/components/field_panel.dart';
import '../../design/components/meta.dart';
import '../../design/components/panel.dart';
import '../../design/components/panel_sheet.dart';
import '../../design/components/picker_row.dart';
import '../../design/components/section.dart';
import '../../design/components/solid_action_bar.dart';
import '../../design/spacing.dart';
import '../../platform/host_keys.dart';
import '../hosts/host_key_sheet.dart';
import '../screen/screen_preview.dart';
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

const _defaultPort = 22;

class _HostFormScreenState extends ConsumerState<HostFormScreen> {
  late final TextEditingController _name;
  late final TextEditingController _address;
  late final TextEditingController _port;
  late final TextEditingController _user;
  late final TextEditingController _vncUsername;

  /// Drawn only while the VNC row is on and saved whether it is or not, so switching the
  /// integration back on brings the same password back.
  late final TextEditingController _password;
  String? _keyId;
  bool _submitting = false;

  bool _verifying = false;

  /// Not part of the draft the save writes: forgetting a key takes effect at once, because
  /// the reason to reach for it is a connection that is being refused right now.
  PinnedHostKey? _hostKey;

  /// Null until the host's rows are read back; an existing host must not have its
  /// integrations rewritten from a set that has not loaded yet.
  Set<IntegrationKind>? _integrations;

  /// The question the form asks before dropping a draft is whether anything the *user* did
  /// is unsaved, so a key the form preselected on their behalf moves this baseline with it.
  String? _baseKeyId;
  Set<IntegrationKind>? _baseIntegrations;

  /// Set before a pop that has already committed, so the back handler does not offer to
  /// discard what it has just written.
  bool _leaving = false;
  bool _asking = false;

  @override
  void initState() {
    super.initState();
    _hostKey = widget.host?.hostKey;
    final host = widget.host;
    _name = TextEditingController(text: host?.name ?? '');
    _address = TextEditingController(text: host?.address ?? '');
    _port = TextEditingController(text: '${host?.port ?? _defaultPort}');
    _user = TextEditingController(text: host?.user ?? '');
    _vncUsername = TextEditingController(text: host?.vncUsername ?? '');
    _password = TextEditingController(text: host?.vncPassword ?? '');
    _keyId = host?.keyId;
    _baseKeyId = _keyId;
    if (host == null) {
      _integrations = <IntegrationKind>{};
      _baseIntegrations = <IntegrationKind>{};
      // The keys are a stream that has usually not emitted by the time this runs, so the value
      // present now is taken here and every later one through the subscription. The first list
      // holding exactly one key preselects it; two or more preselect nothing.
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
    _port.dispose();
    _user.dispose();
    _vncUsername.dispose();
    _password.dispose();
    super.dispose();
  }

  String? get _missing {
    if (_name.text.trim().isEmpty) return 'NAME MISSING';
    if (_address.text.trim().isEmpty) return 'ADDRESS MISSING';
    if (_parsedPort == null) return 'PORT MISSING';
    if (_user.text.trim().isEmpty) return 'USER MISSING';
    if (_keyId == null) return 'KEY MISSING';
    return null;
  }

  int? get _parsedPort {
    final port = int.tryParse(_port.text.trim());
    if (port == null || port < 1 || port > 65535) return null;
    return port;
  }

  bool get _valid => _missing == null;

  bool get _dirty {
    final host = widget.host;
    if (_name.text.trim() != (host?.name ?? '')) return true;
    if (_address.text.trim() != (host?.address ?? '')) return true;
    // The port counts against the 22 the form filled in rather than against an empty box, so
    // an untouched new form is still clean.
    if (_port.text.trim() != '${host?.port ?? _defaultPort}') return true;
    if (_user.text.trim() != (host?.user ?? '')) return true;
    if (_vncUsername.text.trim() != (host?.vncUsername ?? '')) return true;
    if (_password.text != (host?.vncPassword ?? '')) return true;
    if (_keyId != _baseKeyId) return true;
    final base = _baseIntegrations;
    final current = _integrations;
    // An existing host's rows are still in flight until both of these are set, and nothing
    // has been changed against a baseline that has not landed.
    if (base == null || current == null) return false;
    return !setEquals(base, current);
  }

  /// Blank is no password, not an empty one. Not trimmed: a space is a character a server
  /// would count.
  String? get _vncPassword => _password.text.isEmpty ? null : _password.text;

  String? get _screenUsername {
    final username = _vncUsername.text.trim();
    return username.isEmpty ? null : username;
  }

  /// The back arrow and the system gesture are one door. [PopScope] holds the route so both
  /// arrive here and the pop is issued once.
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
      port: _parsedPort!,
      user: _user.text.trim(),
      keyId: _keyId!,
      vncUsername: _screenUsername,
      vncPassword: _vncPassword,
    );
    final hosts = ref.read(hostRepositoryProvider);
    await hosts.save(host);
    // The switches are local until here because a new host has no id to hang them on until
    // it is saved.
    final integrations = _integrations;
    if (integrations != null) {
      for (final kind in IntegrationKind.values) {
        await hosts.setIntegration(host.id, kind, integrations.contains(kind));
      }
    }
    if (_hostKey == null) await _verifyHostKey(host);
    if (mounted) {
      _leaving = true;
      Navigator.of(context).pop();
    }
  }

  /// Every failure leaves the host saved and unpinned: the panel keeps `VERIFY` for it.
  Future<void> _verifyHostKey(Host host) async {
    final privateKey = await ref
        .read(ed25519KeysProvider)
        .privateKey(host.keyId);
    if (privateKey == null || !mounted) return;
    setState(() => _verifying = true);
    try {
      await ref.read(hostKeyDialProvider)(
        address: host.address,
        port: host.port,
        user: host.user,
        privateKey: privateKey,
        verifier: HostKeyVerifier(
          prompt: (offer, pinned) async =>
              mounted &&
              await askHostKey(
                context,
                host: host,
                offer: offer,
                pinned: pinned,
              ),
          pin: (key) =>
              ref.read(hostRepositoryProvider).pinHostKey(host.id, key),
        ),
      );
    } catch (error) {
      debugPrint('dazzle.verify ${host.name}: $error');
    }
    if (mounted) setState(() => _verifying = false);
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
    if (!mounted) return;
    await _deletePreview(host.id);
    if (mounted) {
      _leaving = true;
      Navigator.of(context).pop();
    }
  }

  /// A store that will not open costs a stray file and nothing else, which is not a reason
  /// to leave the user on a form for a host that is already gone.
  Future<void> _deletePreview(String hostId) async {
    try {
      final previews = await ref.read(screenPreviewsProvider.future);
      await previews.delete(hostId);
    } catch (error) {
      debugPrint('dazzle.vnc $hostId: preview not removed: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final keys = ref.watch(managedKeysProvider);
    final loaded = _integrations != null;
    final integrations = _integrations ?? <IntegrationKind>{};
    return PopScope(
      // Always false: whether this form may leave depends on text the fields own, and a
      // [canPop] read at build time is a keystroke behind.
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
            breadcrumb: '/ DAZZLE / HOSTS',
            onBack: _handleBack,
            children: [
              PanelStack(
                children: [
                  FieldPanel(label: '[ NAME ]', controller: _name),
                  FieldPanel(label: '[ ADDRESS ]', controller: _address),
                  FieldPanel(
                    label: '[ PORT ]',
                    controller: _port,
                    keyboardType: TextInputType.number,
                  ),
                  FieldPanel(label: '[ USER ]', controller: _user),
                  Panel(
                    title: '[ KEY ]',
                    bodyPadding: panelRowsPadding,
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
                  if (integrations.contains(IntegrationKind.vnc))
                    FieldPanel(
                      label: '[ VNC USER ]',
                      controller: _vncUsername,
                      hint: 'macOS account · blank for classic VNC',
                      keyboardType: TextInputType.text,
                    ),
                  if (integrations.contains(IntegrationKind.vnc))
                    FieldPanel(
                      label: '[ VNC PASSWORD ]',
                      controller: _password,
                      hint: 'blank when the server offers none',
                      obscureText: true,
                      keyboardType: TextInputType.visiblePassword,
                    ),
                  if (_hostKey != null) _hostKeyPanel(_hostKey!),
                ],
              ),
              const SizedBox(height: Spacing.xl),
              ListenableBuilder(
                listenable: Listenable.merge([
                  _name,
                  _address,
                  _port,
                  _user,
                  _vncUsername,
                  _password,
                ]),
                builder: (context, _) {
                  final missing = _missing;
                  return SolidActionBar(
                    label: _verifying
                        ? 'VERIFYING'
                        : missing ??
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
                  tone: context.tokens.warning,
                  onTap: _delete,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _hostKeyPanel(PinnedHostKey key) {
    return Panel(
      title: '[ HOST KEY ]',
      bodyPadding: panelRowsPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _KeyMetaRow('TYPE', key.type.toUpperCase()),
          _KeyMetaRow('FINGERPRINT', key.fingerprint, maxLines: 3),
          _KeyMetaRow('PINNED', relativeAge(key.pinnedAt.toUtc())),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
            child: Align(
              alignment: Alignment.centerLeft,
              child: ActionBlock(
                label: 'FORGET KEY',
                tone: context.tokens.warning,
                onTap: _forgetHostKey,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _forgetHostKey() async {
    final host = widget.host;
    if (host == null) return;
    final confirmed = await confirmSheet(
      context,
      title: 'FORGET HOST KEY?',
      confirmLabel: 'FORGET',
    );
    if (!confirmed || !mounted) return;
    await ref.read(hostRepositoryProvider).forgetHostKey(host.id);
    if (mounted) setState(() => _hostKey = null);
  }
}

class _KeyMetaRow extends StatelessWidget {
  const _KeyMetaRow(this.label, this.value, {this.maxLines = 1});

  final String label;
  final String value;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 108, child: Text(label, style: context.tokens.label)),
          Expanded(child: Meta(value, maxLines: maxLines)),
        ],
      ),
    );
  }
}
