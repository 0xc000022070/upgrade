import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dart_mosh/dart_mosh.dart';

import 'package:upgrade/platform/shell/udp_path.dart';

const engineWireVersion = 1;
const engineMaxPlaintext = 1200;
const engineClientHeader = 30;
const engineServerHeader = 26;
const engineMaxInput = engineMaxPlaintext - engineClientHeader - 8;
const engineMaxData = engineMaxPlaintext - engineServerHeader - 8;
const engineNoTimestamp = 0xffff;

const _clientInput = 1 << 0;
const _clientClose = 1 << 1;
const _serverData = 1 << 0;
const _serverJump = 1 << 1;

const _recordPty = 1;
const _recordSnapshot = 2;
const _recordExit = 3;
const _recordForeground = 4;
const _recordHeader = 5;

class EngineSize {
  const EngineSize(this.cols, this.rows, {this.widthPx = 0, this.heightPx = 0});

  final int cols;
  final int rows;
  final int widthPx;
  final int heightPx;

  @override
  bool operator ==(Object other) =>
      other is EngineSize &&
      other.cols == cols &&
      other.rows == rows &&
      other.widthPx == widthPx &&
      other.heightPx == heightPx;

  @override
  int get hashCode => Object.hash(cols, rows, widthPx, heightPx);
}

class EngineClientPacket {
  const EngineClientPacket({
    this.close = false,
    required this.timestamp,
    this.timestampReply = engineNoTimestamp,
    required this.ack,
    required this.keyframe,
    required this.sizeGen,
    required this.size,
    this.inputOffset,
    this.input,
  });

  final bool close;
  final int timestamp;
  final int timestampReply;
  final int ack;
  final int keyframe;
  final int sizeGen;
  final EngineSize size;
  final int? inputOffset;
  final Uint8List? input;

  Uint8List encode() {
    final input = this.input;
    final offset = inputOffset;
    final carries = input != null && offset != null;
    final out = ByteData(engineClientHeader + (carries ? 8 + input.length : 0));
    out
      ..setUint8(0, engineWireVersion)
      ..setUint8(1, (carries ? _clientInput : 0) | (close ? _clientClose : 0))
      ..setUint16(2, timestamp & 0xffff)
      ..setUint16(4, timestampReply & 0xffff)
      ..setUint64(6, ack)
      ..setUint32(14, keyframe)
      ..setUint32(18, sizeGen)
      ..setUint16(22, size.cols)
      ..setUint16(24, size.rows)
      ..setUint16(26, size.widthPx)
      ..setUint16(28, size.heightPx);
    final bytes = out.buffer.asUint8List();
    if (carries) {
      out.setUint64(engineClientHeader, offset);
      bytes.setAll(engineClientHeader + 8, input);
    }
    return bytes;
  }

  static EngineClientPacket? decode(Uint8List bytes) {
    if (bytes.length < engineClientHeader) return null;
    final view = ByteData.sublistView(bytes);
    if (view.getUint8(0) != engineWireVersion) return null;
    final flags = view.getUint8(1);
    final carries = flags & _clientInput != 0;
    if (carries && bytes.length < engineClientHeader + 8) return null;
    return EngineClientPacket(
      close: flags & _clientClose != 0,
      timestamp: view.getUint16(2),
      timestampReply: view.getUint16(4),
      ack: view.getUint64(6),
      keyframe: view.getUint32(14),
      sizeGen: view.getUint32(18),
      size: EngineSize(
        view.getUint16(22),
        view.getUint16(24),
        widthPx: view.getUint16(26),
        heightPx: view.getUint16(28),
      ),
      inputOffset: carries ? view.getUint64(engineClientHeader) : null,
      input: carries
          ? Uint8List.fromList(bytes.sublist(engineClientHeader + 8))
          : null,
    );
  }
}

class EngineServerPacket {
  const EngineServerPacket({
    this.jump = false,
    required this.timestamp,
    this.timestampReply = engineNoTimestamp,
    required this.inputAck,
    required this.sizeGen,
    required this.streamEnd,
    this.offset,
    this.data,
  });

