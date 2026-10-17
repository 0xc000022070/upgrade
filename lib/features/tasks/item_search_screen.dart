import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:striked/app/static_surface.dart';
import 'package:striked/application/drops/item_search.dart';
import 'package:striked/application/providers.dart';
import 'package:striked/data/views.dart';
import 'package:striked/design/components/striked_field.dart';
import 'package:striked/design/components/list_row.dart';
import 'package:striked/design/components/panel.dart';
import 'package:striked/design/components/section.dart';
import 'package:striked/design/spacing.dart';
import 'package:striked/design/tokens.dart';
import 'package:striked/design/components/screen_scaffold.dart';
import 'package:striked/features/tasks/task_row.dart';

void openItemSearch(BuildContext context) {
  Navigator.of(
    context,
    rootNavigator: true,
  ).push(MaterialPageRoute<void>(builder: (_) => const ItemSearchScreen()));
}

class ItemSearchScreen extends ConsumerStatefulWidget {
  const ItemSearchScreen({super.key});

  @override
  ConsumerState<ItemSearchScreen> createState() => _ItemSearchScreenState();
}

class _ItemSearchScreenState extends ConsumerState<ItemSearchScreen> {
  final _query = TextEditingController();
  Set<SearchMark> _marks = const {};

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hits = ref.watch(searchHitsProvider);
    final all = hits.valueOrNull ?? const <SearchHit>[];
    final worded = [
      for (final hit in all)
        if (matchesWords(hit, _query.text)) hit,
    ];
    final results = searchItems(worded, '', _marks);

    return Scaffold(
      body: StaticSurface(
        child: ScreenScaffold(
          title: 'SEARCH',
          breadcrumb: '/ STRIKED / SEARCH',
          onBack: () => Navigator.of(context).pop(),
          children: [
            PanelStack(
              children: [
                Panel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      StrikedField(
                        key: const ValueKey('item-search-field'),
                        controller: _query,
                        autofocus: true,
                        hint: 'words from an item, its prompt or a link',
                        semanticLabel: 'Search items',
                        textInputAction: TextInputAction.search,
                        contentPadding: const EdgeInsets.symmetric(
                          vertical: Spacing.md,
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                      Wrap(
                        spacing: Spacing.lg,
                        children: [
                          for (final mark in SearchMark.values)
                            _MarkToggle(
                              mark: mark,
                              lit: _marks.contains(mark),
                              count: !hits.hasValue
                                  ? null
                                  : _marks.contains(mark)
                                  ? results.length
                                  : searchItems(
                                      worded,
                                      '',
                                      toggleMark(_marks, mark),
                                    ).length,
                              onTap: () => setState(
                                () => _marks = toggleMark(_marks, mark),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                Panel(
                  title: 'ITEMS',
                  affordance: PanelAffordance(
                    '${results.length}',
                    showIcon: false,
                  ),
                  bodyPadding: panelRowsPadding,
                  child: AsyncSection(
                    value: hits.whenData((_) => results),
                    empty: all.isEmpty ? 'nothing captured' : 'no match',
                    builder: (items) => ListRowGroup(
                      children: [
                        for (final hit in items)
                          TaskRow(
                            key: ValueKey(hit.task.id),
                            task: hit.task,
                            drop: hit.task.projectId == null,
                            place: hit.location.label,
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MarkToggle extends StatelessWidget {
  const _MarkToggle({
    required this.mark,
    required this.lit,
    required this.count,
    required this.onTap,
  });

  final SearchMark mark;
  final bool lit;

  final int? count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final spent = !lit && count == 0;
    final ink = lit
        ? context.tokens.accent
        : spent
        ? context.tokens.textDisabled
        : context.tokens.textMuted;
    return Semantics(
      button: true,
      toggled: lit,
      enabled: !spent,
      label: mark.label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: spent ? null : onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: TapTargets.minHeight),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                mark.label,
                style: context.tokens.panelHeader.copyWith(color: ink),
              ),
              if (count != null) ...[
                const SizedBox(width: Spacing.sm),
                Text(
                  '$count',
                  style: context.tokens.panelHeader.copyWith(
                    color: lit
                        ? context.tokens.accent
                        : context.tokens.textDisabled,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
