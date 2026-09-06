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
