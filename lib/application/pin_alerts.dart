import 'dart:convert';

import '../platform/shell/remote_shell.dart';

const pinNotificationTitle = 'AUTHORIZATION REQUIRED';

const pinWatchInterval = Duration(seconds: 15);

const pinWatchStep = Duration(seconds: 2);

const _payloadPrefix = 'pin:';

/// The alert ids sit at 1000 plus thirty bits; this region starts above them and folds
/// to twenty-nine, keeping both inside Android's signed 32-bit id.
int pinNotificationId(String hostId) {
  var hash = 0;
  for (final unit in hostId.codeUnits) {
    hash = (hash * 31 + unit) & 0x1fffffff;
  }
  return 0x40001000 + hash;
}

String pinPayload(String hostId) => '$_payloadPrefix$hostId';

String? pinPayloadHost(String? payload) {
  if (payload == null || !payload.startsWith(_payloadPrefix)) return null;
  final host = payload.substring(_payloadPrefix.length);
  return host.isEmpty ? null : host;
}

String pinNotificationText({
  required String host,
  required String desc,
  required String prompt,
}) {
  final name = host.trim().toUpperCase();
  final said = desc.trim().isNotEmpty ? desc.trim() : prompt.trim();
  return said.isEmpty ? name : '$name · $said';
}

abstract interface class PinNotifier {
  Future<void> raise({required String hostId, required String text});
  Future<void> withdraw(String hostId);
}

/// The tabs keep one of these and the watcher another, in isolates sharing no object
/// graph: each takes down only what it put up, and neither rescinds the other's.
class PinShade {
  PinShade(this.notifier);

  final PinNotifier? notifier;

  final _rang = <String, String>{};

  Future<void> tell({
    required String hostId,
    required String hostName,
    required PinRequest? held,
  }) async {
    final notifier = this.notifier;
    if (notifier == null) return;
    if (held == null) {
      if (_rang.remove(hostId) == null) return;
      await notifier.withdraw(hostId);
      return;
    }
    if (_rang[hostId] == held.id) return;
    _rang[hostId] = held.id;
    await notifier.raise(
      hostId: hostId,
      text: pinNotificationText(
        host: hostName,
        desc: held.desc,
        prompt: held.prompt,
      ),
    );
  }
}

class PinRequest {
  const PinRequest({
    required this.id,
    required this.mode,
    required this.since,
    this.desc = '',
    this.prompt = '',
    this.error = '',
    this.ok = '',
    this.cancel = '',
    this.stale = false,
  });

  static PinRequest? decode(String id, String payload, {DateTime? at}) {
    if (!pinentryRequestId.hasMatch(id)) return null;
    try {
      final json = jsonDecode(utf8.decode(base64Decode(payload)));
      if (json is! Map<String, Object?>) return null;
      String field(String key) {
        final value = json[key];
        return value is String ? value : '';
      }

      final mode = field('mode');
      return PinRequest(
        id: id,
        mode: mode.isEmpty ? 'pin' : mode,
        since: at ?? DateTime.now(),
        desc: field('desc'),
        prompt: field('prompt'),
        error: field('error'),
        ok: field('ok'),
        cancel: field('cancel'),
      );
    } on FormatException {
      return null;
    }
  }

  static List<PinRequest> decodeOpen(String listing, {DateTime? at}) {
    final requests = <PinRequest>[];
    for (final line in listing.split('\n')) {
      final space = line.indexOf(' ');
      if (space <= 0) continue;
      final request = decode(
        line.substring(0, space),
        line.substring(space + 1).trim(),
        at: at,
      );
      if (request != null) requests.add(request);
    }
    return requests;
  }

  final String id;
  final String mode;
  final String desc;
  final String prompt;
  final String error;
  final String ok;
  final String cancel;

  final DateTime since;

  final bool stale;

  PinRequest aged() => PinRequest(
    id: id,
    mode: mode,
    since: since,
    desc: desc,
    prompt: prompt,
    error: error,
    ok: ok,
    cancel: cancel,
    stale: true,
  );

  String get promptLabel => _label(prompt, 'PASSPHRASE');

  String get okLabel => _label(ok, mode == 'pin' ? 'UNLOCK' : 'OK');

  String get cancelLabel => _label(cancel, 'CANCEL');

  static String _label(String text, String fallback) {
    final cleaned = text
        .replaceAll('_', '')
        .trim()
        .replaceAll(RegExp(r':$'), '')
        .toUpperCase();
    return cleaned.isEmpty ? fallback : cleaned;
  }
}
