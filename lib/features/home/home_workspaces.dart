import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/application/plugins/native_plugins.dart';
import 'package:upgrade/application/plugins/plugin_placements.dart';
import 'package:upgrade/data/repositories/plugin_placement_repository.dart';
import 'package:upgrade/design/components/action_block.dart';
import 'package:upgrade/design/components/list_row.dart';
import 'package:upgrade/design/components/panel.dart';
import 'package:upgrade/design/components/panel_sheet.dart';
import 'package:upgrade/design/components/panel_text_action.dart';
import 'package:upgrade/design/components/upgrade_field.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/features/plugins/plugin_management_screen.dart';
import 'package:upgrade/platform/plugins/contributions.dart';

PluginWidgetRegistration? homeShown(
  PluginContributionCatalog catalog,
  PluginPlacementState placements,
  String id,
) => switch (catalog.widget(id)) {
  final widget?
      when widget.enabled &&
          placements.placements[id] == PluginPlacementLocation.homeCard &&
          !placements.hiddenHome.contains(id) =>
    widget,
  _ => null,
};

List<int> homeNumbers(
  PluginContributionCatalog catalog,
  PluginPlacementState placements,
) => {
  for (final MapEntry(key: space, value: tile) in placements.homeTiles.entries)
    if (tile.cards.any((id) => homeShown(catalog, placements, id) != null))
      space,
  ...placements.homeNames.keys,
  placements.homeSpace,
}.toList()..sort();

int? homeFreeNumber(List<int> numbers) => [
  for (var n = 1; n <= homeSpaceCount; n++)
    if (!numbers.contains(n)) n,
].firstOrNull;

String homeLabel(PluginPlacementState placements, int space) =>
    placements.homeNames[space]?.toUpperCase() ?? '$space';

Future<void> showWorkspaceName(
  BuildContext context, {
  required int space,
  required bool fresh,
}) => showPanelSheet<void>(
  context,
  title: fresh ? 'NEW WORKSPACE' : 'RENAME WORKSPACE',
  builder: (context) => _NameSheet(space: space, fresh: fresh),
);

class _NameSheet extends ConsumerStatefulWidget {
  const _NameSheet({required this.space, required this.fresh});

  final int space;
  final bool fresh;

  @override
  ConsumerState<_NameSheet> createState() => _NameSheetState();
}

class _NameSheetState extends ConsumerState<_NameSheet> {
  late final _field = TextEditingController(
    text: widget.fresh
        ? ''
        : ref
                  .read(pluginPlacementsProvider)
                  .valueOrNull
                  ?.homeNames[widget.space] ??
              '',
  );

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _save() {
    Navigator.of(context).pop();
    unawaited(
      ref
          .read(pluginPlacementsProvider.notifier)
          .nameHomeSpace(widget.space, _field.text, show: widget.fresh),
    );
  }

  @override
  Widget build(BuildContext context) => PanelSheetBody(
    title: widget.fresh ? 'NEW WORKSPACE' : 'RENAME WORKSPACE',
    children: [
      UpgradeField(
        controller: _field,
        autofocus: true,
        maxLength: homeNameLength,
        style: context.tokens.rowTitleLead,
        hint: '${widget.space}',
        semanticLabel: 'WORKSPACE NAME',
        contentPadding: const EdgeInsets.symmetric(vertical: Spacing.sm),
        onSubmitted: (_) => _save(),
      ),
      const SizedBox(height: Spacing.md),
      Text(
        widget.fresh
            ? 'BLANK KEEPS THE NUMBER, ${widget.space}.'
            : 'BLANK TAKES THE NAME AWAY.',
        style: context.tokens.rowSubtitle,
      ),
      const SizedBox(height: Spacing.md),
      Row(
        children: [
          Expanded(
            child: ActionBlock(
              label: 'CANCEL',
              onTap: () => Navigator.of(context).pop(),
            ),
          ),
          const SizedBox(width: Spacing.md),
          Expanded(
            child: ActionBlock(
              label: widget.fresh ? 'OPEN' : 'SAVE',
              tone: context.tokens.accent,
              filled: true,
              onTap: _save,
            ),
          ),
        ],
      ),
    ],
  );
}

