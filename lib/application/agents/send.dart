import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:striked/data/repositories/dispatch_repository.dart';
import 'package:striked/data/repositories/path_repository.dart';
import 'package:striked/platform/herdr/herdr_client.dart';
import 'package:striked/platform/shell/remote_shell.dart';
import 'package:striked/platform/ssh/host_keys.dart';
import 'package:striked/platform/ssh/host_links.dart';
import 'package:striked/platform/ssh/keys.dart';
import 'package:striked/application/agents/agent_kind.dart';
import 'package:striked/application/agents/agents.dart';
import 'package:striked/application/providers.dart';

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
  void Function(PaneRef pane)? onPane,
  required HostKeyVerifier verifier,
});

typedef ReadImage = Future<Uint8List> Function(String path);

Future<Uint8List> _readFile(String path) => File(path).readAsBytes();

/// With `--dart-define=STRIKED_FAKE_SPAWN=true` the send never dials and answers with a
/// pane id.
const _fakeSpawn = bool.fromEnvironment('STRIKED_FAKE_SPAWN');

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
  void Function(PaneRef pane)? onPane,
  required HostKeyVerifier verifier,
}) async {
  // Long enough that SENDING is a state the eye reads rather than a flicker.
  await Future<void>.delayed(const Duration(milliseconds: 900));
  return const SpawnSent('wQ:pH', 'main');
}

final herdrSendProvider = Provider<HerdrSend>((ref) {
  if (_fakeSpawn) return _fakeSend;
  return HerdrClient(
    links: ref.read(hostLinksProvider),
    use: HostUse.send,
  ).send;
});

/// A prompt leads and the title follows it; nothing is wrapped around either, or the agent reads
/// those words as the user's. An image is its path on the host, which is how both
/// agents document being handed a picture.
String sendPrompt({
  required String title,
  required List<String> links,
  String? prompt,
  List<RemoteFile> images = const [],
}) {
  final head = prompt == null ? title : '$prompt\n\nITEM\n$title';
  final lines = [...links, for (final image in images) image.remotePath];
  if (lines.isEmpty) return head;
  return '$head\n\n${lines.join('\n')}';
}

class SendChoice {
  const SendChoice({required this.target, required this.kind, this.model});

  final PathTarget target;
  final AgentKind kind;

  final String? model;
}

sealed class SendState {
  const SendState();
}

final class SendSending extends SendState {
  const SendSending();
}

final class SendSent extends SendState {
  const SendSent(this.paneId, [this.session]);

  final String paneId;
  final String? session;
}

final class SendFailed extends SendState {
  const SendFailed(this.reason);

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

class Sender {
  const Sender({
    required this.send,
    required this.keys,
    required this.dispatches,
    this.readImage = _readFile,
    this.checkActive,
  });

  final HerdrSend send;
  final Ed25519Keys keys;
  final DispatchRepository dispatches;
  final ReadImage readImage;
  final void Function()? checkActive;

  Future<SendState> call({
    required String sendId,
    required PathTarget target,
    String? itemId,
    required String title,
    required List<String> links,
    required AgentKind kind,
    String? prompt,
    String? message,
    List<String> imagePaths = const [],
    String? model,
  }) async {
    checkActive?.call();
    final named = [
      for (final path in imagePaths) RemoteFile.fromPath(path, Uint8List(0)),
    ];
    final text = message == null
        ? sendPrompt(title: title, links: links, prompt: prompt, images: named)
        : [
            message,
            if (named.isNotEmpty)
              named.map((image) => image.remotePath).join('\n'),
          ].join('\n\n');
    await dispatches.start(
      id: sendId,
      itemId: itemId,
      pathId: target.path.id,
      text: text,
      agent: kind.name,
      model: model,
    );
    final SendState state;
    try {
      state = await _attempt(
        sendId: sendId,
        target: target,
        kind: kind,
        text: text,
        imagePaths: imagePaths,
        model: model,
      );
    } catch (_) {
      // ignored: the original send error is rethrown below, it matters more
      await dispatches.failed(sendId, 'send failed').catchError((_) {});
      rethrow;
    }
    switch (state) {
      case SendSent():
        await dispatches.sent(sendId, title: title);
      case SendFailed(:final reason):
        await dispatches.failed(sendId, reason);
      case SendSending():
        break;
    }
    return state;
  }

  Future<SendState> _attempt({
    required String sendId,
    required PathTarget target,
    required AgentKind kind,
    required String text,
    required List<String> imagePaths,
    String? model,
  }) async {
    final host = target.host;
    void log(Object error) => debugPrint('striked.spawn ${host.name}: $error');

    final privateKey = await keys.privateKey(host.keyId);
    checkActive?.call();
    if (privateKey == null) {
      log('no private key stored for ${host.keyId}');
      return const SendFailed('key rejected');
    }
    // Read before the dial: an attachment whose file is gone must not go out as a prompt
    // naming a path the agent would never find.
    final images = <RemoteFile>[];
    for (final path in imagePaths) {
      try {
        images.add(RemoteFile.fromPath(path, await readImage(path)));
      } catch (error) {
        log(error);
        return const SendFailed('image unreadable');
      }
    }
    final panes = <Future<void>>[];
    final SpawnResult result;
    try {
      checkActive?.call();
      result = await send(
        address: host.address,
        port: host.port,
        user: host.user,
        privateKey: privateKey,
        kind: kind,
        model: model,
        directory: target.path.directory,
        images: images,
        prompt: text,
        onPane: (pane) => panes.add(
          dispatches
              .pane(sendId, session: pane.session, paneId: pane.pane)
              .catchError((Object error) => log(error)),
        ),
        verifier: HostKeyVerifier.pinnedOnly(host.hostKey),
      );
    } on HerdrFailure catch (error) {
      log(error.detail ?? error);
      return SendFailed(error.reason(host.name));
    } finally {
      await Future.wait(panes);
    }
    checkActive?.call();
    switch (result) {
      case SpawnSent(:final paneId, :final session):
        if (panes.isEmpty) {
          await dispatches.pane(sendId, session: session, paneId: paneId);
        }
        return SendSent(paneId, session);
      case SpawnRefused(:final refusal, :final detail):
        log(detail ?? refusal);
        return SendFailed(spawnRefusalReason(refusal));
    }
  }
}

bool sentImage(String text, String path) => text
    .split('\n')
    .contains(RemoteFile.fromPath(path, Uint8List(0)).remotePath);

String sentMessage(String text) {
  final cut = text.lastIndexOf('\n\n');
  if (cut < 0) return text;
  final lines = text.substring(cut + 2).split('\n');
  final named = lines.every(
    (line) => line.startsWith('$remoteUploadDirectory/'),
  );
  return named ? text.substring(0, cut) : text;
}

final senderProvider = Provider(
  (ref) => Sender(
    send: ref.watch(herdrSendProvider),
    keys: ref.watch(ed25519KeysProvider),
    dispatches: ref.watch(dispatchRepositoryProvider),
    checkActive: ref
        .watch(pluginDataGateProvider)
        ?.lease('host.dispatch')
        .check,
  ),
  dependencies: [dispatchRepositoryProvider, pluginDataGateProvider],
);
