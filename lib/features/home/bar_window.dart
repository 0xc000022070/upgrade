import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/application/home/compose_window.dart';
import 'package:upgrade/application/home/composer_focus.dart';
import 'package:upgrade/application/home/input_bar_holder.dart';
import 'package:upgrade/application/plugins/native_plugins.dart';
import 'package:upgrade/platform/launcher_widget/launcher_widget.dart';

class BarWindow extends ConsumerStatefulWidget {
  const BarWindow({super.key});

  @override
  ConsumerState<BarWindow> createState() => _BarWindowState();
}

class _BarWindowState extends ConsumerState<BarWindow> {
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (ref.read(inputBarHolderProvider).value == null) {
        return _leave(LauncherWidget.openApp(LauncherOpen.plugins));
      }
      unawaited(LauncherWidget.composeShown());
      ref.read(composerFocusRequestProvider.notifier).request();
    });
  }

  void _close() => _leave(LauncherWidget.closeCompose());

  void _focusMoved(bool inside) {
    if (inside) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !(ModalRoute.of(context)?.isCurrent ?? false)) {
        return;
      }
      if (FocusManager.instance.primaryFocus?.context case final focused?
          when focused.findAncestorStateOfType<_BarWindowState>() == this) {
        return;
      }
      _close();
    });
  }

  void _leave(Future<void> door) {
    if (_closed) return;
    _closed = true;
    FocusManager.instance.primaryFocus?.unfocus();
    unawaited(door);
    final route = ModalRoute.of(context);
    if (route != null && route.isActive) {
      Navigator.of(context).removeRoute(route);
    }
    ref.read(composeWindowProvider.notifier).state = false;
  }

  @override
  Widget build(BuildContext context) {
    final holder = ref.watch(inputBarHolderProvider).value;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        resizeToAvoidBottomInset: true,
        body: Column(
          children: [
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _close,
              ),
            ),
            if (holder != null)
              Focus(
                canRequestFocus: false,
                skipTraversal: true,
                onFocusChange: _focusMoved,
                child: NativeContributionSurface.widget(holder),
              ),
          ],
        ),
      ),
    );
  }
}
