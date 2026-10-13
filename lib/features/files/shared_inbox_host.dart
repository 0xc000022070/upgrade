import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/application/files/phone_inbox.dart';
import 'package:upgrade/features/files/send_sheet.dart';

class SharedInboxHost extends ConsumerStatefulWidget {
  const SharedInboxHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<SharedInboxHost> createState() => _SharedInboxHostState();
}

class _SharedInboxHostState extends ConsumerState<SharedInboxHost> {
  StreamSubscription<void>? _nudges;
  final _waiting = <SharedItem>[];
  bool _showing = false;

  @override
  void initState() {
    super.initState();
    final phone = ref.read(phoneFilesProvider);
    _nudges = phone.nudges.listen((_) => unawaited(_take()));
    unawaited(_take());
  }

  @override
  void dispose() {
    unawaited(_nudges?.cancel());
    super.dispose();
  }

  Future<void> _take() async {
    _waiting.addAll(await ref.read(phoneFilesProvider).takeShared());
    if (!mounted || _showing || _waiting.isEmpty) return;
    _showing = true;
    while (_waiting.isNotEmpty && mounted) {
      final items = [..._waiting];
      _waiting.clear();
      await showSendSheet(context, items);
    }
    _showing = false;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
