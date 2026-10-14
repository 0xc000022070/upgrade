import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/application/files/phone_inbox.dart';
import 'package:upgrade/features/files/send_sheet.dart';
import 'package:upgrade/features/files/transfer_bar.dart';

class SharedInboxHost extends ConsumerStatefulWidget {
  const SharedInboxHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<SharedInboxHost> createState() => _SharedInboxHostState();
}

class _SharedInboxHostState extends ConsumerState<SharedInboxHost> {
  StreamSubscription<void>? _nudges;
  StreamSubscription<void>? _opens;
  bool _transfers = false;
  final _waiting = <SharedItem>[];
  var _unreadable = 0;
  bool _showing = false;

  @override
  void initState() {
    super.initState();
    final phone = ref.read(phoneFilesProvider);
    _nudges = phone.nudges.listen((_) => unawaited(_take()));
    _opens = phone.opens.listen((_) => unawaited(_openTransfers()));
    unawaited(_take());
  }

  @override
  void dispose() {
    unawaited(_nudges?.cancel());
    unawaited(_opens?.cancel());
    super.dispose();
  }

  Future<void> _take() async {
    final shared = await ref.read(phoneFilesProvider).takeShared();
    _waiting.addAll(shared.items);
    _unreadable += shared.unreadable;
    bool waiting() => _waiting.isNotEmpty || _unreadable > 0;
    if (!mounted || _showing || !waiting()) return;
    _showing = true;
    while (waiting() && mounted) {
      final items = [..._waiting];
      final unreadable = _unreadable;
      _waiting.clear();
      _unreadable = 0;
      await showSendSheet(context, items, unreadable: unreadable);
    }
    _showing = false;
  }

  Future<void> _openTransfers() async {
    if (!mounted || _transfers) return;
    _transfers = true;
    await showTransfers(context);
    _transfers = false;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
