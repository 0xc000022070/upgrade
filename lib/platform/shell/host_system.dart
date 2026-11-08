import 'package:upgrade/data/host_system.dart';
import 'package:upgrade/platform/shell/remote_shell.dart';
import 'package:upgrade/platform/shell/shell_connection.dart';

const systemProbeScript = 'uname -s; cat /etc/os-release 2>/dev/null';

HostSystem parseSystemProbe(String output) {
  final lines = output.split('\n').map((line) => line.trim()).toList();
  final kernel = lines.isEmpty ? '' : lines.first.toLowerCase();
  if (kernel == 'darwin') return HostSystem.darwin;
  if (kernel != 'linux') return HostSystem.other;
  for (final line in lines.skip(1)) {
    if (!line.startsWith('ID=')) continue;
    final id = line.substring(3).replaceAll('"', '').replaceAll("'", '');
    switch (id) {
      case 'nixos':
        return HostSystem.nixos;
      case 'ubuntu':
        return HostSystem.ubuntu;
      case 'arch' || 'archarm':
        return HostSystem.arch;
      case 'alpine':
        return HostSystem.alpine;
    }
  }
  return HostSystem.linux;
}

Future<HostSystem?> probeSystem(HostChannels channels) async {
  final result = await channels.exec(
    underSh(systemProbeScript),
    timeout: const Duration(seconds: 10),
  );
  // The exit is cat's, which fails on a Mac with no os-release; only the answer counts.
  final out = result?.out ?? '';
  if (out.trim().isEmpty) return null;
  return parseSystemProbe(out);
}
