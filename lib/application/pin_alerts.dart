const pinNotificationTitle = 'AUTHORIZATION REQUIRED';

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
