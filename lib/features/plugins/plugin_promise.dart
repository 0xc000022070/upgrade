import 'package:striked/application/plugins/native_plugins.dart';
import 'package:striked/platform/plugins/contributions.dart';

String pluginPromise(PluginContributionOwner owner) => [
  for (final page in owner.pages)
    '${page.contribution.title.toUpperCase()} '
        '${page.contribution.defaultPinned ? 'TAB' : 'PAGE'}',
  for (final widget in owner.widgets)
    if (widget.contribution.locations.contains(
      PluginPlacementLocation.homeCard,
    ))
      '${widget.contribution.title.toUpperCase()} CARD'
    else if (widget.contribution.locations.contains(
      PluginPlacementLocation.homeComposer,
    ))
      '${widget.contribution.title.toUpperCase()} BAR',
  if (owner.plugin.manifest.actions case [final action])
    '${action.title.toUpperCase()} ACTION'
  else if (owner.plugin.manifest.actions.isNotEmpty)
    '${owner.plugin.manifest.actions.length} ACTIONS',
].join(' · ');
