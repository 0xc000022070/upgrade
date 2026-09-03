import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/agents.dart';
import '../../application/providers.dart';
import '../../data/database.dart';
import '../../data/repositories/host_repository.dart';
import '../../platform/vnc/framebuffer.dart';
import '../../platform/vnc/rfb_client.dart';
import '../../platform/vnc/rfb_messages.dart';
import '../../platform/vnc/vnc_failure.dart';
import '../../platform/vnc/vnc_tunnel.dart';
import 'framebuffer_view.dart';
import 'host_screen.dart';
import 'screen_controller.dart';

/// A way into SPEC.md §39.32's route before the section's own entry points
/// exist.
///
/// The `SCREEN >` affordance and the settings row live in files another builder
/// holds right now, so this entry point stands in for them: same providers,
/// same database, same keystore, and the same [openHostScreen] the panel will
/// call. Run with `flutter run -t lib/features/screen/screen_debug_main.dart`;
/// nothing imports it.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final db = AppDatabase();
  await db.customSelect('SELECT 1').get();
  runApp(
    ProviderScope(
      overrides: databaseOverrides(db),
      child: const MaterialApp(
        debugShowCheckedModeBanner: false,
        home: _HostPicker(),
      ),
    ),
  );
}

class _HostPicker extends ConsumerWidget {
  const _HostPicker();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hosts = ref.watch(hostsProvider);
    return Scaffold(
      backgroundColor: const Color(0xFF0B0B0B),
      appBar: AppBar(title: const Text('SCREEN debug')),
      body: hosts.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('$error')),
        data: (rows) => ListView(
          children: [
            ListTile(
              textColor: const Color(0xFFE0E0E0),
              title: const Text('MEASURE  1080p update'),
              subtitle: const Text('decode and raster, 30 updates'),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const _Measure()),
              ),
            ),
            // §39.32's live target is nyx on the port the real sshd listens
            // on, which is not what the stored rows point at. Borrows the key
            // the stored rows use.
            for (final host in [..._emulatorHosts(rows), ...rows])
              ListTile(
                textColor: const Color(0xFFE0E0E0),
                title: Text('${host.name}  ${host.address}:${host.port}'),
                subtitle: Text('${host.user} / key ${host.keyId}'),
                onTap: () => openHostScreen(context, host),
                // A screen without the tunnel, for the days the key on the
                // host has not been authorized yet: same route, same RFB
                // client, wayvnc's own listener instead of a forwarded
                // channel. Never a path the app itself offers.
                trailing: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => HostScreenRoute(
                        host: host,
                        open: _openDirect,
                      ),
                    ),
                  ),
                  child: const Text('DIRECT'),
                ),
                // The reason line and its `RETRY`, on demand: the same host
                // pointed at a port nothing is listening on.
                onLongPress: () => openHostScreen(context, _wrongPort(host)),
              ),
          ],
        ),
      ),
    );
  }

  /// nyx as the emulator can reach it. The emulator runs on rose, so 10.0.2.2
  /// is rose's own loopback and not the host wayvnc is on; nyx answers on 357
  /// at both its tailnet and its LAN address.
  List<Host> _emulatorHosts(List<Host> rows) {
    if (rows.isEmpty) return const [];
    final key = rows.first.keyId;
    return [
      for (final address in const ['100.118.60.77', '192.168.18.36'])
        Host(
          id: 'debug-nyx-$address',
          name: 'nyx',
          address: address,
          port: 357,
          user: 'luisnquin',
          keyId: key,
        ),
    ];
  }

  Host _wrongPort(Host host) => Host(
    id: host.id,
    name: host.name,
    address: host.address,
    port: 1,
    user: host.user,
    keyId: host.keyId,
  );
}

/// §39.32 asks for the cost of one 1080p update on the device. With no host
/// answering, the update is synthesized: a full-screen framebuffer whose bytes
/// all differ, pushed through the route's own [decodeFramebuffer] and painted
/// by the route's own painter, thirty times.
///
/// Both halves are timed because they are charged to different threads: the
/// decode is an upload on the UI thread and shows up in the controller's own
/// `lastFrameTime`, and the paint is one `drawImageRect` the raster thread
/// does, which only a frame timing can see.
class _Measure extends StatefulWidget {
  const _Measure();

