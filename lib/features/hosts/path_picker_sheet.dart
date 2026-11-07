import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/application/shell/path_scan.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/data/repositories/path_repository.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/design/components/action_block.dart';
import 'package:upgrade/design/components/dot_spinner.dart';
import 'package:upgrade/design/components/field_panel.dart';
import 'package:upgrade/design/components/list_row.dart';
import 'package:upgrade/design/components/panel.dart';
import 'package:upgrade/design/components/panel_sheet.dart';
import 'package:upgrade/design/spacing.dart';

Future<String?> showPathPicker(
  BuildContext context, {
  required Host host,
  Set<String> taken = const {},
}) {
  return showPanelSheet<String>(
    context,
    title: 'PATH ON ${host.name.toUpperCase()}',
    builder: (context) => _PathPickerBody(host: host, taken: taken),
  );
}

class _PathPickerBody extends ConsumerStatefulWidget {
  const _PathPickerBody({required this.host, required this.taken});

  final Host host;
  final Set<String> taken;

  @override
  ConsumerState<_PathPickerBody> createState() => _PathPickerBodyState();
}

class _PathPickerBodyState extends ConsumerState<_PathPickerBody> {
  final _filter = TextEditingController();

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  void _rescan() => ref.invalidate(checkoutsFoundProvider(widget.host.id));

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
    final scan = ref.watch(checkoutsFoundProvider(widget.host.id)).value;
    return PanelSheetBody(
      title: 'PATH ON ${widget.host.name.toUpperCase()}',
      affordance: PanelAffordance(
        'CANCEL',
        onTap: () => Navigator.pop(context),
      ),
      children: switch (scan) {
        null => const [
          Padding(
            padding: EdgeInsets.symmetric(vertical: Spacing.xl),
            child: Center(child: DotSpinner()),
          ),
        ],
        PathScanFailed(:final reason) => [
          Text(reason.toUpperCase(), style: context.tokens.panelHeader),
          const SizedBox(height: Spacing.lg),
          Row(
            children: [ActionBlock(label: 'RETRY', onTap: _rescan)],
          ),
        ],
        PathScanFound(:final directories) when directories.isEmpty => [
          Text('NO CHECKOUTS REPORTED', style: context.tokens.panelHeader),
          const SizedBox(height: Spacing.lg),
          Row(
            children: [ActionBlock(label: 'RESCAN', onTap: _rescan)],
          ),
        ],
        PathScanFound(:final directories) => _list(directories),
        PathScanLoading() => const [],
      },
    );
  }

  List<Widget> _list(List<String> directories) {
    final matching = _matching(directories);
    final offered = directories.where((d) => !widget.taken.contains(d)).length;
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
                title: shortPathLabel(directory),
                literalTitle: true,
                onTap: () => Navigator.pop(context, directory),
              ),
          ],
        ),
    ];
  }
}