  final bool jump;
  final int timestamp;
  final int timestampReply;
  final int inputAck;
  final int sizeGen;
  final int streamEnd;
  final int? offset;
  final Uint8List? data;

  Uint8List encode() {
    final data = this.data;
    final offset = this.offset;
    final carries = data != null && offset != null;
    final out = ByteData(engineServerHeader + (carries ? 8 + data.length : 0));
    out
      ..setUint8(0, engineWireVersion)
      ..setUint8(1, (carries ? _serverData : 0) | (jump ? _serverJump : 0))
      ..setUint16(2, timestamp & 0xffff)
      ..setUint16(4, timestampReply & 0xffff)
      ..setUint64(6, inputAck)
      ..setUint32(14, sizeGen)
      ..setUint64(18, streamEnd);
    final bytes = out.buffer.asUint8List();
    if (carries) {
      out.setUint64(engineServerHeader, offset);
      bytes.setAll(engineServerHeader + 8, data);
    }
    return bytes;
  }

  static EngineServerPacket? decode(Uint8List bytes) {
    if (bytes.length < engineServerHeader) return null;
    final view = ByteData.sublistView(bytes);
    if (view.getUint8(0) != engineWireVersion) return null;
    final flags = view.getUint8(1);
    final carries = flags & _serverData != 0;
    if (carries && bytes.length < engineServerHeader + 8) return null;
    return EngineServerPacket(
      jump: flags & _serverJump != 0,
      timestamp: view.getUint16(2),
      timestampReply: view.getUint16(4),
      inputAck: view.getUint64(6),
      sizeGen: view.getUint32(14),
      streamEnd: view.getUint64(18),
      offset: carries ? view.getUint64(engineServerHeader) : null,
      data: carries
          ? Uint8List.fromList(bytes.sublist(engineServerHeader + 8))
          : null,
    );
  }
}

Uint8List sealEngineServerPacket(
  MoshPacketCipher cipher,
  int sequence,
  Uint8List plaintext,
) {
  final wire = Uint8List(8);
  ByteData.sublistView(wire).setUint64(0, sequence);
  wire[0] |= 0x80;
  final sealed = cipher.delegate.seal(
    nonce: MoshNonce.fromWire(wire).aeadBytes,
    plaintext: plaintext,
  );
  return Uint8List(8 + sealed.length)
    ..setAll(0, wire)
    ..setAll(8, sealed);
}

bool engineFromServer(Uint8List packet) =>
    packet.isNotEmpty && packet[0] & 0x80 != 0;

Uint8List engineRecord(int kind, List<int> body) {
  final out = ByteData(_recordHeader + body.length)
    ..setUint8(0, kind)
    ..setUint32(1, body.length);
  return out.buffer.asUint8List()..setAll(_recordHeader, body);
}

sealed class EngineEvent {
  const EngineEvent();
}

class EnginePty extends EngineEvent {
  const EnginePty(this.bytes);

  final Uint8List bytes;
}

class EngineSnapshot extends EngineEvent {
  const EngineSnapshot(this.bytes);

  final Uint8List bytes;
}

class EngineExit extends EngineEvent {
  const EngineExit(this.status);

  final int status;
}

class EngineForeground extends EngineEvent {
  const EngineForeground(this.processes);

  final String processes;
}

class EngineRecordReader {
  final _header = BytesBuilder(copy: true);
  final _body = BytesBuilder(copy: true);
  int? _kind;
  int _remaining = 0;

  void reset() {
    _header.clear();
    _body.clear();
    _kind = null;
    _remaining = 0;
  }

  List<EngineEvent> add(Uint8List bytes) {
    final events = <EngineEvent>[];
    var at = 0;
    while (at < bytes.length) {
      final kind = _kind;
      if (kind == null) {
        final take = min(_recordHeader - _header.length, bytes.length - at);
        _header.add(Uint8List.sublistView(bytes, at, at + take));
        at += take;
        if (_header.length < _recordHeader) break;
        final header = ByteData.sublistView(_header.takeBytes());
        _kind = header.getUint8(0);
        _remaining = header.getUint32(1);
        if (_remaining == 0) _complete(events);
        continue;
      }
      final take = min(_remaining, bytes.length - at);
      final chunk = Uint8List.sublistView(bytes, at, at + take);
      at += take;
      _remaining -= take;
      if (kind == _recordPty) {
        if (chunk.isNotEmpty) events.add(EnginePty(Uint8List.fromList(chunk)));
      } else if (kind == _recordSnapshot ||
          kind == _recordExit ||
          kind == _recordForeground) {
        _body.add(chunk);
      }
      if (_remaining == 0) _complete(events);
    }
    return events;
  }

