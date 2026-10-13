import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/application/providers.dart';
import 'package:upgrade/application/whisper.dart';
import 'package:upgrade/data/repositories/settings_repository.dart';
import 'package:upgrade/design/components/panel.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/platform/voice/whisper.dart';

String _size(WhisperSize size) =>
    '${(modelBytes(size.files) / 1e6).round()} MB';

String _cost(WhisperSize size) => switch (size) {
  WhisperSize.base => 'STAYS ON THE PHONE',
  WhisperSize.small => 'SHARPER, SLOWER',
};

String whisperSubtitle(
  WhisperSize size,
  WhisperState state, {
  required bool hearing,
}) => switch (state) {
  WhisperOff(fault: ModelFault.corrupt) => 'MODEL CORRUPT',
  WhisperOff(fault: ModelFault.failed) => 'DOWNLOAD FAILED',
  WhisperOff() => '${_size(size)} DOWNLOAD · ${_cost(size)}',
  WhisperFetching(:final progress) =>
    'DOWNLOADING ${(progress * 100).floor()}%',
  WhisperReady() => '${hearing ? 'IN USE' : 'INSTALLED'} · ${_size(size)}',
};

const whisperLanguages = ['', 'es', 'en', 'pt', 'fr', 'de', 'it'];

class VoiceSettingsBlock extends ConsumerWidget {
  const VoiceSettingsBlock({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hearing = whisperHearing(
      (size) => ref.watch(whisperModelProvider(size)),
    );
    final language = ref.watch(whisperLanguageProvider).value ?? '';
    return Panel(
      title: '[ VOICE ]',
      bodyPadding: panelRowsPadding,
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final size in WhisperSize.values)
              _ModelRow(size: size, hearing: size == hearing),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('LANGUAGE', style: context.tokens.rowTitle),
              subtitle: Text(
                "WHISPER ONLY · THE PHONE'S RECOGNIZER FOLLOWS ITS OWN",
                style: context.tokens.rowSubtitle,
              ),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final code in whisperLanguages)
                  ChoiceChip(
                    key: ValueKey('settings-whisper-language-$code'),
                    label: Text(code.isEmpty ? 'AUTO' : code.toUpperCase()),
                    selected: code == language,
                    onSelected: (_) => unawaited(
                      ref
                          .read(settingsRepositoryProvider)
                          .setText(SettingsRepository.whisperLanguage, code),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ModelRow extends ConsumerWidget {
  const _ModelRow({required this.size, required this.hearing});

  final WhisperSize size;
  final bool hearing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(whisperModelProvider(size));
    final model = ref.read(whisperModelProvider(size).notifier);
    return SwitchListTile.adaptive(
      key: ValueKey('settings-whisper-${size.name}'),
      contentPadding: EdgeInsets.zero,
      title: Text(
        'WHISPER ${size.name.toUpperCase()}',
        style: context.tokens.rowTitle,
      ),
      subtitle: Text(
        whisperSubtitle(size, state, hearing: hearing),
        style: context.tokens.rowSubtitle,
      ),
      value: state is! WhisperOff,
      onChanged: (on) => unawaited(on ? model.enable() : model.disable()),
    );
  }
}
