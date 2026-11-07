import 'package:flutter/widgets.dart';
import 'package:widgetbook/widgetbook.dart';

import 'package:upgrade/design/components/connection_glyph.dart';
import 'package:upgrade/design/components/dot_spinner.dart';
import 'package:upgrade/design/components/progress_bar.dart';
import 'package:upgrade/design/components/scan_sweep.dart';
import 'package:upgrade/design/components/signal_text.dart';
import 'package:upgrade/design/tokens.dart';

import 'package:upgrade_widgetbook/components/knobs.dart';
import 'package:upgrade_widgetbook/frame.dart';

final feedbackComponents = [
  WidgetbookComponent(
    name: 'ProgressBar',
    useCases: [
      WidgetbookUseCase(
        name: 'Playground',
        builder: (context) {
          final head = context.knobs.boolean(label: 'Head');
          return Stage(
            children: [
              ProgressBar(
                value: context.knobs.double.slider(
                  label: 'Value',
                  initialValue: 0.62,
                  max: 1,
                ),
                thickness: context.knobs.double.slider(
                  label: 'Thickness',
                  initialValue: 2,
                  min: 1,
                  max: 8,
                  divisions: 7,
                ),
                head: head ? const DotSpinner() : null,
              ),
            ],
          );
        },
      ),
    ],
  ),
  WidgetbookComponent(
    name: 'Spinners',
    useCases: [
      WidgetbookUseCase(
        name: 'DotSpinner and DelayedSpinner',
        builder: (context) => const Stage(
          children: [
            Specimen('DotSpinner', child: Row(children: [DotSpinner()])),
            Specimen(
              'DelayedSpinner',
              note:
                  'Blank until Effects.spinnerThreshold passes. Switch use '
                  'cases and back to replay the wait.',
              child: DelayedSpinner(),
            ),
          ],
        ),
      ),
    ],
  ),
  WidgetbookComponent(
    name: 'ConnectionGlyph',
    useCases: [
      WidgetbookUseCase(
        name: 'Playground',
        builder: (context) => Stage(
          children: [
            Specimen(
              'Tap to send traffic',
              child: _Traffic(
                dedicated: context.knobs.boolean(label: 'Dedicated'),
              ),
            ),
          ],
        ),
      ),
    ],
  ),
  WidgetbookComponent(
    name: 'ScanSweep',
    useCases: [
      WidgetbookUseCase(
        name: 'Playground',
        builder: (context) {
          final tokens = context.tokens;
          return Stage(
            children: [
              ScanSweep(
                base: tokens.textMuted,
                lit:
                    context.tone(label: 'Lit', initial: Tone.accent) ??
                    tokens.textPrimary,
                child: Text(
                  context.label('CONNECTING TO OAK'),
                  style: tokens.panelHeader,
                ),
              ),
            ],
          );
        },
      ),
    ],
  ),
  WidgetbookComponent(
    name: 'SignalText',
    useCases: [
      WidgetbookUseCase(
        name: 'Playground',
        builder: (context) {
          final decode = context.knobs.boolean(
            label: 'Decode on entry',
            initialValue: true,
          );
          final smear = context.knobs.boolean(label: 'Smear on entry');
          final text = context.label('3 AGENTS WAITING');
          return Stage(
            children: [
              Specimen(
                'Edit the label to replay the entry',
                child: SignalText(
                  text,
                  key: ValueKey((text, decode, smear)),
                  style: context.tokens.screenTitle,
                  decodeOnEntry: decode,
                  smearOnEntry: smear,
                ),
              ),
            ],
          );
        },
      ),
    ],
  ),
];

class _Traffic extends StatefulWidget {
  const _Traffic({required this.dedicated});

  final bool dedicated;

  @override
  State<_Traffic> createState() => _TrafficState();
}

class _TrafficState extends State<_Traffic> {
  final _traffic = ValueNotifier(0);

  @override
  void dispose() {
    _traffic.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _traffic.value++,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Transform.scale(
          scale: 3,
          alignment: Alignment.centerLeft,
          child: ConnectionGlyph(
            dedicated: widget.dedicated,
            traffic: _traffic,
          ),
        ),
      ),
    );
  }
}
