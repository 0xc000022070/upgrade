/// What a long press takes out of a line of terminal text. Spectacle patch.
///
/// `Buffer.getWordBoundary` answers with a word, and a word is the wrong unit
/// for a terminal: its separator set breaks on `.`, `:`, `-` and `/`, which
/// are the characters a URL, a path and `file.dart:42` are made of, so a press
/// on any of them could only ever hand back one segment.
///
/// The unit here is the run of non-blank cells around the finger, less the
/// punctuation the run only happens to end in. Prose words are already
/// space-delimited, so this is a superset of what a word rule gets right, and
/// it takes `/home/luis/x.dart:42`, `git@github.com:o/r.git` and
/// `github.com/o/r` whole. A URL with a scheme inside the run wins over the
/// run itself, which is what pulls the link out of `url=https://x.dev/a`.
library;

/// A half-open span of a string: [start] inclusive, [end] exclusive.
class TokenSpan {
  const TokenSpan(this.start, this.end);

  final int start;
  final int end;

  @override
  bool operator ==(Object other) =>
      other is TokenSpan && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'TokenSpan($start, $end)';
}

/// Sentence punctuation: a run that ends in it ends in it by accident.
const _trailing = '.,;:!?';

/// Wrappers, paired by position. A quote is its own closer.
const _openers = '([{<\'"`';
const _closers = ')]}>\'"`';

/// A scheme and its authority. The tail is deliberately greedy — a URL may
/// hold anything but a space, and the punctuation it should not have swallowed
/// is taken off by [_trim], which knows that `(bar)` closes and `foo).` does
/// not.
final _url = RegExp(r'[A-Za-z][A-Za-z0-9+.\-]*://\S+');

bool _isBlank(int code) => code == 0x20 || code == 0x09 || code == 0;

/// The token under [index], or null when the character there is blank — a
/// press on a gap is the caller's to answer, since a gap in the middle of a
/// line still deserves a selection.
TokenSpan? tokenAt(String text, int index) {
  if (index < 0 || index >= text.length) return null;
  if (_isBlank(text.codeUnitAt(index))) return null;

  var start = index;
  while (start > 0 && !_isBlank(text.codeUnitAt(start - 1))) {
    start--;
  }
  var end = index + 1;
  while (end < text.length && !_isBlank(text.codeUnitAt(end))) {
    end++;
  }

  for (final match in _url.allMatches(text.substring(start, end))) {
    final from = start + match.start;
    final to = start + match.end;
    if (index >= from && index < to) return _trim(text, from, to, index);
  }

  return _trim(text, start, end, index);
}

/// Peels punctuation off both ends while the finger stays inside what is left:
/// sentence marks at the tail, a wrapper around the whole of it, and a bracket
/// whose other half is not in the run.
TokenSpan _trim(String text, int start, int end, int index) {
  var from = start;
  var to = end;

  var peeled = true;
  while (peeled && to - from > 1) {
    peeled = false;

    while (to - 1 > index && _trailing.contains(text[to - 1])) {
      to--;
      peeled = true;
    }

    if (to - from > 2 && index > from && index < to - 1) {
      final open = _openers.indexOf(text[from]);
      if (open >= 0 && text[to - 1] == _closers[open]) {
        from++;
        to--;
        peeled = true;
        continue;
      }
    }

    if (to - 1 > index) {
      final close = _closers.indexOf(text[to - 1]);
      if (close >= 0 && !text.substring(from, to - 1).contains(_openers[close])) {
        to--;
        peeled = true;
      }
    }

    if (from < index) {
      final open = _openers.indexOf(text[from]);
      if (open >= 0 && !text.substring(from + 1, to).contains(_closers[open])) {
        from++;
        peeled = true;
      }
    }
  }

  return TokenSpan(from, to);
}
