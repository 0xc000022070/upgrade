import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/application/agents/agents.dart';
import 'package:upgrade/application/hosts/host_providers.dart';
import 'package:upgrade/application/phone_linux.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/design/components/meta.dart';
import 'package:upgrade/design/components/panel.dart';
import 'package:upgrade/design/components/panel_sheet.dart';
import 'package:upgrade/features/screen/screen_preview.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/platform/ssh/host_key_dial.dart';
import 'package:upgrade/platform/ssh/host_keys.dart';
import 'package:upgrade/platform/links/host_link_probe.dart';
import 'package:upgrade/platform/phone_linux.dart';
import 'package:upgrade/platform/shell/shell_connection.dart';
import 'package:upgrade/features/shell/session/shell_sessions.dart';
import 'package:upgrade/features/hosts/host_key_sheet.dart';
import 'package:upgrade/features/hosts/link_probes.dart';
import 'package:upgrade/features/hosts/phone_linux_picker.dart';
import 'package:upgrade/brand.dart';

const _labelWidth = 96.0;

double _labelScale(BuildContext context) {
  final size = context.tokens.label.fontSize!;
  return MediaQuery.textScalerOf(context).scale(size) / size;
}

class MetaRow extends StatelessWidget {
  const MetaRow(
    this.label,
    this.value, {
    super.key,
    this.strong = false,
    this.color,
    this.trailing,
  });

  final String label;
  final String value;
  final bool strong;
  final Color? color;

  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      // A minimum, which is what the metric is called: a row holding words the reader asked to
      // be bigger is taller than one that is not.
      constraints: const BoxConstraints(minHeight: RowMetrics.minHeight),
      child: Row(
        children: [
          SizedBox(
            // Handing the width to the scaler as if it were a font size is not the same number: the
            // system curve gives a small size much more than a large one, so a 96px "font" barely
            // moved while the 9px label it was holding nearly doubled and broke mid-word.
            width: _labelWidth * _labelScale(context),
            child: Text(label, style: context.tokens.label),
          ),
          const SizedBox(width: Spacing.md),
          Expanded(
            child: Meta(value, strong: strong, color: color),
          ),
          if (trailing != null) ...[
            const SizedBox(width: Spacing.md),
            trailing!,
          ],
        ],
      ),
    );
  }
}

class LinkRow extends ConsumerStatefulWidget {
  const LinkRow({super.key, required this.host, required this.outcome});

  final Host host;
  final HostOutcome? outcome;

  @override
  ConsumerState<LinkRow> createState() => LinkRowState();
}

class LinkRowState extends ConsumerState<LinkRow> {
  bool _verifying = false;

  /// The row's own answer outranks [LinkRow.outcome], which is the last word of a poll
  /// this tap does not re-run: without it a host that is already pinned goes `VERIFYING`
  /// and straight back to `VERIFY`.
  bool _verified = false;

  String? _failure;

  @override
  void didUpdateWidget(LinkRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.host.hostKey == null && oldWidget.host.hostKey != null) {
      _verified = false;
    }
  }

  bool get _unverified =>
      widget.host.hostKey == null ||
      widget.outcome?.kind == AgentOutcomeKind.hostKeyUnverified ||
      widget.outcome?.kind == AgentOutcomeKind.hostKeyChanged;

  @override
  Widget build(BuildContext context) {
    final probes = ref.watch(linkProbesProvider);
    return AnimatedBuilder(
      animation: probes,
      builder: (context, _) {
        final result = probes.forHost(widget.host.id);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => unawaited(probes.probe(widget.host, force: true)),
          child: MetaRow(
            'LINK',
            linkWord(result),
            color: linkFailed(result) ? context.tokens.warning : null,
            trailing: _trailing(),
          ),
        );
      },
    );
  }

  Widget? _trailing() {
    if (_verifying) {
      return const PanelAffordance('VERIFYING', showIcon: false);
    }
    if (_verified || !_unverified) return null;
    final failure = _failure;
    return PanelAffordance(
      failure ?? 'VERIFY',
      showIcon: false,
      color: failure == null ? null : context.tokens.warning,
      onTap: () => unawaited(_verify()),
    );
  }

  Future<void> _verify() async {
    if (_verifying) return;
    setState(() {
      _verifying = true;
      _failure = null;
      _verified = false;
    });
    final host = widget.host;
    String? failure;
    var verified = false;
    try {
      final privateKey = await ref
          .read(ed25519KeysProvider)
          .privateKey(host.keyId);
      if (privateKey == null) {
        failure = 'NO KEY';
      } else {
        final verifier = HostKeyVerifier(
          pinned: host.hostKey,
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
        );
        await ref.read(hostKeyDialProvider)(
          address: host.address,
          port: host.port,
          user: host.user,
          privateKey: privateKey,
          verifier: verifier,
        );
        // A user who said no said nothing went wrong. A key that does not match the pin is the
        // one refusal that has to stay on screen.
        if (verifier.refusal == HostKeyRefusal.changed) failure = 'KEY CHANGED';
        verified = verifier.refusal == null;
      }
    } catch (error) {
      debugPrint('$appSlug.verify ${host.name}: $error');
      failure = _failureWord(error);
    }
    if (!mounted) return;
    setState(() {
      _verifying = false;
      _failure = failure;
      _verified = verified;
    });
  }
}

