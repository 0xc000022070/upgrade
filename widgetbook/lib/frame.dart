import 'package:flutter/material.dart';

import 'package:upgrade/design/components/action_block.dart';
import 'package:upgrade/design/components/meta.dart';
import 'package:upgrade/design/layout.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/design/tokens.dart';

class Stage extends StatelessWidget {
  const Stage({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: context.tokens.backgroundPrimary,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Spacing.screenEdge),
        child: ContentColumn(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0) const SizedBox(height: Spacing.xxl),
                children[i],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class Specimen extends StatelessWidget {
  const Specimen(this.label, {super.key, this.note, required this.child});

  final String label;
  final String? note;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final note = this.note;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('[ ${label.toUpperCase()} ]', style: context.tokens.label),
        if (note != null) ...[
          const SizedBox(height: Spacing.xs),
          Meta(note, maxLines: 4),
        ],
        const SizedBox(height: Spacing.md),
        child,
      ],
    );
  }
}

class SheetStage extends StatelessWidget {
  const SheetStage({super.key, required this.open});

  final Future<Object?> Function(BuildContext context) open;

  @override
  Widget build(BuildContext context) {
    return Navigator(
      onGenerateRoute: (_) => PageRouteBuilder<void>(
        pageBuilder: (context, _, _) => _SheetHome(open: open),
      ),
    );
  }
}

class _SheetHome extends StatefulWidget {
  const _SheetHome({required this.open});

  final Future<Object?> Function(BuildContext context) open;

  @override
  State<_SheetHome> createState() => _SheetHomeState();
}

class _SheetHomeState extends State<_SheetHome> {
  String _answer = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _open());
  }

  Future<void> _open() async {
    if (!mounted) return;
    final answer = await widget.open(context);
    if (!mounted) return;
    setState(() => _answer = 'ANSWERED ${answer ?? 'NOTHING'}');
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: context.tokens.backgroundPrimary,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Meta(_answer),
            const SizedBox(height: Spacing.md),
            ActionBlock(label: 'OPEN SHEET', onTap: _open),
          ],
        ),
      ),
    );
  }
}