  void _complete(List<EngineEvent> events) {
    final kind = _kind;
    final body = _body.takeBytes();
    _kind = null;
    if (kind == _recordSnapshot) {
      events.add(EngineSnapshot(body));
    } else if (kind == _recordExit && body.length >= 4) {
      events.add(EngineExit(ByteData.sublistView(body).getInt32(0)));
    } else if (kind == _recordForeground) {
      events.add(EngineForeground(utf8.decode(body, allowMalformed: true)));
    }
  }
}

class EngineReceiver {
  EngineReceiver({this.awaitingKeyframe = true});

  static const aheadLimit = 1 << 20;

  final _records = EngineRecordReader();
  final _ahead = SplayTreeMap<int, Uint8List>();
  int _aheadBytes = 0;
  int ack = 0;

  bool awaitingKeyframe;

  List<EngineEvent> take(EngineServerPacket packet) {
    final data = packet.data;
    final offset = packet.offset;
    if (data == null || offset == null) return const [];
    if (packet.jump && offset >= ack) {
      ack = offset;
      awaitingKeyframe = false;
      _records.reset();
      while (_ahead.isNotEmpty && _ahead.firstKey()! < offset) {
        _aheadBytes -= _ahead.remove(_ahead.firstKey())!.length;
      }
    } else if (awaitingKeyframe || offset > ack) {
      if (offset > ack) _hold(offset, data);
      return const [];
    }
    final events = _consume(offset, data);
    while (_ahead.isNotEmpty && _ahead.firstKey()! <= ack) {
      final key = _ahead.firstKey()!;
      final held = _ahead.remove(key)!;
      _aheadBytes -= held.length;
      events.addAll(_consume(key, held));
    }
    return events;
  }

  List<EngineEvent> _consume(int offset, Uint8List data) {
    final end = offset + data.length;
    if (end <= ack) return [];
    final fresh = Uint8List.sublistView(data, ack - offset);
    ack = end;
    return _records.add(fresh);
  }

  void forgetAhead() {
    _ahead.clear();
    _aheadBytes = 0;
  }

  void _hold(int offset, Uint8List data) {
    if (_ahead.containsKey(offset)) return;
    if (_aheadBytes + data.length > aheadLimit) return;
    _ahead[offset] = data;
    _aheadBytes += data.length;
  }
}

class EngineOutbox {
  final _bytes = BytesBuilder(copy: true);
  Uint8List _buffer = Uint8List(0);
  int base = 0;
  int sent = 0;

  int get end => base + _buffer.length + _bytes.length;
  bool get unsent => sent < end;
  bool get inFlight => base < sent;

  void add(Uint8List bytes) => _bytes.add(bytes);

  void acknowledge(int inputAck) {
    if (inputAck <= base) return;
    _flatten();
    final drop = min(inputAck, end) - base;
    _buffer = Uint8List.fromList(_buffer.sublist(drop));
    base += drop;
    if (sent < base) sent = base;
  }

  void rewind() => sent = base;

  void adopt(int offset) {
    final shift = offset - base;
    base += shift;
    sent += shift;
  }

  (int, Uint8List)? next([int limit = engineMaxInput]) {
    if (!unsent) return null;
    _flatten();
    final from = sent - base;
    final to = min(from + limit, _buffer.length);
    final offset = sent;
    sent = base + to;
    return (offset, Uint8List.fromList(_buffer.sublist(from, to)));
  }

  void _flatten() {
    if (_bytes.isEmpty) return;
    final more = _bytes.takeBytes();
    _buffer = Uint8List(_buffer.length + more.length)
      ..setAll(0, _buffer)
      ..setAll(_buffer.length, more);
  }
}

