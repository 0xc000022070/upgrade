import 'dart:typed_data';

import 'package:flutter/services.dart' show TextInputAction, TextInputType;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/application/bundle/bundle.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/design/components/action_block.dart';
import 'package:upgrade/design/components/field_panel.dart';
import 'package:upgrade/design/components/meta.dart';
import 'package:upgrade/design/components/panel.dart';
import 'package:upgrade/design/components/panel_sheet.dart';
import 'package:upgrade/design/components/panel_text_action.dart';
import 'package:upgrade/design/components/solid_action_bar.dart';
import 'package:upgrade/design/icons/upgrade_icons.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/platform/bundle_cipher.dart';
import 'package:upgrade/platform/files/documents.dart';

class BundlePanel extends ConsumerStatefulWidget {
  const BundlePanel({super.key});

  @override
  ConsumerState<BundlePanel> createState() => _BundlePanelState();
}

class _BundlePanelState extends ConsumerState<BundlePanel> {
  ({String words, bool failed})? _last;
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final last = _last;
    return Panel(
      title: '[ BUNDLE ]',
      bodyPadding: panelRowsPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (last != null)
            SizedBox(
              height: RowMetrics.minHeight,
              child: Row(
                children: [
                  SizedBox(
                    width: 96,
                    child: Text('LAST', style: context.tokens.label),
                  ),
                  Expanded(
                    child: Meta(
                      last.words,
                      strong: !last.failed,
                      color: last.failed ? context.tokens.danger : null,
                    ),
                  ),
                ],
              ),
            ),
          PanelTextAction(
            label: 'EXPORT',
            icon: UpgradeIcons.arrowUp,
            onTap: _busy ? null : _export,
          ),
          PanelTextAction(
            label: 'IMPORT',
            icon: UpgradeIcons.arrowDown,
            onTap: _busy ? null : _import,
          ),
        ],
      ),
    );
  }

  void _say(String words, {bool failed = false}) {
    if (!mounted) return;
    setState(() => _last = (words: words, failed: failed));
  }

  /// The sheet does the sealing under its own bar, so `SEALING` is read where the
  /// passphrase was typed. The picker comes up after, and its dismissal is nothing
  /// happening.
  Future<void> _export() async {
    final transfer = ref.read(bundleTransferProvider);
    final cipher = ref.read(bundleCipherProvider);
    setState(() => _busy = true);
    try {
      final outcome = await _passphraseSheet(
        title: 'EXPORT BUNDLE',
        confirm: true,
        busy: 'SEALING',
        action: (passphrase) async {
          final bundle = await transfer.gather();
          final bytes = await cipher.seal(bundle.encode(), passphrase);
          final saved = await Documents.save(
            name: bundleFileName(DateTime.now()),
            bytes: bytes,
          );
          return saved ? _Outcome.done('EXPORTED ${bundle.count.words}') : null;
        },
      );
      if (outcome != null) _say(outcome.words, failed: outcome.failed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    final transfer = ref.read(bundleTransferProvider);
    final cipher = ref.read(bundleCipherProvider);
    setState(() => _busy = true);
    try {
      final Uint8List? file;
      try {
        file = await Documents.open();
      } on BundleException catch (e) {
        _say(bundleLine(e.fault).short, failed: true);
        return;
      }
      if (file == null || !mounted) return;
      final bytes = file;
      final opened = await _passphraseSheet(
        title: 'IMPORT BUNDLE',
        confirm: false,
        busy: 'OPENING',
        action: (passphrase) async => _Outcome.bundle(
          Bundle.decode(await cipher.open(bytes, passphrase)),
        ),
      );
      if (opened == null || !mounted) return;
      final bundle = opened.bundle;
      if (bundle == null) {
        _say(opened.words, failed: opened.failed);
        return;
      }
      if (!await _confirmImport(bundle.count.words) || !mounted) return;
      try {
        final count = await transfer.apply(bundle);
        _say('IMPORTED ${count.words}');
      } on BundleException catch (e) {
        _say(bundleLine(e.fault).short, failed: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<_Outcome?> _passphraseSheet({
    required String title,
    required bool confirm,
    required String busy,
    required Future<_Outcome?> Function(String passphrase) action,
  }) {
    return showPanelSheet<_Outcome>(
      context,
      title: title,
      builder: (context) => PanelSheetBody(
        title: title,
        children: [
          _PassphraseSheet(confirm: confirm, busyLabel: busy, action: action),
        ],
      ),
    );
  }

  Future<bool> _confirmImport(String count) async {
    const title = 'IMPORT BUNDLE';
    final answer = await showPanelSheet<bool>(
      context,
      title: title,
      builder: (context) => PanelSheetBody(
        title: title,
        children: [
          Text(count, style: context.tokens.valueStrong),
          const SizedBox(height: Spacing.md),
          Row(
            children: [
              Expanded(
                child: ActionBlock(
                  label: 'CANCEL',
                  onTap: () => Navigator.of(context).pop(false),
                ),
              ),
              const SizedBox(width: Spacing.md),
              Expanded(
                child: ActionBlock(
                  label: 'IMPORT',
                  tone: context.tokens.accent,
                  filled: true,
                  onTap: () => Navigator.of(context).pop(true),
                ),
              ),
            ],
          ),
        ],
      ),
    );
    return answer ?? false;
  }
}

class _Outcome {
  const _Outcome._(this.words, {required this.failed, this.bundle});

  const _Outcome.done(String words) : this._(words, failed: false);
  const _Outcome.failed(String words) : this._(words, failed: true);
  const _Outcome.bundle(Bundle bundle)
    : this._('', failed: false, bundle: bundle);

  final String words;
  final bool failed;
  final Bundle? bundle;
}

class _PassphraseSheet extends StatefulWidget {
  const _PassphraseSheet({
    required this.confirm,
    required this.busyLabel,
    required this.action,
  });

  final bool confirm;
  final String busyLabel;
  final Future<_Outcome?> Function(String passphrase) action;

  @override
  State<_PassphraseSheet> createState() => _PassphraseSheetState();
}

class _PassphraseSheetState extends State<_PassphraseSheet> {
  final _first = TextEditingController();
  final _second = TextEditingController();
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _first.addListener(_changed);
    _second.addListener(_changed);
  }

  @override
  void dispose() {
    _first.dispose();
    _second.dispose();
    super.dispose();
  }

  void _changed() => setState(() {});

  String? get _missing {
    if (_first.text.isEmpty) return 'PASSPHRASE MISSING';
    if (widget.confirm && _first.text != _second.text) {
      return 'PASSPHRASES DIFFER';
    }
    return null;
  }

  Future<void> _go() async {
    if (_running || _missing != null) return;
    setState(() => _running = true);
    final _Outcome? outcome;
    try {
      outcome = await widget.action(_first.text);
    } on BundleException catch (e) {
      if (mounted) {
        Navigator.of(context).pop(_Outcome.failed(bundleLine(e.fault).short));
      }
      return;
    } catch (_) {
      // Anything else is a bug, not a word for the panel: the bar comes back so the sheet is
      // not stuck on its busy word, and the error goes up.
      if (mounted) setState(() => _running = false);
      rethrow;
    }
    if (mounted) Navigator.of(context).pop(outcome);
  }

  @override
  Widget build(BuildContext context) {
    final missing = _missing;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        FieldPanel(
          label: '[ PASSPHRASE ]',
          controller: _first,
          obscureText: true,
          autofocus: true,
          keyboardType: TextInputType.visiblePassword,
          textInputAction: widget.confirm
              ? TextInputAction.next
              : TextInputAction.done,
          onSubmitted: widget.confirm ? null : (_) => _go(),
        ),
        if (widget.confirm) ...[
          const SizedBox(height: Spacing.md),
          FieldPanel(
            label: '[ AGAIN ]',
            controller: _second,
            obscureText: true,
            keyboardType: TextInputType.visiblePassword,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _go(),
          ),
        ],
        const SizedBox(height: Spacing.md),
        SolidActionBar(
          label: _running
              ? widget.busyLabel
              : missing ?? (widget.confirm ? 'SEAL' : 'OPEN'),
          enabled: !_running && missing == null,
          onTap: _go,
        ),
      ],
    );
  }
}
