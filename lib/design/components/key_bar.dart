import 'package:flutter/widgets.dart';

import '../tokens.dart';
import '../spacing.dart';
import 'cell_divider.dart';

const _fadeWidth = 32.0;
const _fadeSolid = 0.28;

class KeyBar extends StatelessWidget {
  const KeyBar({super.key, required this.keys, this.pinned = const []});

  static const height = RowMetrics.minHeight;

  static const cellPadding = RowMetrics.padding;

  final List<Widget> keys;
  final List<Widget> pinned;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: context.tokens.surfacePrimary,
        border: Border(top: BorderSide(color: context.tokens.borderSubtle)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: _Keys(children: keys)),
          if (pinned.isNotEmpty) ...[const CellDivider(), ...pinned],
        ],
      ),
    );
  }
}

class _Keys extends StatefulWidget {
  const _Keys({required this.children});

  final List<Widget> children;

  @override
  State<_Keys> createState() => _KeysState();
}

class _KeysState extends State<_Keys> {
  var _before = 0.0;
  var _after = 0.0;

  bool _onMetrics(ScrollMetrics metrics) {
    if (metrics.extentBefore == _before && metrics.extentAfter == _after) {
      return false;
    }
    setState(() {
      _before = metrics.extentBefore;
      _after = metrics.extentAfter;
    });
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (notification) => _onMetrics(notification.metrics),
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) => _onMetrics(notification.metrics),
        child: Stack(
          fit: StackFit.passthrough,
          children: [
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: widget.children,
              ),
            ),
            if (_before > 0) const _Fade(key: ValueKey('bar-fade-start')),
            if (_after > 0)
              const _Fade(key: ValueKey('bar-fade-end'), end: true),
          ],
        ),
      ),
    );
  }
}

class _Fade extends StatelessWidget {
  const _Fade({super.key, this.end = false});

  final bool end;

  @override
  Widget build(BuildContext context) => Positioned(
    top: 0,
    bottom: 0,
    left: end ? null : 0,
    right: end ? 0 : null,
    width: _fadeWidth,
    child: IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: end ? Alignment.centerRight : Alignment.centerLeft,
            end: end ? Alignment.centerLeft : Alignment.centerRight,
            colors: [
              context.tokens.surfacePrimary,
              context.tokens.surfacePrimary.withValues(alpha: 0),
            ],
            stops: const [_fadeSolid, 1],
          ),
        ),
      ),
    ),
  );
}
