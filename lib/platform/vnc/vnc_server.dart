typedef HostRun = Future<int> Function(String command);

abstract class VncServer {
  const VncServer();

  factory VncServer.named(String name) => switch (name) {
    'WayVNC' => const Wayvnc(),
    _ => const PlainRfb(),
  };

  bool get cyclesOutputs => false;

  Future<void> cycleOutput(HostRun run) =>
      throw UnsupportedError('$runtimeType serves one output');
}

class PlainRfb extends VncServer {
  const PlainRfb();
}

/// wayvnc captures one output at a time and takes orders through `wayvncctl`, which reaches
/// it over its control socket on the host.
class Wayvnc extends VncServer {
  const Wayvnc();

  @override
  bool get cyclesOutputs => true;

  @override
  Future<void> cycleOutput(HostRun run) async {
    final code = await run('wayvncctl output-cycle');
    if (code != 0) throw StateError('wayvncctl exited $code');
  }
}