class EngineResume {
  const EngineResume({
    required this.keyframe,
    required this.receiver,
    required this.outbox,
    required this.emitted,
  });

  final int keyframe;
  final EngineReceiver receiver;
  final EngineOutbox outbox;

  final int emitted;
}

abstract interface class EngineChannel {
  Stream<EngineEvent> get events;
  Stream<Object> get errors;

  Stream<void> get contacts;

  Future<void> get firstContact;

  void send(Uint8List bytes);
  void resize(int columns, int rows, {int widthPx = 0, int heightPx = 0});

  void poke();
  Future<void> rehome();
  Future<void> suspend();

  Future<void> close({bool end = false});

  EngineResume? get resumable;
}

typedef EngineDialer = Future<EngineChannel> Function({
  required String host,
  required int port,
  required String key,
  required int columns,
  required int rows,
  EngineResume? resume,
});

Future<EngineChannel> dialEngine({
  required String host,
  required int port,
  required String key,
  required int columns,
  required int rows,
  EngineResume? resume,
  Duration contactWindow = const Duration(seconds: 4),
  Duration lookupWindow = const Duration(seconds: 10),
}) async {
  final address =
      InternetAddress.tryParse(host) ??
      (await InternetAddress.lookup(host).timeout(lookupWindow)).first;
  final channel = UdpEngineChannel(
    address: address,
    port: port,
    cipher: MoshPacketCipher.aesOcb(MoshKey.parse(key)),
    size: EngineSize(columns, rows),
    contactWindow: contactWindow,
    resume: resume,
  );
  await channel.start();
  return channel;
}

class UdpEngineChannel implements EngineChannel {
  UdpEngineChannel({
    required this.address,
    required this.port,
    required this._cipher,
    required this._size,
    this.heartbeat = const Duration(seconds: 3),
    this.ackDelay = const Duration(milliseconds: 10),
    this.inFlightLimit = 16,
    this.contactWindow = const Duration(seconds: 4),
    this.contactTries = 2,
    this.firstResend = const Duration(milliseconds: 250),
    this.binder = RawDatagramSocket.bind,
    Random? random,
    EngineResume? resume,
  }) : keyframe =
           resume?.keyframe ??
           (random ?? Random.secure()).nextInt(0xfffffffe) + 1,
       _receiver = resume?.receiver ?? EngineReceiver(),
       _outbox = resume?.outbox ?? EngineOutbox(),
       _carried = resume != null {
    _outbox.rewind();
  }

  final InternetAddress address;
  final int port;
  final Duration heartbeat;
  final Duration ackDelay;

  final int inFlightLimit;

  final Duration contactWindow;

  final int contactTries;

  final Duration firstResend;

  final Future<RawDatagramSocket> Function(InternetAddress host, int port)
  binder;

  final int keyframe;

  final MoshPacketCipher _cipher;
  final _clock = Stopwatch()..start();
  final _rtt = MoshRttEstimator();
  final EngineReceiver _receiver;
  final EngineOutbox _outbox;

  final bool _carried;
  int _emitted = 0;

  final _events = StreamController<EngineEvent>();
  final _errors = StreamController<Object>.broadcast();
  final _contacts = StreamController<void>.broadcast();

  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _reading;
  Timer? _timer;
  EngineSize _size;
  int _sizeGen = 1;
  int _sequence = 0;
  int _unanswered = 0;
  final _contact = UdpContact();
  int? _heardStamp;
  int _heardAt = 0;
  int _sentAt = 0;
  int _progressAt = 0;
  int _ackedTo = 0;
  int? _ackDue;
  var _closed = false;
  var _suspended = false;
  var _reviving = false;

  var _failing = false;

  var _synced = false;

  @override
  Stream<EngineEvent> get events => _events.stream;

  @override
  Stream<Object> get errors => _errors.stream;

  @override
  Stream<void> get contacts => _contacts.stream;

  @override
  Future<void> get firstContact => _contact.future;

  int get ack => _receiver.ack;

  @override
  EngineResume? get resumable => _closed && !_receiver.awaitingKeyframe
      ? EngineResume(
          keyframe: keyframe,
          receiver: _receiver,
          outbox: _outbox,
          emitted: _emitted,
        )
      : null;

