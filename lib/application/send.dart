import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/repositories/dispatch_repository.dart';
import '../data/repositories/path_repository.dart';
import '../platform/herdr_client.dart';
import '../platform/shell/remote_shell.dart';
import '../platform/host_keys.dart';
import '../platform/keys.dart';
import 'agent_kind.dart';
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
  required AgentKind kind,
  required String directory,
  required String prompt,
  List<RemoteFile> images,
  String? model,
  HostKeyVerifier? verifier,
});

/// How a local file becomes bytes. A seam for the same reason [HerdrSend] is
/// one: a test drives a send with images and no filesystem under it.
typedef ReadImage = Future<Uint8List> Function(String path);

Future<Uint8List> _readFile(String path) => File(path).readAsBytes();

/// The evidence seam, the one the watcher already uses. With
/// `--dart-define=DAZZLE_FAKE_SPAWN=true` the send never dials and answers
/// with a pane id, which is what lets the sheet's three states be captured on
/// an emulator while the verb is not deployed on the host yet.
const _fakeSpawn = bool.fromEnvironment('DAZZLE_FAKE_SPAWN');

Future<SpawnResult> _fakeSend({
  required String address,
  required int port,
  required String user,
  required String privateKey,
  required AgentKind kind,
  required String directory,
  required String prompt,
  List<RemoteFile> images = const [],
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
/// blank line, one link per line, and one image path per line under them.
///
/// Not a template with headings. The title is the whole instruction the user
/// wrote, and anything wrapped around it would be words the agent reads as
/// coming from them. An image is its path on the host and nothing else, which
/// is what both agents document as the way to hand them a picture; the bytes
/// are already there by the time this string is read.
String sendPrompt({
  required String title,
  required List<String> links,
  List<RemoteFile> images = const [],
}) {
  final lines = [...links, for (final image in images) image.remotePath];
  if (lines.isEmpty) return title;
  return '$title\n\n${lines.join('\n')}';
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
  SpawnRefusal.uploadFailed => 'image upload failed',
  SpawnRefusal.startFailed => 'agent start failed',
  SpawnRefusal.spawnFailed => 'spawn failed',
  SpawnRefusal.timedOut => 'spawn timed out',
  SpawnRefusal.noSession => 'no herdr session',
  SpawnRefusal.noDefaultSession => 'no default session',
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
    this.readImage = _readFile,
  });

  final HerdrSend send;
  final Ed25519Keys keys;
  final DispatchRepository dispatches;
  final ReadImage readImage;

  /// [kind] and [model] are the send's, not the path's: where the work goes is
  /// a property of the directory, what picks it up is a property of this send.
  /// [model] null is the agent's own default, which is always accepted.
  Future<SendState> call({
    required PathTarget target,
    required String itemId,
    required String title,
    required List<String> links,
    required AgentKind kind,
    List<String> imagePaths = const [],
    String? model,
  }) async {
    final host = target.host;
    void log(Object error) =>
        debugPrint('dazzle.spawn ${host.name}: $error');

    final privateKey = await keys.privateKey(host.keyId);
    if (privateKey == null) {
      log('no private key stored for ${host.keyId}');
      return const SendFailed('key rejected');
    }
    // Read before the dial. An attachment whose file is gone cannot be sent
    // without the prompt naming a path the agent would never find, so the send
    // fails here rather than going out with a line about a picture that is not
    // there.
    final images = <RemoteFile>[];
    for (final path in imagePaths) {
      try {
        images.add(RemoteFile.fromPath(path, await readImage(path)));
      } catch (error) {
        log(error);
        return const SendFailed('image unreadable');
      }
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
        images: images,
        prompt: sendPrompt(title: title, links: links, images: images),
        verifier: HostKeyVerifier.pinnedOnly(host.hostKey),
      );
    } on HerdrFailure catch (error) {
      log(error.detail ?? error);
      return SendFailed(error.reason(host.name));
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
          agent: kind.name,
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
