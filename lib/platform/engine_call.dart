Map<String, Object?> engineRequest(
  String service,
  String op,
  Map<String, Object?> args, {
  required String owner,
}) => {'service': service, 'op': op, 'owner': owner, 'args': args};

enum EnginePart { reply, result }

sealed class EngineReply {
  const EngineReply();

  factory EngineReply.parse(Object? json) {
    if (json is! Map<String, Object?>) {
      return const EngineMalformed(EnginePart.reply);
    }
    if (json['ok'] != true) {
      final error = json['error'];
      final failure = error is Map<String, Object?> ? error : const {};
      final kind = failure['kind'];
      final message = failure['message'];
      return EngineErr(
        kind is String ? kind : null,
        message is String ? message : null,
      );
    }
    final result = json['result'];
    return result is Map<String, Object?>
        ? EngineOk(result)
        : const EngineMalformed(EnginePart.result);
  }
}

final class EngineOk extends EngineReply {
  const EngineOk(this.result);
  final Map<String, Object?> result;
}

final class EngineErr extends EngineReply {
  const EngineErr(this.kind, this.message);
  final String? kind;
  final String? message;
}

final class EngineMalformed extends EngineReply {
  const EngineMalformed(this.part);
  final EnginePart part;
}

/// A machine with no engine answers over the shell instead: 127 and a line of its own.
bool engineNotInstalled(int? exitCode, String complaint) =>
    exitCode == 127 || complaint.endsWith('not found');

/// Asks the host for its `daemon/1` over ssh; [reply] sends one request and returns the
/// decoded answer, whatever it is.
Future<Map<String, Object?>?> Function() daemonStart(
  String owner,
  Future<Object?> Function(Map<String, Object?> request) reply,
) =>
    () async => switch (EngineReply.parse(
      await reply(engineRequest('daemon/1', 'start', const {}, owner: owner)),
    )) {
      EngineOk(:final result) => result,
      _ => null,
    };
