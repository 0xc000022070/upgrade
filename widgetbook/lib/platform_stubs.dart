import 'package:flutter/services.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:upgrade/platform/channels.dart';

/// The app's event channels have an Android side only. Answered here, a widget that
/// subscribes gets no events instead of a MissingPluginException in the console.
void answerDeviceChannels() {
  webPluginRegistrar.registerMessageHandler();
  for (final name in const [Channels.deviceThrottle, Channels.deviceNetwork]) {
    webPluginRegistrar.setMessageHandler(
      name,
      (_) async => const StandardMethodCodec().encodeSuccessEnvelope(null),
    );
  }
}
