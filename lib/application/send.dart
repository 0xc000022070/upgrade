import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/repositories/dispatch_repository.dart';
import '../data/repositories/path_repository.dart';
import '../platform/herdr_client.dart';
import '../platform/host_keys.dart';
import '../platform/keys.dart';
import 'agents.dart';
import 'providers.dart';

/// Nothing outside this typedef's implementation names a transport, the same
/// way the agents feed's fetch does not: today a send is an ssh command, and a
/// backend proxying herdr would replace [HerdrClient] without a screen or a
/// provider above changing.
typedef HerdrSend = Future<SpawnResult> Function({
  required String address,
  required int port,
  required String user,
  required String privateKey,
  required String kind,
  required String directory,
  required String prompt,
  String? model,
  HostKeyVerifier? verifier,
});

/// The evidence seam, the one the watcher already uses. With
/// `--dart-define=HOTLINE_FAKE_SPAWN=true` the send never dials and answers
/// with a pane id, which is what lets the sheet's three states be captured on
/// an emulator while the verb is not deployed on the host yet.
const _fakeSpawn = bool.fromEnvironment('HOTLINE_FAKE_SPAWN');

Future<SpawnResult> _fakeSend({
  required String address,
  required int port,
  required String user,
  required String privateKey,
  required String kind,
  required String directory,
  required String prompt,
  String? model,
  HostKeyVerifier? verifier,
}) async {
  // Long enough that SENDING is a state the eye reads rather than a flicker.
  await Future<void>.delayed(const Duration(milliseconds: 900));
  return const SpawnSent('wQ:pH');
}

final herdrSendProvider = Provider<HerdrSend>((ref) {
  if (_fakeSpawn) return _fakeSend;
  const client = HerdrClient();
  return client.send;
});

/// What the agent is handed on stdin: the drop's title as it was typed, then a
/// blank line and one link per line.
///
/// Not a template with headings. The title is the whole instruction the user
/// wrote, and anything wrapped around it would be words the agent reads as
/// coming from them.
String sendPrompt({required String title, required List<String> links}) {
  if (links.isEmpty) return title;
  return '$title\n\n${links.join('\n')}';
}

sealed class SendState {
  const SendState();
}

final class SendSending extends SendState {
  const SendSending();
}

final class SendSent extends SendState {
  const SendSent(this.paneId);

  final String paneId;
}

final class SendFailed extends SendState {
  const SendFailed(this.reason);

  /// One line, lowercase, the words the agents panel already uses for the
  /// connection failures so the same problem never reads two ways.
  final String reason;
}

String spawnRefusalReason(SpawnRefusal refusal) => switch (refusal) {
  SpawnRefusal.noDirectory => 'no such directory',
  SpawnRefusal.startFailed => 'agent start failed',
  SpawnRefusal.spawnFailed => 'spawn failed',
  SpawnRefusal.timedOut => 'spawn timed out',
};

/// One send, end to end: key, dial, prompt, and the row that says it happened.
///
/// A plain class and not a notifier because the sheet owns the state — it has
/// exactly one send in flight and forgets it when it closes — and because a
/// test can then drive a send with three fakes and no widget tree.
class Sender {
  const Sender({
    required this.send,
    required this.keys,
    required this.dispatches,
  });

  final HerdrSend send;
  final Ed25519Keys keys;
  final DispatchRepository dispatches;

  /// [kind] and [model] are the send's, not the path's: where the work goes is
  /// a property of the directory, what picks it up is a property of this send.
  /// [model] null is the agent's own default, which is always accepted.
  Future<SendState> call({
    required PathTarget target,
    required String itemId,
    required String title,
    required List<String> links,
    required String kind,
    String? model,
  }) async {
    final host = target.host;
    void log(Object error) => debugPrint('hotline.spawn ${host.name}: $error');

    final privateKey = await keys.privateKey(host.keyId);
    if (privateKey == null) {
      log('no private key stored for ${host.keyId}');
      return const SendFailed('key rejected');
    }
    final SpawnResult result;
    try {
      result = await send(
        address: host.address,
        port: host.port,
        user: host.user,
        privateKey: privateKey,
        kind: kind,
        model: model,
        directory: target.path.directory,
        prompt: sendPrompt(title: title, links: links),
        verifier: HostKeyVerifier.pinnedOnly(host.hostKey),
      );
    } on HerdrFailure catch (error) {
      log(error.detail ?? error);
      return SendFailed(switch (error) {
        HerdrKeyRejected() => 'key rejected',
        HerdrProtocolMismatch() => 'protocol ${error.protocol}',
        HerdrUnresolved() => '${host.name.toLowerCase()} unresolved',
        HerdrUnreachable() => '${host.name.toLowerCase()} unreachable',
        HerdrHostKeyUnverified() => hostKeyReason(HostKeyRefusal.unverified),
        HerdrHostKeyChanged() => hostKeyReason(HostKeyRefusal.changed),
      });
    }
    switch (result) {
      // The row is written here and only here: a send that did not come back
      // with a pane never happened, and `[ SENT ]` must not carry a line the
      // user cannot open.
      case SpawnSent(:final paneId):
        await dispatches.record(
          itemId: itemId,
          pathId: target.path.id,
          paneId: paneId,
          title: title,
          agent: kind,
          model: model,
        );
        return SendSent(paneId);
      case SpawnRefused(:final refusal, :final detail):
        log(detail ?? refusal);
        return SendFailed(spawnRefusalReason(refusal));
    }
  }
}

final senderProvider = Provider(
  (ref) => Sender(
    send: ref.watch(herdrSendProvider),
    keys: ref.watch(ed25519KeysProvider),
    dispatches: ref.watch(dispatchRepositoryProvider),
  ),
);