  @override
  State<_Measure> createState() => _MeasureState();
}

class _MeasureState extends State<_Measure> {
  static const _updates = 30;

  final _decodes = <double>[];
  final _rasters = <double>[];
  ui.Image? _image;
  String _line = 'measuring…';
  int _done = 0;

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  @override
  void dispose() {
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    _image?.dispose();
    super.dispose();
  }

  /// Only the frames this route drew, and only after the first: the first is
  /// the route's own entrance and has no framebuffer in it.
  void _onTimings(List<FrameTiming> timings) {
    if (_done == 0) return;
    for (final timing in timings) {
      _rasters.add(timing.rasterDuration.inMicroseconds / 1000);
    }
  }

  Future<void> _run() async {
    final framebuffer = Framebuffer(1920, 1080);
    for (var i = 0; i < _updates; i++) {
      // A different byte in every pixel and a different image every update, so
      // nothing upstream can hand back the last one.
      for (var p = 0; p < framebuffer.pixels.length; p += 4) {
        framebuffer.pixels[p] = (p + i) & 0xFF;
        framebuffer.pixels[p + 1] = (p >> 8) & 0xFF;
        framebuffer.pixels[p + 2] = (p >> 5) & 0xFF;
      }
      final watch = Stopwatch()..start();
      final image = await decodeFramebuffer(framebuffer);
      watch.stop();
      if (!mounted) {
        image.dispose();
        return;
      }
      _decodes.add(watch.elapsedMicroseconds / 1000);
      setState(() {
        _image?.dispose();
        _image = image;
        _done = i + 1;
      });
      // One frame has to actually go up before the next update is timed, or
      // thirty decodes would land on one raster.
      await SchedulerBinding.instance.endOfFrame;
    }
    if (!mounted) return;
    setState(() {
      _line =
          'decode ${_stat(_decodes)}  ·  raster ${_stat(_rasters)}  ·  '
          '1920x1080, $_updates updates';
    });
    debugPrint('hotline.vnc measure: $_line');
  }

  static String _stat(List<double> samples) {
    if (samples.isEmpty) return 'n/a';
    final sorted = [...samples]..sort();
    String at(double q) =>
        sorted[(q * (sorted.length - 1)).round()].toStringAsFixed(1);
    return 'p50 ${at(0.5)}ms p90 ${at(0.9)}ms';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF000000),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                _done < _updates ? 'measuring $_done/$_updates' : _line,
                style: const TextStyle(
                  color: Color(0xFFE0E0E0),
                  fontFamily: 'monospace',
                ),
              ),
            ),
            Expanded(
              child: FramebufferView(
                image: _image,
                framebufferSize: const Size(1920, 1080),
                onClick: (_) {},
                onRightClick: (_) {},
                onDrag: (_, {required bool down}) {},
                onWheel: (_, {required bool up}) {},
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// wayvnc reached straight over TCP, with no ssh in front of it.
///
/// Debug only, and only because §39.32's evidence needs a screen to show while
/// the key waits to be authorized on the host. Everything above the socket is
/// the shipped path: the same [RfbClient], the same handshake, the same route.
Future<VncConnection> _openDirect({
  required String address,
  required int port,
  required String user,
  required String privateKey,
}) async {
  final socket = await guardVnc(
    () => Socket.connect(address, VncTunnel.displayPort,
        timeout: const Duration(seconds: 10)),
  );
  final rfb = RfbClient(incoming: socket, outgoing: socket);
  try {
    return _DirectConnection(socket, rfb, await guardVnc(rfb.handshake));
  } catch (_) {
    await rfb.close();
    socket.destroy();
    rethrow;
  }
}

class _DirectConnection implements VncConnection {
  _DirectConnection(this._socket, this.rfb, this.serverInit);

  final Socket _socket;

  @override
  final RfbClient rfb;

  @override
  final RfbServerInit serverInit;

  @override
  Future<void> close() async {
    await rfb.close();
    _socket.destroy();
  }
}
