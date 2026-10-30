import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:upgrade_luau/upgrade_luau.dart';

import 'package:upgrade/application/plugins/native_plugins.dart';
import 'package:upgrade/application/plugins/plugins.dart';
import 'package:upgrade/design/components/dot_spinner.dart';
import 'package:upgrade/design/components/panel.dart';
import 'package:upgrade/design/components/panel_text_action.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/features/plugins/plugin_frames.dart';
import 'package:upgrade/features/plugins/plugin_page.dart';
import 'package:upgrade/platform/plugins/store.dart';
import 'package:upgrade/platform/plugins/ui.dart';
import 'package:upgrade/platform/ssh/connection_supervisor.dart';

typedef _Drawn = ({
  String stamp,
  Map<String, Object?> state,
  PluginUiNode view,
});

final _drawnCardsProvider = Provider<Map<String, _Drawn>>((ref) => {});

class PluginCard extends ConsumerWidget {
  const PluginCard({super.key, required this.registration});

  final PluginWidgetRegistration registration;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(effectivePluginsProvider);
    final owner = registration.owner;
    final stamp =
        '${owner.package.digest}:'
        '${ref.read(pluginsProvider.notifier).activation(owner.id)}';
    return _PluginCardBody(
      key: ValueKey('${registration.stableId}:$stamp'),
      registration: registration,
      stamp: stamp,
    );
  }
}

class _PluginCardBody extends ConsumerStatefulWidget {
  const _PluginCardBody({
    super.key,
    required this.registration,
    required this.stamp,
  });

  final PluginWidgetRegistration registration;
  final String stamp;

  @override
  ConsumerState<_PluginCardBody> createState() => _PluginCardState();
}

class _PluginCardState extends ConsumerState<_PluginCardBody>
    with PluginFrames<_PluginCardBody> {
  Timer? _timer;
  AppLifecycleListener? _lifecycle;
  bool _due = false;

  @override
  InstalledPlugin get plugin => widget.registration.owner;

  String get _widgetId => widget.registration.contribution.id;

  Duration? get _refresh => widget.registration.contribution.refresh;

  @override
  Future<LuauResult> invokeFrame(Map<String, Object?> input) =>
      ref.read(pluginsProvider.notifier).card(plugin.id, _widgetId, input);

  @override
  PluginUiNode parseView(Object? view) => PluginUiNode.parse(
    view,
    allowCanvas: canvasGranted,
    card: true,
    pages: pageIds,
  );

  @override
  void framed() {
    ref.read(_drawnCardsProvider)[widget.registration.stableId] = (
      stamp: widget.stamp,
      state: pluginState!,
      view: view!,
    );
    _due = false;
    if (_refresh case final every?) _arm(every);
  }

  @override
  void initState() {
    super.initState();
    if (ref.read(_drawnCardsProvider)[widget.registration.stableId]
        case final drawn? when drawn.stamp == widget.stamp) {
      pluginState = drawn.state;
      view = drawn.view;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_refresh case final every?) _arm(every);
      dispatch(_mountEvent());
    });
    if (_refresh != null) {
      _lifecycle = AppLifecycleListener(onResume: _refreshIfShown);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _refreshIfShown();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _lifecycle?.dispose();
    super.dispose();
  }

  void _arm(Duration after) {
    _timer?.cancel();
    _timer = Timer(after, () {
      _due = true;
      _refreshIfShown();
    });
  }

  @override
  Future<void> dispatch(
    Map<String, Object?> event, {
    bool quiet = false,
    UserIntent? intent,
  }) async {
    await super.dispatch(event, quiet: quiet, intent: intent);
    _refreshIfShown();
  }

  void _refreshIfShown() {
    if (!mounted ||
        !_due ||
        busy ||
        !onStage ||
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    _due = false;
    _arm(_refresh!);
    dispatch({'type': 'refresh', 'widget': _widgetId});
  }

  Map<String, Object?> _mountEvent() => {
    'type': 'mount',
    'widget': _widgetId,
    if (plugin.manifest.uiVersion == 2)
      'theme': pluginThemeTable(context.tokens),
  };

  @override
  Widget build(BuildContext context) {
    if (!pluginActive) return const SizedBox.shrink();
    final title = widget.registration.contribution.title.toUpperCase();
    final drawn = view;
    if (drawn == null) {
      return Panel(
        title: '[ $title ]',
        child: error == null
            ? const DelayedSpinner()
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    error!,
                    style: context.tokens.rowSubtitle.copyWith(
                      color: context.tokens.danger,
                    ),
                  ),
                  PanelTextAction(
                    label: 'RETRY',
                    onTap: () => dispatch(_mountEvent()),
                  ),
                ],
              ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PluginUi(
          node: drawn,
          values: fieldValues,
          onEvent: UserIntent.onGestureWith(
            (intent, event) => dispatch(event, intent: intent),
          ),
          busy: busy,
          onOpen: openPage,
        ),
        if (error != null)
          Text(
            error!,
            style: context.tokens.rowSubtitle.copyWith(
              color: context.tokens.danger,
            ),
          ),
      ],
    );
  }
}
