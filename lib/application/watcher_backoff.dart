const watcherMinBackoff = Duration(seconds: 5);
const watcherMaxBackoff = Duration(seconds: 60);

class WatcherBackoff {
  Duration _current = watcherMinBackoff;

  Duration get current => _current;

  void advance() {
    final doubled = _current * 2;
    _current = doubled > watcherMaxBackoff ? watcherMaxBackoff : doubled;
  }

  void reset() => _current = watcherMinBackoff;
}
