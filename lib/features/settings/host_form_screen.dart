import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import 'package:upgrade/data/pinned_host_key.dart';
import 'package:upgrade/application/static_surface.dart';
import 'package:upgrade/application/hosts/host_providers.dart';
import 'package:upgrade/application/formatting.dart';
import 'package:upgrade/application/phone_linux.dart';
import 'package:upgrade/application/providers.dart';
import 'package:upgrade/data/enums.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/data/repositories/key_repository.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/design/components/action_block.dart';
import 'package:upgrade/design/components/list_row.dart';
import 'package:upgrade/design/components/panel_text_action.dart';
import 'package:upgrade/design/components/upgrade_field.dart';
import 'package:upgrade/design/components/meta_row.dart';
import 'package:upgrade/design/components/panel.dart';
import 'package:upgrade/design/components/panel_sheet.dart';
import 'package:upgrade/design/components/section.dart';
import 'package:upgrade/design/components/solid_action_bar.dart';
import 'package:upgrade/design/icons/upgrade_icon.dart';
import 'package:upgrade/design/icons/upgrade_icons.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/platform/ssh/host_keys.dart';
import 'package:upgrade/platform/shell/shell_connection.dart';
import 'package:upgrade/features/shell/session/shell_sessions.dart';
import 'package:upgrade/features/hosts/host_key_sheet.dart';
import 'package:upgrade/features/settings/key_form_screen.dart';
import 'package:upgrade/features/screen/screen_preview.dart';
import 'package:upgrade/design/components/screen_scaffold.dart';
import 'package:upgrade/brand.dart';

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
  late final String _draftId;
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
  String? _saveError;

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
    _draftId = host?.id ?? const Uuid().v4();
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
      _preselect(ref.read(managedKeysProvider).value);
      ref.listenManual(managedKeysProvider, (_, next) {
        final before = _keyId;
        _preselect(next.value);
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
    final current = await readFirst(
      ref,
      hostIntegrationsProvider(hostId).future,
    );
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
    if (_asking || _submitting) return;
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
    if (!_valid || _submitting || _integrations == null) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _submitting = true;
      _saveError = null;
    });
    final host = Host(
      id: _draftId,
      name: _name.text.trim(),
      address: _address.text.trim(),
      port: _parsedPort!,
      user: _user.text.trim(),
      keyId: _keyId!,
      vncUsername: _screenUsername,
      vncPassword: _vncPassword,
    );
    try {
      final hosts = ref.read(hostRepositoryProvider);
      await hosts.save(host);
      // The switches are local until here because a new host has no id to hang them on until
      // it is saved.
      final integrations = _integrations;
      if (integrations != null) {
        for (final kind in IntegrationKind.values) {
          await hosts.setIntegration(
            host.id,
            kind,
            integrations.contains(kind),
          );
        }
      }
      if (_hostKey == null) await _verifyHostKey(host);
      if (mounted) {
        _leaving = true;
        Navigator.of(context).pop();
      }
    } catch (_) {
      if (mounted) {
        setState(() => _saveError = 'Could not save host. Try again.');
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
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
      debugPrint('$appSlug.verify ${host.name}: $error');
    }
    if (mounted) setState(() => _verifying = false);
  }

  Future<void> _delete() async {
    final host = widget.host;
    if (host == null) return;
    final linux = ref.read(phoneLinuxHostProvider);
    final onPhone = (await linux?.hostIds())?.contains(host.id) ?? false;
    if (!mounted) return;
    const title = 'DELETE HOST?';
    final shells = ref.read(shellSessionsProvider);
    final confirmed = await showPanelSheet<bool>(
      context,
      title: title,
      builder: (_) => ConfirmSheetBody(
        title: title,
        confirmLabel: 'DELETE',
        message: onPhone
            ? 'Deletes the system with every file in it, and the '
                  '${host.name} host.'
            : null,
        onConfirm: UserIntent.onGesture(
          (intent) => unawaited(shells.closeHost(host.id, intent)),
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    final repository = ref.read(hostRepositoryProvider);
    final previews = ref.read(screenPreviewsProvider.future);
    setState(() => _submitting = true);
    try {
      if (onPhone) {
        await linux!.remove(host);
      } else {
        await repository.delete(host.id);
      }
      await deletePreview(previews, host.id);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
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
      // Always false: whether this form may leave depends on text the fields own, and a
      // [canPop] read at build time is a keystroke behind.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        unawaited(_handleBack());
      },
      child: Scaffold(
        resizeToAvoidBottomInset: true,
        bottomNavigationBar: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(Spacing.screenEdge),
            child: ListenableBuilder(
              listenable: Listenable.merge([_name, _address, _port, _user]),
              builder: (context, _) => Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_saveError != null || _missing != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: Spacing.sm),
                      child: Text(
                        _saveError ?? _missing!,
                        style: context.tokens.label,
                      ),
                    ),
                  Row(
                    children: [
                      ActionBlock(
                        label: 'CANCEL',
                        onTap: _submitting ? null : _handleBack,
                      ),
                      const SizedBox(width: Spacing.md),
                      Expanded(
                        child: SolidActionBar(
                          label: _verifying
                              ? 'VERIFYING'
                              : _submitting
                              ? 'SAVING'
                              : widget.host == null
                              ? 'CREATE HOST'
                              : 'SAVE',
                          enabled: _valid && loaded && !_submitting,
                          onTap: _submit,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
        body: StaticSurface(
          child: ScreenScaffold(
            title: widget.host == null ? 'NEW HOST' : 'HOST',
            breadcrumb: '/ $appNameCaps / MACHINES',
            onBack: _handleBack,
            children: [
              PanelStack(
                children: [
                  Panel(
                    title: '[ CONNECTION ]',
                    child: Column(
                      children: [
                        _HostField(
                          label: 'NAME',
                          id: 'host.name',
                          controller: _name,
                          enabled: !_submitting,
                        ),
                        _HostField(
                          label: 'ADDRESS',
                          id: 'host.address',
                          controller: _address,
                          enabled: !_submitting,
                          hint: 'IP address or hostname',
                        ),
                        _HostField(
                          label: 'PORT',
                          id: 'host.port',
                          controller: _port,
                          enabled: !_submitting,
                          keyboardType: TextInputType.number,
                        ),
                        _HostField(
                          label: 'USER',
                          id: 'host.user',
                          controller: _user,
                          enabled: !_submitting,
                        ),
                      ],
                    ),
                  ),
                  Panel(
                    title: '[ KEY ]',
                    bodyPadding: panelRowsPadding,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        AsyncSection<List<ManagedKey>>(
                          value: keys,
                          empty: 'No keys yet',
                          builder: (items) => ListRowGroup(
                            children: [
                              for (final key in items)
                                ListRow(
                                  key: ValueKey('host-key-${key.id}'),
                                  leading: UpgradeIcon(
                                    UpgradeIcons.sshKey,
                                    size: IconSizes.glyph,
                                    color: context.tokens.textSecondary,
                                  ),
                                  title: key.name,
                                  literalTitle: true,
                                  subtitle: key.fingerprint,
                                  trailing: key.id == _keyId
                                      ? UpgradeIcon(
                                          UpgradeIcons.check,
                                          size: IconSizes.check,
                                          color: context.tokens.accent,
                                        )
                                      : null,
                                  onTap: _submitting
                                      ? null
                                      : () => setState(() => _keyId = key.id),
                                ),
                            ],
                          ),
                        ),
                        PanelTextAction(
                          label: 'CREATE SSH KEY',
                          onTap: _submitting ? null : () => openNewKey(context),
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
                        ListRowGroup(
                          children: [
                            for (final kind in IntegrationKind.values)
                              ListRow(
                                key: ValueKey('integration-${kind.wire}'),
                                leading: _check(
                                  context,
                                  integrations.contains(kind),
                                ),
                                title: kind.label,
                                subtitle: _integrationLine(kind),
                                subtitleMaxLines: 2,
                                onTap: loaded && !_submitting
                                    ? () => setState(() {
                                        if (!integrations.remove(kind)) {
                                          integrations.add(kind);
                                        }
                                      })
                                    : null,
                              ),
                          ],
                        ),
                        if (integrations.contains(IntegrationKind.vnc)) ...[
                          _HostField(
                            label: 'VNC USER',
                            id: 'host.vnc_user',
                            controller: _vncUsername,
                            enabled: !_submitting,
                            hint: 'macOS account · blank for classic VNC',
                            keyboardType: TextInputType.text,
                          ),
                          _HostField(
                            label: 'VNC PASSWORD',
                            id: 'host.vnc_password',
                            controller: _password,
                            enabled: !_submitting,
                            hint: 'blank when the server offers none',
                            obscureText: true,
                            keyboardType: TextInputType.visiblePassword,
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (_hostKey != null) _hostKeyPanel(_hostKey!),
                ],
              ),
              if (widget.host != null) ...[
                const SizedBox(height: Spacing.md),
                Align(
                  alignment: Alignment.centerLeft,
                  child: ActionBlock(
                    label: 'DELETE HOST',
                    tone: context.tokens.warning,
                    onTap: _submitting ? null : _delete,
                  ),
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
          MetaRow('TYPE', key.type.toUpperCase()),
          MetaRow('FINGERPRINT', key.fingerprint, maxLines: 3),
          MetaRow('PINNED', relativeAge(key.pinnedAt.toUtc())),
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
    await ref.read(hostKeyPinsProvider).forget(host.id);
    if (mounted) setState(() => _hostKey = null);
  }
}

String _integrationLine(IntegrationKind kind) => switch (kind) {
  IntegrationKind.herdr => 'Agents in its herdr panes',
  IntegrationKind.agents => 'Agents heard from their own hooks',
  IntegrationKind.vnc => 'Its desktop, tunnelled through ssh',
  IntegrationKind.devices => 'Its emulators and simulators',
};

Widget _check(BuildContext context, bool on) => UpgradeIcon(
  on ? UpgradeIcons.checkboxChecked : UpgradeIcons.checkboxEmpty,
  size: IconSizes.check,
  color: on ? context.tokens.accent : context.tokens.textMuted,
);

class _HostField extends StatelessWidget {
  const _HostField({
    required this.label,
    required this.id,
    required this.controller,
    this.hint = '',
    this.keyboardType,
    this.obscureText = false,
    this.enabled = true,
  });

  final String label;
  final String id;
  final TextEditingController controller;
  final String hint;
  final TextInputType? keyboardType;
  final bool obscureText;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: context.tokens.label),
        UpgradeField(
          semanticLabel: label,
          semanticIdentifier: id,
          controller: controller,
          enabled: enabled,
          hint: hint,
          obscureText: obscureText,
          keyboardType: keyboardType,
          textInputAction: TextInputAction.next,
          contentPadding: const EdgeInsets.symmetric(vertical: Spacing.md),
        ),
      ],
    ),
  );
}
