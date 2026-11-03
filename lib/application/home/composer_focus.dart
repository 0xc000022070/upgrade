import 'package:flutter_riverpod/flutter_riverpod.dart';

final composerFocusRequestProvider =
    NotifierProvider<ComposerFocusRequest, int>(ComposerFocusRequest.new);

class ComposerFocusRequest extends Notifier<int> {
  @override
  int build() => 0;

  void request() => state++;
}

final composerSummaryProvider = NotifierProvider<ComposerSummary, String?>(
  ComposerSummary.new,
);

class ComposerSummary extends Notifier<String?> {
  Object? _holder;

  @override
  String? build() => null;

  void report(Object holder, String? line) {
    _holder = holder;
    state = line;
  }

  void withdraw([Object? holder]) {
    if (!ref.mounted || (holder != null && !identical(holder, _holder))) return;
    _holder = null;
    state = null;
  }
}
