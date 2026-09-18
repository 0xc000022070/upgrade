import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/path_scan.dart';
import '../../data/repositories/host_repository.dart';
import '../../data/repositories/path_repository.dart';
import '../../design/tokens.dart';
import '../../design/components/action_block.dart';
import '../../design/components/dot_spinner.dart';
import '../../design/components/field_panel.dart';
import '../../design/components/list_row.dart';
import '../../design/components/panel.dart';
import '../../design/components/panel_sheet.dart';
import '../../design/spacing.dart';

Future<List<String>?> showPathPicker(
  BuildContext context, {
  required Host host,
  bool multiple = false,
  Set<String> taken = const {},
}) {
  return showPanelSheet<List<String>>(
    context,
    title: 'PATH ON ${host.name.toUpperCase()}',
    builder: (context) =>
        _PathPickerBody(host: host, multiple: multiple, taken: taken),
  );
}

/// A mono `[ ]` is wider than the 14px glyph slot the row keeps by default.
const _checkbox = 24.0;

class _PathPickerBody extends ConsumerStatefulWidget {
  const _PathPickerBody({
    required this.host,
    required this.multiple,
    required this.taken,
  });

  final Host host;
  final bool multiple;
  final Set<String> taken;

  @override
  ConsumerState<_PathPickerBody> createState() => _PathPickerBodyState();
}

class _PathPickerBodyState extends ConsumerState<_PathPickerBody> {
  final _filter = TextEditingController();
  final _chosen = <String>{};
  PathScan _scan = const PathScanLoading();
  bool _manual = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _scan = const PathScanLoading());
    final scan = await ref.read(pathScannerProvider)(widget.host);
    if (mounted) setState(() => _scan = scan);
  }

  List<String> _matching(List<String> directories) {
    final needle = _filter.text.trim().toLowerCase();
    return [
      for (final directory in directories)
        if (!widget.taken.contains(directory) &&
            (needle.isEmpty || directory.toLowerCase().contains(needle)))
          directory,
    ];
  }

  @override
  Widget build(BuildContext context) {
    return PanelSheetBody(
      title: 'PATH ON ${widget.host.name.toUpperCase()}',
      affordance: PanelAffordance(
        'CANCEL',
        onTap: () => Navigator.pop(context),
      ),
      children: _body(),
    );
  }

  List<Widget> _body() {
    if (_manual) return _manualEntry();
    return switch (_scan) {
      PathScanLoading() => const [
        Padding(
          padding: EdgeInsets.symmetric(vertical: Spacing.xl),
          child: Center(child: DotSpinner()),
        ),
      ],
      PathScanFailed(:final reason) => [
        Text(reason.toUpperCase(), style: context.tokens.panelHeader),
        const SizedBox(height: Spacing.lg),
        Row(
          children: [
            ActionBlock(label: 'RETRY', onTap: _load),
            const SizedBox(width: Spacing.md),
            ActionBlock(
              label: 'TYPE IT',
              onTap: () => setState(() => _manual = true),
            ),
          ],
        ),
      ],
      // A host whose every checkout is already registered is not this case: that one keeps the
      // list so the filter and the escape hatch stay reachable.
      PathScanFound(:final directories) when directories.isEmpty => [
        Text('NO CHECKOUTS REPORTED', style: context.tokens.panelHeader),
        const SizedBox(height: Spacing.lg),
        Row(
          children: [
            ActionBlock(label: 'RESCAN', onTap: _load),
            const SizedBox(width: Spacing.md),
            ActionBlock(
              label: 'TYPE IT',
              onTap: () => setState(() => _manual = true),
            ),
          ],
        ),
      ],
      PathScanFound(:final directories) => _list(directories),
    };
  }

  List<Widget> _list(List<String> directories) {
    final matching = _matching(directories);
    final offered = directories.length - widget.taken.length;
    return [
      FieldPanel(
        label: 'FILTER',
        controller: _filter,
        hint: '$offered checkouts',
        autofocus: false,
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) => setState(() {}),
      ),
      const SheetRule(),
      if (matching.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: Spacing.lg),
          child: Text(
            _filter.text.trim().isEmpty ? 'ALL REGISTERED' : 'NO MATCH',
            style: context.tokens.panelHeader,
          ),
        )
      else
        ListRowGroup(
          children: [
            for (final directory in matching)
              ListRow(
                leading: widget.multiple
                    ? Text(
                        _chosen.contains(directory) ? '[x]' : '[ ]',
                        style: context.tokens.rowTitle,
                      )
                    : null,
                leadingWidth: _checkbox,
                title: shortPathLabel(directory),
                titleColor: !widget.multiple || _chosen.contains(directory)
                    ? null
                    : context.tokens.textSecondary,
                onTap: () => _take(directory),
              ),
          ],
        ),
      const SheetRule(),
      Row(
        children: [
          ActionBlock(
            label: 'TYPE A PATH',
            tone: context.tokens.textSecondary,
            onTap: () => setState(() => _manual = true),
          ),
          if (widget.multiple) ...[
            const Spacer(),
            ActionBlock(
              label: 'ADD ${_chosen.length}',
              filled: _chosen.isNotEmpty,
              tone: _chosen.isEmpty
                  ? context.tokens.textSecondary
                  : context.tokens.accent,
              onTap: () {
                if (_chosen.isEmpty) return;
                Navigator.pop(context, _chosen.toList());
              },
            ),
          ],
        ],
      ),
    ];
  }

  void _take(String directory) {
    if (!widget.multiple) {
      Navigator.pop(context, [directory]);
      return;
    }
    setState(() {
      if (!_chosen.remove(directory)) _chosen.add(directory);
    });
  }

  List<Widget> _manualEntry() {
    final controller = _filter;
    return [
      FieldPanel(
        label: 'DIRECTORY',
        controller: controller,
        hint: '~/src/project',
        autofocus: true,
        textInputAction: TextInputAction.done,
        onSubmitted: (value) => _commitManual(value),
      ),
      const SizedBox(height: Spacing.lg),
      Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          ActionBlock(
            label: 'BACK',
            onTap: () => setState(() => _manual = false),
          ),
          const SizedBox(width: Spacing.md),
          ActionBlock(
            label: 'USE',
            filled: true,
            tone: context.tokens.accent,
            onTap: () => _commitManual(controller.text),
          ),
        ],
      ),
    ];
  }

  void _commitManual(String value) {
    final directory = value.trim();
    if (directory.isEmpty) return;
    Navigator.pop(context, [directory]);
  }
}