  Future<void> start() async {
    await _bind();
    _contact.arm(
      contactWindow,
      address: address.address,
      port: port,
      tries: contactTries,
      again: () {
        if (_suspended) return;
        // ignored: an unbound socket just lets the window run out to the verdict.
        unawaited(rehome().catchError((Object _) {}));
      },
    );
    _transmit();
  }

  @override
  void send(Uint8List bytes) {
    if (_closed || bytes.isEmpty) return;
    _outbox.add(bytes);
    if (!_suspended && _synced) _transmit();
  }

  @override
  void resize(int columns, int rows, {int widthPx = 0, int heightPx = 0}) {
    final size = EngineSize(
      columns,
      rows,
      widthPx: widthPx,
      heightPx: heightPx,
    );
    if (_closed || size == _size) return;
    _size = size;
    _sizeGen = (_sizeGen + 1) & 0xffffffff;
    if (!_suspended) _transmit();
  }

  @override
  void poke() {
    if (_closed || _suspended) return;
    _transmit(bare: true);
  }

  @override
  Future<void> rehome() async {
    if (_closed) return;
    _suspended = false;
    await _unbind();
    await _bind();
    _outbox.rewind();
    _transmit();
  }

  @override
  Future<void> suspend() async {
    if (_closed || _suspended) return;
    _suspended = true;
    _timer?.cancel();
    _timer = null;
    await _unbind();
  }

  @override
  Future<void> close({bool end = false}) async {
    if (_closed) return;
    if (end && !_suspended && _socket != null) {
      for (var i = 0; i < 3; i++) {
        _write(_packet(close: true));
      }
    }
    _closed = true;
    _receiver.forgetAhead();
    _contact.cancel();
    _timer?.cancel();
    _timer = null;
    await _unbind();
    // Completes only once a listener drains it, which may be never.
    unawaited(_events.close());
    await _errors.close();
    await _contacts.close();
  }

  Future<void> _bind() async {
    final socket = await binder(
      address.type == InternetAddressType.IPv6
          ? InternetAddress.anyIPv6
          : InternetAddress.anyIPv4,
      0,
    );
    if (_closed || _socket != null) {
      socket.close();
      return;
    }
    _socket = socket;
    _reading = socket.listen(
      (event) {
        if (event != RawSocketEvent.read) return;
        Datagram? datagram;
        while ((datagram = socket.receive()) != null) {
          _receive(datagram!);
        }
      },
      onError: (Object error) => _lose(socket, error),
      onDone: () => _lose(socket, null),
    );
  }

  /// The runtime closes a socket on any error, EPERM in the background included, and
  /// a closed socket drops every later send silently, so the next tick binds another.
  void _lose(RawDatagramSocket socket, Object? error) {
    if (error != null) _fail(error);
    if (!identical(_socket, socket)) return;
    unawaited(_reading?.cancel());
    _reading = null;
    _socket = null;
    socket.close();
    _schedule();
  }

  Future<void> _revive() async {
    if (_reviving) return;
    _reviving = true;
    try {
      await _bind();
    } catch (error) {
      _fail(error);
    } finally {
      _reviving = false;
    }
    if (_closed) return;
    if (_suspended) {
      await _unbind();
      return;
    }
    if (_socket == null) {
      _timer?.cancel();
      _timer = Timer(heartbeat, _tick);
      return;
    }
    _outbox.rewind();
    _transmit();
  }

  Future<void> _unbind() async {
    final reading = _reading;
    _reading = null;
    final socket = _socket;
    _socket = null;
    await reading?.cancel();
    socket?.close();
  }

  int get _now => _clock.elapsedMilliseconds;

