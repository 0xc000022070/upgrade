import 'dart:typed_data';

import 'package:gal/gal.dart';

/// Writes one PNG into the phone's gallery, under the app's own album, and
/// asks for access on the way when the platform still wants asking — which is
/// Android up to 9 and nothing after, where the app's own media are its own.
typedef GallerySaver = Future<void> Function(Uint8List png, String name);

const galleryAlbum = 'Spectacle';

Future<void> saveToGallery(Uint8List png, String name) async {
  if (!await Gal.hasAccess() && !await Gal.requestAccess()) {
    throw const GalleryDenied();
  }
  await Gal.putImageBytes(png, album: galleryAlbum, name: name);
}

class GalleryDenied implements Exception {
  const GalleryDenied();

  @override
  String toString() => 'gallery access denied';
}
