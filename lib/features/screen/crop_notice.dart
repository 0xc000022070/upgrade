import 'package:upgrade/application/clips.dart';
import 'package:upgrade/features/screen/framebuffer_view.dart';

const cropNoticeLinger = Duration(seconds: 2);

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