  void _receive(Datagram datagram) {
    if (_closed || datagram.port != port) return;
    final packet = datagram.data;
    if (!engineFromServer(packet)) return;
    final Uint8List plaintext;
    try {
      plaintext = _cipher.decrypt(packet);
    } catch (_) {
      return;
    }
    final server = EngineServerPacket.decode(plaintext);
    if (server == null) return;
    final now = _now;
    _failing = false;
    final syncing = !_synced;
    if (syncing) {
      _synced = true;
      if (_carried && server.inputAck <= _outbox.end) {
        _outbox.acknowledge(server.inputAck);
      } else {
        _outbox.adopt(server.inputAck);
      }
    }
    _heardStamp = server.timestamp;
    _heardAt = now;
    if (server.timestampReply != engineNoTimestamp) {
      _rtt.sample((now - server.timestampReply) & 0xffff);
    }
    if (server.inputAck > _outbox.base) {
      _outbox.acknowledge(server.inputAck);
      _progressAt = now;
    }
    _contacts.add(null);
    _contact.hear();
    final before = _receiver.ack;
    for (final event in _receiver.take(server)) {
      if (_closed) return;
      if (event is! EngineExit) _emitted++;
      _events.add(event);
    }
    if (_receiver.ack != before) {
      _ackDue ??= now + ackDelay.inMilliseconds;
    }
    if (syncing && _outbox.unsent) {
      _transmit();
      return;
    }
    _schedule();
  }

  void _transmit({bool bare = false}) {
    if (_closed || _suspended || _socket == null) return;
    var wrote = false;
    if (!bare && _synced) {
      final window = inFlightLimit * engineMaxInput;
      if (!_outbox.inFlight) _progressAt = _now;
      while (_outbox.unsent && _outbox.sent - _outbox.base < window) {
        final (offset, bytes) = _outbox.next()!;
        _write(_packet(inputOffset: offset, input: bytes));
        wrote = true;
      }
    }
    if (!wrote) _write(_packet());
    _schedule();
  }

  EngineClientPacket _packet({
    bool close = false,
    int? inputOffset,
    Uint8List? input,
  }) {
    final now = _now;
    final heard = _heardStamp;
    final held = now - _heardAt;
    final stamp = now & 0xffff;
    return EngineClientPacket(
      close: close,
      timestamp: stamp == engineNoTimestamp ? 0 : stamp,
      timestampReply: heard == null || held >= 1000
          ? engineNoTimestamp
          : (heard + held) & 0xffff,
      ack: _receiver.ack,
      keyframe: keyframe,
      sizeGen: _sizeGen,
      size: _size,
      inputOffset: inputOffset,
      input: input,
    );
  }

  void _write(EngineClientPacket packet) {
    final socket = _socket;
    if (socket == null) return;
    final sealed = _cipher.encrypt(
      nonce: _sequence++,
      plaintext: packet.encode(),
    );
    _sentAt = _now;
    if (!_synced) _unanswered++;
    _ackedTo = packet.ack;
    _ackDue = null;
    try {
      socket.send(sealed, address, port);
    } catch (error) {
      _lose(socket, error);
    }
  }

  void _schedule() {
    _timer?.cancel();
    _timer = null;
    if (_closed || _suspended) return;
    final now = _now;
    var due = _sentAt + _interval;
    final ackDue = _ackDue;
    if (ackDue != null && _receiver.ack != _ackedTo) due = min(due, ackDue);
    if (_outbox.inFlight) due = min(due, _progressAt + _rtt.rto);
    _timer = Timer(Duration(milliseconds: max(0, due - now)), _tick);
  }

  int get _interval => _synced
      ? heartbeat.inMilliseconds
      : min(
          firstResend.inMilliseconds << min(max(0, _unanswered - 1), 16),
          heartbeat.inMilliseconds,
        );

  void _tick() {
    _timer = null;
    if (_closed || _suspended) return;
    if (_socket == null) {
      unawaited(_revive());
      return;
    }
    final now = _now;
    if (_outbox.inFlight && now - _progressAt >= _rtt.rto) {
      _outbox.rewind();
      _progressAt = now;
      _transmit();
      return;
    }
    final ackDue = _ackDue;
    if (ackDue != null && now >= ackDue && _receiver.ack != _ackedTo) {
      _transmit();
      return;
    }
    if (now - _sentAt >= _interval) {
      _transmit();
      return;
    }
    _schedule();
  }

  void _fail(Object error) {
    if (_failing) return;
    _failing = true;
    if (!_errors.isClosed) _errors.add(error);
  }
}
