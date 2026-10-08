import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../platform/bundle_cipher.dart';
import 'bundle.dart';

Future<String?> applySeedBundle(BundleTransfer transfer) async {
  if (!kDebugMode) return null;
  final support = await getApplicationSupportDirectory();
  final file = File('${support.path}/seed-bundle.json');
  if (!await file.exists()) return null;
  try {
    final count = await transfer.apply(Bundle.decode(await file.readAsBytes()));
    return '${count.hosts} hosts';
  } on BundleException catch (error) {
    return error.fault.name;
  } finally {
    await file.delete();
  }
}
