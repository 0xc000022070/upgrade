import 'dart:async';

class UdpSilent implements Exception {
  const UdpSilent({
    required this.address,
    required this.port,
    required this.window,
  });

  final String address;
  final int port;
  final Duration window;

  @override
  String toString() => 'udp silent to $address:$port after ${spell(window)}';

  static String spell(Duration duration) {
    if (duration.inMilliseconds % 60000 == 0) return '${duration.inMinutes}m';
    if (duration.inMilliseconds % 1000 == 0) return '${duration.inSeconds}s';
    return '${duration.inMilliseconds}ms';
  }
}

class UdpContact {
  UdpContact() {
    _done.future.ignore();
  }

  final _done = Completer<void>();
  Timer? _timer;

  Future<void> get future => _done.future;

  void arm(
    Duration window, {
    required String address,
    required int port,
    int tries = 1,
    void Function()? again,
  }) {
    if (_done.isCompleted || _timer != null) return;
    _timer = Timer(window, () {
      _timer = null;
      if (_done.isCompleted) return;
      if (tries > 1 && again != null) {
        again();
        arm(
          window,
          address: address,
          port: port,
          tries: tries - 1,
          again: again,
        );
        return;
      }
      _done.completeError(
        UdpSilent(address: address, port: port, window: window),
      );
    });
  }

  void hear() {
    _timer?.cancel();
    _timer = null;
    if (!_done.isCompleted) _done.complete();
  }

  void cancel() => _timer?.cancel();
}

class UdpVerdicts {
  UdpVerdicts({this.ttl = const Duration(minutes: 5), this.now = DateTime.now});

  final Duration ttl;
  final DateTime Function() now;
  final _until = <String, DateTime>{};

  bool silent(String address) {
    final until = _until[address];
    if (until == null) return false;
    if (now().isBefore(until)) return true;
    _until.remove(address);
    return false;
  }

  void record(String address) => _until[address] = now().add(ttl);

  void clear(String address) => _until.remove(address);

  void clearAll() => _until.clear();
}
