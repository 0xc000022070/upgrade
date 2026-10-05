import 'dart:async';

import 'package:flterm/flterm.dart';
import 'package:flutter/material.dart';

import '../../design/tokens.dart';
import '../../design/components/cell_divider.dart';
import '../../design/components/key_cell.dart';
import '../../design/components/upgrade_field.dart';
import '../../design/icons/upgrade_icons.dart';
import '../../design/motion.dart';
import '../../design/spacing.dart';
import 'shell_sessions.dart';

const _typingSettles = Motion.instant;

/// It reads the buffer and never writes to the shell. The field takes the keyboard off
/// the terminal for as long as the line is up, which is what makes the characters land
/// here instead of in the remote.
class ShellSearchRow extends StatefulWidget {
  const ShellSearchRow({
    super.key,
    required this.session,
    required this.onClose,
  });

  final ShellSession session;
  final VoidCallback onClose;

  @override
  State<ShellSearchRow> createState() => _ShellSearchRowState();
}

class _ShellSearchRowState extends State<ShellSearchRow> {
  final _query = TextEditingController();
  Timer? _typing;

  bool _landing = false;

  TerminalController? _bound;

  @override
  void initState() {
    super.initState();
    widget.session.terminals.addListener(_onSwap);
    _bind(widget.session.terminal);
  }

  @override
  void didUpdateWidget(ShellSearchRow old) {
    super.didUpdateWidget(old);
    if (old.session != widget.session) {
      _leave(old.session);
      widget.session.terminals.addListener(_onSwap);
      _bind(widget.session.terminal);
      _run();
    }
  }

  @override
  void dispose() {
    _typing?.cancel();
    // The marks go after the frame, not in it: clearing tells the view, and a
    // notification sent while the tree is being taken down reaches views that can no
    // longer be marked dirty. A tab that went took its search with it.
    final session = widget.session;
    session.terminals.removeListener(_onSwap);
    _bound?.search.removeListener(_onSearch);
    _bound = null;
    scheduleMicrotask(() {
      if (!session.retired) session.terminal.search.clear();
    });
    _query.dispose();
    super.dispose();
  }

  void _leave(ShellSession session) {
    session.terminals.removeListener(_onSwap);
    _bound?.search.removeListener(_onSearch);
    _bound = null;
    session.terminal.search.clear();
  }

  void _bind(TerminalController terminal) {
    _bound?.search.removeListener(_onSearch);
    _bound = terminal..search.addListener(_onSearch);
  }

  void _onSwap() {
    _bind(widget.session.terminal);
    _run();
  }

  void _onSearch() {
    if (!mounted) return;
    final search = widget.session.terminal.search;
    if (_landing && search.totalMatches > 0 && search.selectedIndex == null) {
      _landing = false;
      search.next();
      return;
    }
    setState(() {});
  }

  void _onQuery(String _) {
    _typing?.cancel();
    _typing = Timer(_typingSettles, _run);
  }

  void _run() {
    final query = _query.text.trim();
    _landing = query.isNotEmpty;
    widget.session.terminal.search.search(query);
    _onSearch();
  }

  void _older() => widget.session.terminal.search.next();

  void _newer() => widget.session.terminal.search.previous();

  @override
  Widget build(BuildContext context) {
    final search = widget.session.terminal.search;
    final total = search.totalMatches;
    final selected = search.selectedIndex;
    final at = selected == null ? 0 : total - selected;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.tokens.surfacePrimary,
        border: Border(top: BorderSide(color: context.tokens.borderSubtle)),
      ),
      child: SizedBox(
        height: RowMetrics.minHeight,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: RowMetrics.padding,
                ),
                child: Center(
                  child: UpgradeField(
                    key: const ValueKey('shell-find-field'),
                    controller: _query,
                    autofocus: true,
                    hint: 'FIND',
                    textInputAction: TextInputAction.search,
                    suggest: false,
                    onChanged: _onQuery,
                    onSubmitted: (_) => _older(),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: RowMetrics.padding,
              ),
              child: Center(
                child: Text(
                  key: const ValueKey('shell-find-count'),
                  '$at/$total',
                  style: context.tokens.value,
                ),
              ),
            ),
            const CellDivider(),
            KeyCell(
              key: const ValueKey('shell-find-prev'),
              label: 'PREV',
              icon: UpgradeIcons.arrowUp,
              inert: total == 0,
              minWidth: RowMetrics.minHeight,
              padding: RowMetrics.padding,
              onTap: _older,
            ),
            KeyCell(
              key: const ValueKey('shell-find-next'),
              label: 'NEXT',
              icon: UpgradeIcons.arrowDown,
              inert: total == 0,
              minWidth: RowMetrics.minHeight,
              padding: RowMetrics.padding,
              onTap: _newer,
            ),
            const CellDivider(),
            KeyCell(
              key: const ValueKey('shell-find-close'),
              label: '×',
              minWidth: RowMetrics.minHeight,
              padding: RowMetrics.padding,
              onTap: widget.onClose,
            ),
          ],
        ),
      ),
    );
  }
}
