import 'dart:io';

import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../application/clips.dart';

/// An image attachment is a copy, not a reference. The gallery
/// entry the user picked can be deleted, moved or re-encoded by the OS, and a
/// content URI does not survive a reinstall; the app support directory does.
///
/// Rows store the path *relative* to that directory. The sandbox path carries
/// the package's data directory and changes between installs on some devices,
/// so an absolute path in the database is a broken image waiting for an
/// upgrade.
abstract final class ImageAttachments {
  static const _uuid = Uuid();
  static const _dir = 'attachments';

  static String? _root;

  /// Resolved once at boot so a chip and a readout square can turn a row into a
  /// file synchronously, inside a build.
  static Future<void> init() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, _dir));
    if (!dir.existsSync()) await dir.create(recursive: true);
    _root = support.path;
  }

  /// Null before [init] has run — in a widget test, which has no platform
  /// channels and no images to show either.
  static String? absolute(String relative) =>
      _root == null ? null : p.join(_root!, relative);

  /// Gallery only, no camera. Returns the relative path of the copy, or
  /// null when the picker was dismissed.
  ///
  /// The picker's own resize is used on the way in. What is kept is what is
  /// sent, and a camera's full frame is tens of times the bytes of a picture
  /// an agent can read just as well — the phone's own storage pays for the
  /// difference too, for the whole life of the drop.
  static Future<String?> pick() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: photoAttachEdge,
      maxHeight: photoAttachEdge,
    );
    if (picked == null) return null;
    if (_root == null) await init();
    final extension = p.extension(picked.path).toLowerCase();
    final relative = p.join(
      _dir,
      '${_uuid.v7()}${extension.isEmpty ? '.jpg' : extension}',
    );
    await picked.saveTo(p.join(_root!, relative));
    return relative;
  }

  /// Best effort: the row is the record, and a file that is already gone must
  /// not stop the row from being deleted.
  static Future<void> remove(String relative) async {
    final path = absolute(relative);
    if (path == null) return;
    final file = File(path);
    if (file.existsSync()) await file.delete();
  }
}
