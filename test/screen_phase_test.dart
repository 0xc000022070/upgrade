import 'package:flutter_test/flutter_test.dart';
import 'package:dazzle/data/repositories/host_repository.dart';
import 'package:dazzle/features/screen/screen_controller.dart';

const _nyx = Host(
  id: 'nyx',
  name: 'NYX',
  address: '100.118.60.77',
  port: 22,
  user: 'luisnquin',
  keyId: 'k1',
);

void main() {
  test(
    'a dial that has not answered yet is connecting, and carries no reason',
    () {
      final controller = HostScreenController(
        host: _nyx,
        readPrivateKey: (_) async => 'PRIVATE',
      );
      addTearDown(controller.dispose);

      expect(controller.phase, isA<ScreenConnecting>());
    },
  );

  test('a failure puts its worded line on the phase itself', () async {
    final controller = HostScreenController(
      host: _nyx,
      readPrivateKey: (_) async => null,
    );
    addTearDown(controller.dispose);

    await controller.connect();

    final phase = controller.phase;
    expect(phase, isA<ScreenFailed>());
    expect((phase as ScreenFailed).reason, 'key rejected');
  });

  test('a retry goes back to connecting and drops the line with it', () async {
    final controller = HostScreenController(
      host: _nyx,
      readPrivateKey: (_) async => null,
    );
    addTearDown(controller.dispose);

    await controller.connect();
    expect(controller.phase, isA<ScreenFailed>());

    final dialling = controller.connect();
    expect(controller.phase, isA<ScreenConnecting>());
    await dialling;
  });
}
