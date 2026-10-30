import 'package:flutter_test/flutter_test.dart';
import 'package:widgetbook/widgetbook.dart';

import 'package:upgrade_widgetbook/catalog.dart';
import 'package:upgrade_widgetbook/notes.dart';

Iterable<WidgetbookUseCase> _useCases(WidgetbookNode node) sync* {
  if (node is WidgetbookUseCase) yield node;
  for (final child in node.children ?? const <WidgetbookNode>[]) {
    yield* _useCases(child);
  }
}

void main() {
  test('every component has a note and every note a node', () {
    final useCases = _useCases(WidgetbookRoot(children: directories)).toList();
    final components = {for (final useCase in useCases) useCase.parent!.path};
    final paths = {...components, for (final useCase in useCases) useCase.path};
    expect(components.difference(notes.keys.toSet()), isEmpty);
    expect(notes.keys.toSet().difference(paths), isEmpty);
  });
}
