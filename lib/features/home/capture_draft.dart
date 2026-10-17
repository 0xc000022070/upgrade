import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:striked/data/repositories/attachment_repository.dart';
import 'package:striked/data/views.dart';

final captureDraftProvider = Provider.family<CaptureDraft, String>((
  ref,
  scope,
) {
  final draft = CaptureDraft();
  ref.onDispose(draft.dispose);
  return draft;
});

class CaptureDraft extends ChangeNotifier {
  TextEditingValue _text = TextEditingValue.empty;
  TextEditingValue get text => _text;
  set text(TextEditingValue value) {
    if (_text == value) return;
    _text = value;
    notifyListeners();
  }

  ItemTarget target = const ItemTarget.drops();
  final attachments = <NewAttachment>[];
}
