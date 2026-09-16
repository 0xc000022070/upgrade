/// The passphrase notification: what is decided about it, away from the
/// plugin, so the regression list can be run on the vm.
///
/// The shape is GitHub's line for a sign-in it wants approved: one heading,
/// `AUTHORIZATION REQUIRED`, and under it who is asking and for what.
library;

const pinNotificationTitle = 'AUTHORIZATION REQUIRED';

const _payloadPrefix = 'pin:';

/// One notification per host, so a second tab hearing the same request updates
/// in place. The alert ids sit at 1000 plus thirty bits; this region starts
/// above them and folds to twenty-nine, which keeps the two apart and both
/// inside the signed 32-bit id Android takes.
int pinNotificationId(String hostId) {
  var hash = 0;
  for (final unit in hostId.codeUnits) {
    hash = (hash * 31 + unit) & 0x1fffffff;
  }
  return 0x40001000 + hash;
}

/// The payload names the host and nothing else: a tap opens that host's shell,
/// where the sheet is, and the sheet has the request.
String pinPayload(String hostId) => '$_payloadPrefix$hostId';

String? pinPayloadHost(String? payload) {
  if (payload == null || !payload.startsWith(_payloadPrefix)) return null;
  final host = payload.substring(_payloadPrefix.length);
  return host.isEmpty ? null : host;
}

/// The host in capitals, then what the agent said about the key — the prompt
/// when it described nothing, the host alone when it said nothing at all.
String pinNotificationText({
  required String host,
  required String desc,
  required String prompt,
}) {
  final name = host.trim().toUpperCase();
  final said = desc.trim().isNotEmpty ? desc.trim() : prompt.trim();
  return said.isEmpty ? name : '$name · $said';
}

/// The shade, as the shell store sees it. The store decides when a host has a
/// request up and when it is gone; what a notification looks like is the
/// platform's, behind this.
abstract interface class PinNotifier {
  Future<void> raise({required String hostId, required String text});
  Future<void> withdraw(String hostId);
}
