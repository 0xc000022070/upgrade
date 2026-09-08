/// Every sentence the app words a failed connection as, written once.
///
/// The same handful of facts — the machine did not answer, the key was
/// refused, the pinned host key is not the one that came back — are found by
/// four different layers, each with its own failure type: the herdr client's
/// failures, the shell's failure kinds, the screen route's failures and the
/// agent poll's outcome kinds. Each one used to
/// spell out the words itself, which meant seven copies of `key rejected` and
/// two hand-synchronised copies of the shell's — the header's uppercase word
/// beside the row's sentence, kept in step by nobody.
///
/// Nothing here knows about any of those types: they map into this, one
/// mapping per type, and none of them writes a sentence.
enum ReasonLine {
  unresolved('unresolved', names: true),
  unreachable('unreachable', names: true),
  keyRejected('key rejected'),
  shellRefused('shell refused'),
  streamClosed('stream closed'),
  hostKeyUnverified('host key unverified'),
  hostKeyChanged('host key changed'),

  /// The constant half of the one line that carries a value; the version the
  /// host answered with is added by [protocolLine].
  protocolMismatch('protocol mismatch'),

  /// The screen route's own four, beside the ssh ones it shares.
  tunnelRefused('tunnel refused'),
  authUnsupported('auth unsupported'),
  passwordNeeded('password needed'),
  passwordRejected('password rejected'),

  /// The bundle's five, read uppercased on the `BUNDLE` panel.
  notABundle('not a bundle'),
  newerBundle('newer bundle'),
  wrongPassphrase('wrong passphrase'),
  bundleIncomplete('bundle incomplete'),
  noPicker('no picker');

  const ReasonLine(this.words, {this.names = false});

  /// The sentence with no host in it, which for all but two is the whole of it.
  final String words;

  /// Whether the sentence names the host it happened to. Only the two failures
  /// that are about reaching a machine do: the rest are about this connection
  /// and read the same wherever they happen.
  final bool names;

  /// The line, given the host it happened to. A host handed to a line that
  /// does not name one is dropped rather than prefixed — the caller does not
  /// have to know which kind it is holding.
  String on(String host) => names ? '${host.toLowerCase()} $words' : words;

  /// The same fact as one uppercased phrase, for a header with no room for a
  /// host's name. Derived rather than written, so the two cannot drift.
  String get short => words.toUpperCase();
}

/// The one failure line that carries a value: which protocol version the host
/// answered with. Not a [ReasonLine] because it is not a constant sentence,
/// and here rather than in the two layers that report it so the wording is
/// still owned by one file.
String protocolLine(Object? protocol) => 'protocol ${protocol ?? '?'}';
