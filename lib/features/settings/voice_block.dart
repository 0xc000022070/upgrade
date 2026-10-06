import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/whisper.dart';
import '../../design/components/panel.dart';
import '../../design/tokens.dart';
import '../../platform/whisper.dart';

final _size = '${(modelBytes(whisperFiles) / 1e6).round()} MB';

String whisperSubtitle(WhisperState state) => switch (state) {
  WhisperOff(fault: ModelFault.corrupt) => 'MODEL CORRUPT',
  WhisperOff(fault: ModelFault.failed) => 'DOWNLOAD FAILED',
  WhisperOff() => '$_size DOWNLOAD · STAYS ON THE PHONE',
  WhisperFetching(:final progress) =>
    'DOWNLOADING ${(progress * 100).floor()}%',
  WhisperReady() => 'READY · $_size',
};

class VoiceSettingsBlock extends ConsumerWidget {
  const VoiceSettingsBlock({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(whisperModelProvider);
    final model = ref.read(whisperModelProvider.notifier);
    return Panel(
      title: '[ VOICE ]',
      bodyPadding: panelRowsPadding,
      child: Material(
        type: MaterialType.transparency,
        child: SwitchListTile.adaptive(
          key: const ValueKey('settings-whisper'),
          contentPadding: EdgeInsets.zero,
          title: Text('WHISPER', style: context.tokens.rowTitle),
          subtitle: Text(
            whisperSubtitle(state),
            style: context.tokens.rowSubtitle,
          ),
          value: state is! WhisperOff,
          onChanged: (on) => unawaited(on ? model.enable() : model.disable()),
        ),
      ),
    );
  }
}
