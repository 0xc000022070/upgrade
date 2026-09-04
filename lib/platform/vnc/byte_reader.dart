import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'vnc_failure.dart';

/// Exactly-n reads over a byte stream that arrives in whatever sizes the
/// tunnel hands over.
///
/// RFB is a framed protocol read with a ruler — two bytes here, then a length,
/// then that many — and an ssh channel delivers packets, not frames. Every
/// parser in this directory reads through this, so none of them has to hold a
/// partial-message state machine.
class ByteReader {
  ByteReader(Stream<List<int>> source) {
    _subscription = source.listen(
      _onData,
      onError: _onError,
      onDone: _onDone,
      cancelOnError: true,
    );
  }

  late final StreamSubscription<List<int>> _subscription;
  final Queue<Uint8List> _chunks = Queue();
  int _available = 0;

  /// How far into [_chunks].first the reads have already got. Kept as an offset
  /// rather than by re-slicing the head, so a 4 KB packet read two bytes at a
  /// time costs no copies.
  int _offset = 0;
  Completer<void>? _pending;
  bool _done = false;
  Object? _error;

  int get available => _available;

  void _onData(List<int> data) {
    if (data.isEmpty) return;
    _chunks.add(data is Uint8List ? data : Uint8List.fromList(data));
    _available += data.length;
    _wake();
  }

  void _onError(Object error) {
    _error = asVncFailure(error) ?? error;
    _done = true;
    _wake();
  }

  void _onDone() {
    _done = true;
    _wake();
  }

  void _wake() {
    final pending = _pending;
    _pending = null;
    pending?.complete();
  }

  /// Blocks until [count] bytes have arrived, then returns them.
  ///
  /// A stream that ends first is the `stream closed` reason: a handshake cut in
  /// half and a tunnel dropped mid-frame are the same event from here, and both
  /// are reported rather than left as a future that never completes.
  Future<Uint8List> read(int count) async {
    while (_available < count) {
      if (_error != null) throw _error!;
      if (_done) {
        throw VncStreamClosed('wanted $count bytes, stream had $_available');
      }
      await (_pending ??= Completer<void>()).future;
    }
    return _take(count);
  }

  Uint8List _take(int count) {
    if (count == 0) return Uint8List(0);
    final head = _chunks.first;
    // The common case by far: the next message is already inside one packet.
    if (head.length - _offset >= count) {
      final view = Uint8List.sublistView(head, _offset, _offset + count);
      _offset += count;
      if (_offset == head.length) {
        _chunks.removeFirst();
        _offset = 0;
      }
      _available -= count;
      // A view, not a copy — every caller either parses it at once or blits it
      // into the framebuffer, and a full-screen Raw rect is 8 MB of it.
      return view;
    }
    final out = Uint8List(count);
    var written = 0;
    while (written < count) {
      final chunk = _chunks.first;
      final take = (chunk.length - _offset).clamp(0, count - written);
      out.setRange(written, written + take, chunk, _offset);
      written += take;
      _offset += take;
      if (_offset == chunk.length) {
        _chunks.removeFirst();
        _offset = 0;
      }
    }
    _available -= count;
    return out;
  }

  Future<int> readU8() async => (await read(1))[0];

  Future<int> readU16() async {
    final bytes = await read(2);
    return bytes[0] << 8 | bytes[1];
  }

  Future<int> readU32() async {
    final bytes = await read(4);
    return bytes[0] << 24 | bytes[1] << 16 | bytes[2] << 8 | bytes[3];
  }

  /// RFB's `S32`, which only the encoding numbers use — and only they need the
  /// sign, `DesktopSize` being -223.
  Future<int> readS32() async {
    final bytes = await read(4);
    return ByteData.sublistView(bytes).getInt32(0);
  }

  /// Reads and drops [count] bytes. The colour-map and cut-text messages are
  /// read to stay in frame and then thrown away.
  Future<void> skip(int count) => read(count);

  Future<void> close() async {
    await _subscription.cancel();
    _chunks.clear();
    _available = 0;
    _offset = 0;
  }
}
