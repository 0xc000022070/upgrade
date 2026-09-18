import 'dart:async';
import 'dart:convert';

/// One connection to a herdr server's socket: the bytes in, the bytes out, and
/// the way to let it go.
///
/// Who opens it is not this layer's business. In the app it is a
/// `direct-streamlocal@openssh.com` channel inside the host's own ssh
/// connection; in a test it is two controllers.
class HerdrLink {
  const HerdrLink({
    required this.incoming,
    required this.outgoing,
    required this.shut,
  });

  final Stream<List<int>> incoming;
  final StreamSink<List<int>> outgoing;
  final Future<void> Function() shut;
}

typedef HerdrDial = Future<HerdrLink> Function();

/// What herdr answered.
sealed class HerdrReply {
  const HerdrReply();
}

final class HerdrResult extends HerdrReply {
  const HerdrResult(this.type, this.value);

  /// herdr's own name for the shape of [value]: `agent_list`, `ok`, `pong`.
  final String type;

  final Map<String, Object?> value;
}

/// The request arrived and the server said no. A refusal is data: which of the
/// steps of a send failed, and whether a prompt was read, are both read off
/// [code].
final class HerdrRefusal extends HerdrReply {
  const HerdrRefusal(this.code, this.message);

  final String code;
  final String message;
}

/// One event off a held subscription.
///
/// herdr names an event twice: `pane_updated` on the envelope every client
/// gets, `pane.agent_status_changed` on the ones a subscription asked for by
/// pane. [kind] is the second form written as the first, so a reader has one
/// vocabulary.
class HerdrEvent {
  const HerdrEvent(this.kind, this.data);

  final String kind;
  final Map<String, Object?> data;
}

/// A reply this layer could not read, or a link that went away mid-request.
///
/// Its own exception rather than one of the app's reason lines: nothing here
/// knows which host it is talking to, and the caller maps it.
class HerdrMalformed implements Exception {
  const HerdrMalformed([this.detail, this.protocol]);

  final String? detail;

  /// The protocol number the far side reported, when it reported one.
  final int? protocol;

  @override
  String toString() => 'HerdrMalformed(${detail ?? ''})';
}

/// herdr's socket API, newline-delimited JSON.
///
/// A server answers one request per connection and then stops reading, so
/// every call dials its own link and a subscription holds one of its own. That
/// is still the cheap side of the trade: a channel is a window and two
/// packets, where the command line it replaces was a shell, a `herdr` process
/// and this same socket opened from the far end.
class HerdrApi {
  HerdrApi(this.dial);

  final HerdrDial dial;

  var _id = 0;

  Future<HerdrReply> call(
    String method, [
    Map<String, Object?> params = const {},
  ]) async {
    final link = await dial();
    try {
      final answer = _lines(link.incoming).first;
      link.outgoing.add(_frame(_next(), method, params));
      return _reply(await answer);
    } on StateError catch (error) {
      // `first` on a stream that closed with nothing in it.
      throw HerdrMalformed('$method: $error');
    } finally {
      await link.shut();
    }
  }

  /// Events from [subscriptions] until the caller stops listening or the link
  /// goes. herdr sends `subscription_started` first; a link that answers
  /// anything else never became a subscription and the stream fails.
  Stream<HerdrEvent> subscribe(List<Map<String, Object?>> subscriptions) {
    final events = StreamController<HerdrEvent>();
    HerdrLink? held;
    StreamSubscription<String>? reading;
    events.onListen = () async {
      try {
        final link = await dial();
        held = link;
        var started = false;
        reading = _lines(link.incoming).listen(
          (line) {
            try {
              if (started) {
                final event = _event(line);
                if (event != null) events.add(event);
                return;
              }
              started = true;
              final reply = _reply(line);
              if (reply is! HerdrResult ||
                  reply.type != 'subscription_started') {
                throw HerdrMalformed(line);
              }
            } catch (error, stack) {
              events.addError(error, stack);
              events.close();
            }
          },
          onError: events.addError,
          onDone: events.close,
        );
        link.outgoing.add(
          _frame(_next(), 'events.subscribe', {'subscriptions': subscriptions}),
        );
      } catch (error, stack) {
        events.addError(error, stack);
        await events.close();
      }
    };
    events.onCancel = () async {
      await reading?.cancel();
      await held?.shut();
    };
    return events.stream;
  }

  String _next() => 'dazzle:${_id++}';

  static List<int> _frame(
    String id,
    String method,
    Map<String, Object?> params,
  ) => utf8.encode(
    '${jsonEncode({'id': id, 'method': method, 'params': params})}\n',
  );

  /// The cast is what makes this run: ssh hands over a `Stream<Uint8List>`,
  /// whose `transform` asks for a `StreamTransformer<Uint8List, String>` off
  /// the runtime type argument, and `utf8.decoder` is one over `List<int>`.
  /// Without it the decode throws where only the device can see it.
  static Stream<String> _lines(Stream<List<int>> bytes) => bytes
      .cast<List<int>>()
      .transform(utf8.decoder)
      .transform(const LineSplitter());

  /// A response line: the result and its type, or herdr's refusal.
  static HerdrReply _reply(String line) {
    final decoded = _decode(line);
    final error = decoded['error'];
    if (error is Map<String, Object?>) {
      final code = error['code'];
      final message = error['message'];
      if (code is! String) throw HerdrMalformed(line);
      return HerdrRefusal(code, message is String ? message : '');
    }
    final result = decoded['result'];
    if (result is! Map<String, Object?>) throw HerdrMalformed(line);
    final type = result['type'];
    if (type is! String) throw HerdrMalformed(line, _protocol(result));
    return HerdrResult(type, result);
  }

  /// An event line, or null for a line that is a response: a subscription
  /// carries both, and a late reply is not an event.
  static HerdrEvent? _event(String line) {
    final decoded = _decode(line);
    final kind = decoded['event'];
    if (kind is! String) return null;
    final data = decoded['data'];
    return HerdrEvent(
      kind.replaceAll('.', '_'),
      data is Map<String, Object?> ? data : const {},
    );
  }

  static Map<String, Object?> _decode(String line) {
    Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      throw HerdrMalformed(line);
    }
    if (decoded is! Map<String, Object?>) throw HerdrMalformed(line);
    return decoded;
  }

  static int? _protocol(Map<String, Object?> result) {
    final protocol = result['protocol'];
    return protocol is int ? protocol : null;
  }
}
