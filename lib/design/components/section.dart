import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../colors.dart';
import '../spacing.dart';
import '../typography.dart';
import 'dither_field.dart';
import 'dot_spinner.dart';

/// SPEC.md §16c.5: nothing is blank. An empty panel body is a short dithered
/// band with the reason written over it, sized to the §38.3 single row so the
/// panel keeps its rhythm instead of collapsing.
class EmptyState extends StatelessWidget {
  const EmptyState(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: RowMetrics.minHeight,
      child: DitherField(
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(label.toUpperCase(), style: HotlineText.label),
        ),
      ),
    );
  }
}

/// A local SQLite read resolves within a frame or two, so the spinner is held
/// back behind the §16c.6 threshold rather than flashed and removed.
class AsyncSection<T> extends StatelessWidget {
  const AsyncSection({
    super.key,
    required this.value,
    required this.empty,
    required this.builder,
    this.isEmpty,
  });

  final AsyncValue<T> value;
  final String empty;
  final Widget Function(T value) builder;
  final bool Function(T value)? isEmpty;

  @override
  Widget build(BuildContext context) {
    return value.when(
      loading: () => const DelayedSpinner(),
      error: (error, _) => Text(
        'error: $error',
        style: HotlineText.value.copyWith(color: HotlineColors.danger),
      ),
      data: (data) {
        final blank = isEmpty?.call(data) ?? (data is List && data.isEmpty);
        if (blank) return EmptyState(empty);
        return builder(data);
      },
    );
  }
}
