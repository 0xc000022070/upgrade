/// A host key the user accepted, kept as its fingerprint alone. Comparing keys and showing
/// one to the user both need only the fingerprint, and the host sends the full key on every
/// handshake anyway.
class PinnedHostKey {
  const PinnedHostKey({
    required this.type,
    required this.fingerprint,
    required this.pinnedAt,
  });

  final String type;

  /// `SHA256:<base64>`, the form OpenSSH prints and the form dartssh2 hands the verify
  /// callback.
  final String fingerprint;

  final DateTime pinnedAt;

  bool matches(String type, String fingerprint) =>
      this.type == type && this.fingerprint == fingerprint;
}
