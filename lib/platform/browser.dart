import 'package:url_launcher/url_launcher.dart';

/// The one hand-off to whatever the phone opens links with.
///
/// Written twice before this — once for a token painted into a title, once for
/// a link attachment — and both copies were the same four lines. A verb the
/// app performs on the device belongs beside the gallery and the notifications
/// rather than inside the feature that happened to need it first.
///
/// Always [LaunchMode.externalApplication]: a link leaves the app. False when
/// the text is not a URI at all or nothing on the device took it.
Future<bool> openUrl(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null) return false;
  return launchUrl(uri, mode: LaunchMode.externalApplication);
}
