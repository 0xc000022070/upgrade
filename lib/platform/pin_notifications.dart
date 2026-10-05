import 'package:upgrade_shade/upgrade_shade.dart';
import 'package:flutter/foundation.dart';

import '../application/pin_alerts.dart';

/// A channel of its own so the user can keep a blocked agent quiet and still hear a key
/// being asked for. Posted natively: flutter_local_notifications can neither keep the
/// system's suggested actions off it nor let the channel through Do Not Disturb.
class PinNotifications implements PinNotifier {
  const PinNotifications();

  static const channelId = 'passphrase_asks';
  static const channelName = 'Passphrase requests';

  static const _retired = ['pin_requests'];

  static Future<void> createChannel() async {
    try {
      await UpgradeShade.createChannel(
        id: channelId,
        name: channelName,
        retired: _retired,
      );
    } catch (error) {
      debugPrint('upgrade.pin channel: $error');
    }
  }

  @override
  Future<void> raise({
    required String hostId,
    required String askId,
    required String text,
  }) async {
    try {
      await UpgradeShade.show(
        id: pinNotificationId(hostId),
        channelId: channelId,
        title: pinNotificationTitle,
        body: text,
        payload: pinPayload(hostId),
        ask: askId,
      );
    } catch (error) {
      debugPrint('upgrade.pin notification: $error');
    }
  }

  @override
  Future<void> withdraw(String hostId) async {
    try {
      await UpgradeShade.cancel(pinNotificationId(hostId));
    } catch (error) {
      debugPrint('upgrade.pin notification: $error');
    }
  }
}