Future<void> showWorkspaces(BuildContext context) => showPanelSheet<void>(
  context,
  title: 'WORKSPACES',
  builder: (context) => const _Overview(),
);

class _Overview extends ConsumerWidget {
  const _Overview();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final catalog = ref.watch(pluginContributionCatalogProvider);
    final placements = ref.watch(pluginPlacementsProvider).valueOrNull;
    if (placements == null) return const SizedBox.shrink();
    final numbers = homeNumbers(catalog, placements);
    final free = homeFreeNumber(numbers);
    final layout = ref.read(pluginPlacementsProvider.notifier);
    return PanelSheetBody(
      title: 'WORKSPACES',
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final width = (constraints.maxWidth - Spacing.md) / 2;
            return Wrap(
              spacing: Spacing.md,
              runSpacing: Spacing.md,
              children: [
                for (final n in numbers)
                  _Preview(
                    key: ValueKey('workspace-preview-$n'),
                    width: width,
                    label: placements.homeNames.containsKey(n)
                        ? '$n · ${homeLabel(placements, n)}'
                        : '$n',
                    lit: n == placements.homeSpace,
                    tile: _pruned(
                      placements.tileOf(n),
                      (id) => homeShown(catalog, placements, id) != null,
                    ),
                    titleOf: (id) =>
                        catalog.widget(id)?.contribution.title ?? id,
                    onTap: () {
                      Navigator.of(context).pop();
                      unawaited(layout.showHomeSpace(n));
                    },
                  ),
                if (free != null)
                  _Preview(
                    key: const ValueKey('workspace-preview-new'),
                    width: width,
                    label: '+ NEW',
                    lit: false,
                    tile: null,
                    titleOf: (id) => id,
                    onTap: () {
                      final navigator = Navigator.of(context)..pop();
                      unawaited(
                        showWorkspaceName(
                          navigator.context,
                          space: free,
                          fresh: true,
                        ),
                      );
                    },
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

HomeTile? _pruned(HomeTile? tile, bool Function(String id) shows) =>
    switch (tile) {
      null => null,
      HomeCard(:final id) => shows(id) ? tile : null,
      HomeSplit(:final axis, :final children, :final weight) => switch ([
        for (final child in children) ?_pruned(child, shows),
      ]) {
        [] => null,
        [final only] => only.weighted(weight),
        final kept => HomeSplit(axis, kept, weight: weight),
      },
    };

class _Preview extends StatelessWidget {
  const _Preview({
    super.key,
    required this.width,
    required this.label,
    required this.lit,
    required this.tile,
    required this.titleOf,
    required this.onTap,
  });

  final double width;
  final String label;
  final bool lit;
  final HomeTile? tile;
  final String Function(String id) titleOf;
  final VoidCallback onTap;

  Widget _draw(BuildContext context, HomeTile tile) => switch (tile) {
    HomeCard(:final id) => Container(
      alignment: Alignment.topLeft,
      padding: const EdgeInsets.all(Spacing.sm),
      decoration: BoxDecoration(
        border: Border.all(
          color: context.tokens.borderNormal,
          width: Borders.hairline,
        ),
      ),
      child: Text(
        titleOf(id).toUpperCase(),
        style: context.tokens.label,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
    ),
    HomeSplit(:final axis, :final children) => Flex(
      direction: axis == HomeAxis.row ? Axis.horizontal : Axis.vertical,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: Spacing.xs,
      children: [
        for (final child in children)
          Expanded(
            flex: (child.weight * 100).round().clamp(1, 10000),
            child: _draw(context, child),
          ),
      ],
    ),
  };

  @override
  Widget build(BuildContext context) {
    final tile = this.tile;
    final ink = lit ? context.tokens.accent : context.tokens.textSecondary;
    return Semantics(
      button: true,
      selected: lit,
      label: 'WORKSPACE $label',
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          width: width,
          height: width * 0.75,
          padding: const EdgeInsets.all(Spacing.md),
          decoration: BoxDecoration(
            color: context.tokens.surfaceSecondary,
            border: Border.all(
              color: lit ? context.tokens.accent : context.tokens.borderNormal,
              width: Borders.hairline,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                label,
                style: context.tokens.panelHeader.copyWith(color: ink),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: Spacing.md),
              Expanded(
                child: tile == null
                    ? Center(
                        child: Text(
                          'EMPTY',
                          style: context.tokens.label.copyWith(
                            color: context.tokens.textMuted,
                          ),
                        ),
                      )
                    : _draw(context, tile),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> showAddWidgets(BuildContext context) => showPanelSheet<void>(
  context,
  title: 'ADD WIDGETS',
  builder: (context) => const _AddWidgets(),
);

class _AddWidgets extends ConsumerWidget {
  const _AddWidgets();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final catalog = ref.watch(pluginContributionCatalogProvider);
    final placements = ref.watch(pluginPlacementsProvider).valueOrNull;
    if (placements == null) return const SizedBox.shrink();
    final space = placements.homeSpace;
    final layout = ref.read(pluginPlacementsProvider.notifier);
    final offered = [
      for (final widget in catalog.widgets)
        if (widget.enabled &&
            widget.contribution.locations.contains(
              PluginPlacementLocation.homeCard,
            ) &&
            !(homeShown(catalog, placements, widget.stableId) != null &&
                placements.spaceOf(widget.stableId) == space))
          widget,
    ];
    String where(String id) => switch (placements.placements[id]) {
      PluginPlacementLocation.homeCard
          when placements.hiddenHome.contains(id) =>
        'HIDDEN',
      PluginPlacementLocation.homeCard =>
        'ON ${[for (final MapEntry(key: at, value: tile) in placements.homeTiles.entries)
          if (tile.cards.contains(id)) homeLabel(placements, at)].join(' · ')}',
      PluginPlacementLocation.homeComposer => 'INPUT BAR',
      null => 'NOT PLACED',
    };
    return PanelSheetBody(
      title: 'ADD TO ${homeLabel(placements, space)}',
      children: [
        if (offered.isEmpty)
          Text(
            'EVERY CARD IS ALREADY HERE.',
            style: context.tokens.rowSubtitle,
          ),
        for (final widget in offered)
          ListRow(
            key: ValueKey('add-${widget.stableId}'),
            title: widget.contribution.title.toUpperCase(),
            subtitle: where(widget.stableId),
            value: 'ADD',
            valueColor: context.tokens.accent,
            onTap: () => unawaited(layout.bringHome(widget.stableId)),
          ),
        PanelTextAction(
          label: 'MANAGE PLUGINS',
          onTap: () {
            final navigator = Navigator.of(context)..pop();
            openPluginManagement(navigator.context);
          },
        ),
      ],
    );
  }
}

class HomeEditBar extends StatelessWidget {
  const HomeEditBar({
    super.key,
    required this.selected,
    required this.arrangement,
    required this.onArrange,
    required this.onAdd,
    required this.onDone,
  });

  final int selected;

  final (int, int)? arrangement;
  final VoidCallback? onArrange;
  final VoidCallback onAdd;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final step = arrangement;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Spacing.screenEdge,
        Spacing.md,
        Spacing.screenEdge,
        Spacing.md,
      ),
      child: Panel(
        title: switch (selected) {
          0 => 'EDIT LAYOUT · TAP CARDS TO GATHER THEM',
          1 => 'EDIT LAYOUT · 1 SELECTED',
          final n => 'EDIT LAYOUT · $n SELECTED',
        },
        bodyPadding: const EdgeInsets.all(Spacing.panelPadding),
        child: Row(
          children: [
            Expanded(
              child: ActionBlock(label: 'ADD', onTap: onAdd),
            ),
            const SizedBox(width: Spacing.md),
            Expanded(
              child: ActionBlock(
                label: step == null
                    ? 'LAYOUT'
                    : 'LAYOUT ${step.$1 + 1}/${step.$2}',
                tone: onArrange == null
                    ? context.tokens.textDisabled
                    : context.tokens.textSecondary,
                onTap: onArrange,
              ),
            ),
            const SizedBox(width: Spacing.md),
            Expanded(
              child: ActionBlock(
                label: 'DONE',
                tone: context.tokens.accent,
                filled: true,
                onTap: onDone,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