/// `NO ANSWER` is the one worth naming: a socket that opens and stays silent is a machine
/// behind a tarpit, not a machine that is down, and the two look identical without it.
String _failureWord(Object error) => switch (error) {
  HostKeySilent() => 'NO ANSWER',
  SocketException() => 'NO ROUTE',
  TimeoutException() => 'NO ANSWER',
  _ => 'FAILED',
};

class PhoneLinuxRow extends ConsumerStatefulWidget {
  const PhoneLinuxRow({super.key, required this.host, this.system = true});

  final Host host;

  final bool system;

  @override
  ConsumerState<PhoneLinuxRow> createState() => PhoneLinuxRowState();
}

class PhoneLinuxRowState extends ConsumerState<PhoneLinuxRow> {
  String? _busy;
  String? _failure;
  String? _toolsFailure;

  @override
  Widget build(BuildContext context) {
    final state = ref.phoneLinuxState(widget.host.id);
    final linux = ref.watch(phoneLinuxHostProvider)!;
    final warning = context.tokens.warning;
    final busy = _busy;
    final (String value, Color? color, String? action) = switch (state) {
      PhoneLinuxState(phase: PhoneLinuxPhase.download, :final percent) => (
        percent == null ? 'DOWNLOADING' : 'DOWNLOADING $percent%',
        null,
        null,
      ),
      PhoneLinuxState(phase: PhoneLinuxPhase.unpack) => (
        'UNPACKING',
        null,
        null,
      ),
      PhoneLinuxState(phase: PhoneLinuxPhase.setup) => (
        'INSTALLING SSH',
        null,
        null,
      ),
      PhoneLinuxState(phase: PhoneLinuxPhase.nix) => (
        'INSTALLING NIX',
        null,
        null,
      ),
      PhoneLinuxState(installed: false, phase: PhoneLinuxPhase.failed) => (
        state.error ?? 'failed',
        warning,
        'RETRY',
      ),
      PhoneLinuxState(installed: false) => ('NOT INSTALLED', null, 'INSTALL'),
      PhoneLinuxState(running: true) => ('RUNNING', null, 'STOP'),
      _ => ('STOPPED', warning, 'START'),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MetaRow(
          'LINUX',
          _failure ?? value,
          strong: state.running,
          color: _failure == null ? color : warning,
          trailing: busy != null
              ? PanelAffordance(busy, showIcon: false)
              : action == null
              ? null
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (action == 'STOP') ...[
                      PanelAffordance(
                        'RESTART',
                        key: const ValueKey('phone-linux-restart'),
                        showIcon: false,
                        onTap: UserIntent.onGesture(
                          (intent) => unawaited(
                            _act(linux, state, 'RESTART', UserAction(intent)),
                          ),
                        ),
                      ),
                      const SizedBox(width: Spacing.lg),
                    ],
                    PanelAffordance(
                      action,
                      key: ValueKey('phone-linux-${action.toLowerCase()}'),
                      showIcon: false,
                      onTap: action == 'START'
                          ? UserIntent.onGesture(
                              (intent) => unawaited(
                                _act(linux, state, action, UserAction(intent)),
                              ),
                            )
                          : () => unawaited(_act(linux, state, action, null)),
                    ),
                  ],
                ),
        ),
        if (widget.system && state.installed && !state.installing)
          MetaRow(
            'SYSTEM',
            ref
                    .watch(phoneLinuxCatalogProvider)
                    .value
                    ?.distro(state.distro)
                    ?.label ??
                state.distro?.toUpperCase() ??
                'LINUX',
            trailing: PanelAffordance(
              busy == 'REMOVING' ? busy! : 'REMOVE',
              showIcon: false,
              color: warning,
              onTap: busy == null ? () => _remove(linux) : null,
            ),
          ),
        if (widget.system && state.installed && !state.installing && state.nix)
          const MetaRow('NIX', 'INSTALLED'),
        if (widget.system && state.installed && !state.installing)
          _tools(linux, state),
      ],
    );
  }

  Widget _tools(PhoneLinuxHost linux, PhoneLinuxState state) {
    final warning = context.tokens.warning;
    final catalog = ref.watch(phoneLinuxCatalogProvider).value;
    final distro = catalog?.distro(state.distro);
    final tool = state.tool;
    final error = _toolsFailure ?? state.toolsError;
    final missing =
        distro != null &&
        catalog!.tools.any(
          (tool) =>
              tool.fits(distro, nix: state.nix) &&
              !state.tools.contains(tool.id),
        );
    String label(String id) => catalog?.toolLabel(id) ?? id.toUpperCase();
    final (String value, Color? color, String? action) = tool != null
        ? ('INSTALLING ${label(tool)}', null, null)
        : error != null
        ? (error, warning, state.pending.isEmpty ? null : 'RETRY')
        : (
            state.tools.isEmpty ? 'NONE' : state.tools.map(label).join(' · '),
            null,
            missing ? 'ADD' : null,
          );
    return MetaRow(
      'TOOLS',
      value,
      color: color,
      trailing: action == null
          ? null
          : PanelAffordance(
              action,
              key: ValueKey('phone-linux-tools-${action.toLowerCase()}'),
              showIcon: false,
              onTap: () => unawaited(_addTools(linux, state, action)),
            ),
    );
  }

  Future<void> _addTools(
    PhoneLinuxHost linux,
    PhoneLinuxState state,
    String action,
  ) async {
    final catalog = await ref.read(phoneLinuxCatalogProvider.future);
    final distro = catalog.distro(state.distro);
    if (distro == null || !mounted) return;
    final tools = action == 'RETRY'
        ? state.pending
        : await pickPhoneLinuxTools(
            context,
            catalog: catalog,
            distro: distro,
            nix: state.nix,
            installed: state.tools,
          );
    if (tools == null || tools.isEmpty || !mounted) return;
    setState(() => _toolsFailure = null);
    try {
      await linux.addTools(widget.host, tools);
    } catch (error) {
      debugPrint('$appSlug.linux tools: $error');
      if (mounted) setState(() => _toolsFailure = 'install failed');
    }
  }

  Future<void> _act(
    PhoneLinuxHost linux,
    PhoneLinuxState state,
    String action,
    UserAction? reason,
  ) async {
    final store = ref.read(shellSessionsProvider);
    setState(() {
      _failure = null;
      _busy = switch (action) {
        'STOP' => 'STOPPING',
        'START' => 'STARTING',
        'RESTART' => 'RESTARTING',
        _ => 'PREPARING',
      };
    });
    try {
      switch (action) {
        case 'STOP':
          await linux.stop(widget.host);
        case 'START' || 'RESTART':
          if (action == 'RESTART') await linux.stop(widget.host);
          await linux.ensure(widget.host);
          if (reason != null) store.redialHost(widget.host.id, reason);
        default:
          final catalog = await ref.read(phoneLinuxCatalogProvider.future);
          if (!mounted) return;
          final setup =
              (action == 'RETRY' ? state.setup : null) ??
              await pickPhoneLinuxSetup(
                context,
                catalog: catalog,
                name: widget.host.name,
              );
          if (setup == null) return;
          await linux.install(setup, into: widget.host);
      }
    } catch (error) {
      debugPrint('$appSlug.linux $action: $error');
      if (mounted) setState(() => _failure = '${action.toLowerCase()} failed');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _remove(PhoneLinuxHost linux) async {
    const title = 'REMOVE LINUX';
    final host = widget.host;
    final shells = ref.read(shellSessionsProvider);
    final go = await showPanelSheet<bool>(
      context,
      title: title,
      builder: (_) => ConfirmSheetBody(
        title: title,
        confirmLabel: 'REMOVE',
        message:
            'Deletes the system with every file in it, and the '
            '${host.name} host.',
        onConfirm: UserIntent.onGesture(
          (intent) => unawaited(shells.closeHost(host.id, intent)),
        ),
      ),
    );
    if (go != true || !mounted) return;
    final previews = ref.read(screenPreviewsProvider.future);
    setState(() {
      _failure = null;
      _busy = 'REMOVING';
    });
    try {
      await linux.remove(host);
      await deletePreview(previews, host.id);
    } catch (error) {
      debugPrint('$appSlug.linux remove: $error');
      if (mounted) setState(() => _failure = 'remove failed');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }
}
