import '../../application/clips.dart';
import 'framebuffer_view.dart';

/// How long the breadcrumb carries what became of a crop.
const cropNoticeLinger = Duration(seconds: 2);

/// The one line the breadcrumb shows after `SAVE` or `HOLD`: what happened
/// to the pixels, in the words the user chose them with.
String heldNotice(Clip clip) =>
    clip.sizeLabel.isEmpty ? 'HELD' : 'HELD · ${clip.sizeLabel}';

String savedNotice(int width, int height) => 'SAVED · $width×$height';

String cropFailedNotice(CropTarget target, Object error) {
  final verb = switch (target) {
    CropTarget.save => 'SAVE',
    CropTarget.hold => 'HOLD',
  };
  return '$verb FAILED · $error';
}
