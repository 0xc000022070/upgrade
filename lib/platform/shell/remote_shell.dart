import 'dart:typed_data';

String shellQuote(String value) => "'${value.replaceAll("'", "'\\''")}'";

String underSh(String script) => 'sh -c ${shellQuote(script)}';

/// `cd` to [directory], with a leading `~` left outside the quotes.
///
/// A registered directory is stored as the user typed it, `~` and all, because
/// expanding it on the phone would put this machine's home directory in a
/// command the host runs. So the expansion belongs to the host — and quoting
/// the path, which is what makes a space or a `$` in it safe, is the one thing
/// that stops the shell from doing it. The tilde and its slash are the only
/// characters held out of the quotes; everything after them is still quoted,
/// and a path that does not start with one is quoted whole.
String shellCd(String directory) {
  if (directory == '~') return 'cd ~';
  if (directory.startsWith('~/')) {
    return 'cd ~/${shellQuote(directory.substring(2))}';
  }
  return 'cd ${shellQuote(directory)}';
}

/// Where a file the app pushes lands on a host. World-writable and cleared by
/// the host's own reboot, which is the right lifetime for a file nothing ever
/// comes back for. Shared by the shell's paste and by a send's images, so the
/// directory and the command that fills it are written once.
const remoteUploadDirectory = '/tmp/spectacle';

String remotePathFor(String fileName) => '$remoteUploadDirectory/$fileName';

/// The command a file's bytes are written into: the directory made if it is
/// not, the file taken whole from stdin.
String uploadCommand(String fileName) => underSh(
  'mkdir -p ${shellQuote(remoteUploadDirectory)} && '
  'cat > ${shellQuote(remotePathFor(fileName))}',
);

/// A file on its way to a host: the name it lands under and the bytes that go
/// on the exec channel's stdin.
class RemoteFile {
  const RemoteFile(this.name, this.bytes);

  /// The base name of a local path, held to the characters a name may carry.
  /// The path is the app's own and its names are uuids, but a name is about to
  /// be interpolated into a remote path, and one that could climb out of
  /// [remoteUploadDirectory] must not be able to.
  factory RemoteFile.fromPath(String path, Uint8List bytes) {
    final base = path.split('/').last;
    final safe = base.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return RemoteFile(
      safe.isEmpty || safe.startsWith('.') ? 'file$safe' : safe,
      bytes,
    );
  }

  final String name;
  final Uint8List bytes;

  String get remotePath => remotePathFor(name);
}
