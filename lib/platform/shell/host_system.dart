import '../../data/enums.dart';
import 'remote_shell.dart';
import 'shell_connection.dart';

const systemProbeScript = 'uname -s; cat /etc/os-release 2>/dev/null';

HostSystem parseSystemProbe(String output) {
  final lines = output.split('\n').map((line) => line.trim()).toList();
  final kernel = lines.isEmpty ? '' : lines.first.toLowerCase();
  if (kernel == 'darwin') return HostSystem.darwin;
  if (kernel != 'linux') return HostSystem.other;
  for (final line in lines.skip(1)) {
    if (!line.startsWith('ID=')) continue;
    final id = line.substring(3).replaceAll('"', '').replaceAll("'", '');
    if (id == 'nixos') return HostSystem.nixos;
  }
  return HostSystem.linux;
}

Future<HostSystem?> probeSystem(HostChannels channels) async {
  final result = await channels.exec(
    underSh(systemProbeScript),
    timeout: const Duration(seconds: 10),
  );
  if (result == null || !result.ok) return null;
  return parseSystemProbe(result.out);
}
