import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import 'package:upgrade/application/agents/agent_kind.dart';
import 'package:upgrade/application/agents/send.dart';
import 'package:upgrade/application/alerts/toasts.dart';
import 'package:upgrade/data/repositories/path_repository.dart';

class PendingSend {
  const PendingSend({
    required this.id,
    required this.itemId,
    required this.title,
    required this.target,
    required this.kind,
    required this.run,
    this.state = const SendSending(),
  });

  final String id;
  final String itemId;
  final String title;
  final PathTarget target;
  final AgentKind kind;
  final Future<SendState> Function() run;

  final SendState state;

  PendingSend _to(SendState state) => PendingSend(
    id: id,
    itemId: itemId,
    title: title,
    target: target,
    kind: kind,
    run: run,
    state: state,
  );
}

class SendQueue extends Notifier<List<PendingSend>> {
  static const _uuid = Uuid();

  @override
  List<PendingSend> build() => const [];

  void start({
    required String itemId,
    required String title,
    required PathTarget target,
    required AgentKind kind,
    required Future<SendState> Function() run,
  }) {
    final send = PendingSend(
      id: _uuid.v7(),
      itemId: itemId,
      title: title,
      target: target,
      kind: kind,
      run: run,
    );
    state = [...state, send];
    _run(send);
  }

  void retry(String id) {
    final send = _find(id);
    if (send == null || send.state is SendSending) return;
    _put(send._to(const SendSending()));
    _run(send);
  }

  void dismiss(String id) {
    final send = _find(id);
    if (send == null || send.state is SendSending) return;
    ref.read(toastQueueProvider.notifier).dismiss(_toastId(id));
    state = [...state.where((other) => other.id != id)];
  }

  Future<void> _run(PendingSend send) async {
    ref
        .read(toastQueueProvider.notifier)
        .raise(
          Toast(
            id: _toastId(send.id),
            verb: 'SENDING',
            subject: '${send.kind.name.toUpperCase()} · ${send.title}',
            busy: true,
          ),
        );
    SendState result;
    try {
      result = await send.run();
    } catch (error) {
      debugPrint('upgrade.spawn ${send.target.host.name}: $error');
      result = const SendFailed('send failed');
    }
    final toasts = ref.read(toastQueueProvider.notifier);
    if (_find(send.id) == null) {
      toasts.dismiss(_toastId(send.id));
      return;
    }
    switch (result) {
      case SendSent():
        state = [...state.where((other) => other.id != send.id)];
        toasts.raise(
          Toast(id: _toastId(send.id), verb: 'SENT', subject: send.title),
        );
      case SendFailed(:final reason):
        _put(send._to(result));
        toasts.raise(
          Toast(
            id: _toastId(send.id),
            verb: 'FAILED',
            subject: '$reason · ${send.title}',
            actionLabel: 'RETRY',
            onAction: (ref) async =>
                ref.read(sendQueueProvider.notifier).retry(send.id),
          ),
        );
      case SendSending():
        break;
    }
  }

  void _put(PendingSend send) {
    state = [for (final other in state) other.id == send.id ? send : other];
  }

  PendingSend? _find(String id) {
    for (final send in state) {
      if (send.id == id) return send;
    }
    return null;
  }

  static String _toastId(String id) => 'send:$id';
}

final sendQueueProvider = NotifierProvider<SendQueue, List<PendingSend>>(
  SendQueue.new,
);
