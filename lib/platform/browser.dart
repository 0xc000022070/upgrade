import 'package:url_launcher/url_launcher.dart';

/// Always [LaunchMode.externalApplication]: a link leaves the app. False when the text
/// is not a URI at all or nothing on the device took it.
Future<bool> openUrl(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null) return false;
  return launchUrl(uri, mode: LaunchMode.externalApplication);
}
