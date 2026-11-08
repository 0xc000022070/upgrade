import 'package:upgrade/application/plugins/native_plugins.dart';
import 'package:upgrade/data/plugins/contributions.dart';

String pluginPromise(PluginContributionOwner owner) => [
  for (final page in owner.pages)
    '${page.contribution.title.toUpperCase()} '
        '${page.contribution.defaultPinned ? 'TAB' : 'PAGE'}',
  for (final widget in owner.widgets)
    '${widget.contribution.title.toUpperCase()} '
        '${switch (widget.contribution.defaultLocation) {
          PluginPlacementLocation.homeCard => 'CARD',
          PluginPlacementLocation.homeComposer => 'BAR',
        }}',
  if (owner.plugin.manifest.actions case [final action])
    '${action.title.toUpperCase()} ACTION'
  else if (owner.plugin.manifest.actions.isNotEmpty)
    '${owner.plugin.manifest.actions.length} ACTIONS',
].join(' · ');
