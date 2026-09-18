import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../tokens.dart';
import '../spacing.dart';
import 'dither_field.dart';
import 'dot_spinner.dart';

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
          child: Text(label.toUpperCase(), style: context.tokens.label),
        ),
      ),
    );
  }
}

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
        style: context.tokens.value.copyWith(color: context.tokens.danger),
      ),
      data: (data) {
        final blank = isEmpty?.call(data) ?? (data is List && data.isEmpty);
        if (blank) return EmptyState(empty);
        return builder(data);
      },
    );
  }
}
