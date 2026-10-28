import 'package:flutter/widgets.dart';
import 'package:widgetbook/widgetbook.dart';

import 'package:striked/design/components/action_block.dart';
import 'package:striked/design/components/close_target.dart';
import 'package:striked/design/components/flash_block.dart';
import 'package:striked/design/components/inline_confirm.dart';
import 'package:striked/design/components/key_bar.dart';
import 'package:striked/design/components/key_cell.dart';
import 'package:striked/design/components/panel_text_action.dart';
import 'package:striked/design/components/solid_action_bar.dart';
import 'package:striked/design/components/toolbar_icon_action.dart';
import 'package:striked/design/icons/striked_icons.dart';
import 'package:striked/design/spacing.dart';
import 'package:striked/design/tokens.dart';

import 'package:striked_widgetbook/components/knobs.dart';
import 'package:striked_widgetbook/frame.dart';

final actionComponents = [
  WidgetbookComponent(
    name: 'ActionBlock',
    useCases: [
      WidgetbookUseCase(
        name: 'Playground',
        builder: (context) => Stage(
          children: [
            ActionBlock(
              label: context.label('Trust'),
              tone: context.tone(),
              filled: context.knobs.boolean(label: 'Filled'),
              onTap: context.tap(),
            ),
          ],
        ),
      ),
      WidgetbookUseCase(
        name: 'States',
        builder: (context) {
          final tokens = context.tokens;
          return Stage(
            children: [
              const Specimen(
                'Normal',
                child: ActionBlock(label: 'CANCEL', onTap: _noop),
              ),
              Specimen(
                'Primary',
                child: ActionBlock(
                  label: 'TRUST',
                  tone: tokens.accent,
                  filled: true,
                  onTap: _noop,
                ),
              ),
              Specimen(
                'Destructive',
                child: ActionBlock(
                  label: 'REPLACE',
                  tone: tokens.warning,
                  filled: true,
                  onTap: _noop,
                ),
              ),
              const Specimen(
                'Disabled',
                note:
                    'A null onTap. The block draws no disabled look of its '
                    'own; callers dim it with a muted tone.',
                child: ActionBlock(label: 'CANCEL', onTap: null),
              ),
              Specimen(
                'Pair',
                child: Row(
                  children: [
                    const Expanded(
                      child: ActionBlock(label: 'REJECT', onTap: _noop),
                    ),
                    const SizedBox(width: Spacing.md),
                    Expanded(
                      child: ActionBlock(
                        label: 'TRUST',
                        tone: tokens.accent,
                        filled: true,
                        onTap: _noop,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    ],
  ),
  WidgetbookComponent(
    name: 'SolidActionBar',
    useCases: [
      WidgetbookUseCase(
        name: 'Playground',
        builder: (context) => Stage(
          children: [
            SolidActionBar(
              label: context.label('Connect'),
              tone: context.tone(),
              enabled: context.knobs.boolean(
                label: 'Enabled',
                initialValue: true,
              ),
              onTap: _noop,
            ),
          ],
        ),
      ),
      WidgetbookUseCase(
        name: 'States',
        builder: (context) => Stage(
          children: [
            const Specimen(
              'Enabled',
              child: SolidActionBar(label: 'CONNECT', onTap: _noop),
            ),
            Specimen(
              'Warning',
              child: SolidActionBar(
                label: 'BOOT COLD',
                tone: context.tokens.warning,
                onTap: _noop,
              ),
            ),
            const Specimen(
              'Disabled',
              child: SolidActionBar(
                label: 'CONNECT',
                enabled: false,
                onTap: _noop,
              ),
            ),
          ],
        ),
      ),
    ],
  ),
  WidgetbookComponent(
    name: 'InlineConfirmBlock',
    useCases: [
      WidgetbookUseCase(
        name: 'Playground',
        builder: (context) => Stage(
          children: [
            Specimen(
              'Tap to arm, tap again to confirm',
              note: 'Disarms by itself after the window.',
              child: InlineConfirmBlock(
                label: context.label('Delete'),
                confirmLabel: context.label(
                  'Delete for good',
                  label: 'Confirm label',
                ),
                tone: context.tone(),
                armedTone: context.tone(
                  label: 'Armed tone',
                  initial: Tone.danger,
                ),
                compact: context.knobs.boolean(label: 'Compact'),
                window: Duration(
                  seconds: context.knobs.int.slider(
                    label: 'Window (s)',
                    initialValue: 3,
                    min: 1,
                    max: 10,
                  ),
                ),
                onConfirmed: _noop,
              ),
            ),
          ],
        ),
      ),
    ],
  ),
  WidgetbookComponent(
    name: 'FlashActionBlock',
    useCases: [
      WidgetbookUseCase(
        name: 'Playground',
        builder: (context) => Stage(
          children: [
            Specimen(
              'Tap: the label flips once the work lands',
              child: FlashActionBlock(
                label: context.label('Copy'),
                flashLabel: context.label('Copied', label: 'Flash label'),
                onTap: () => Future<void>.delayed(
                  Duration(
                    milliseconds: context.knobs.int.slider(
                      label: 'Work (ms)',
                      initialValue: 300,
                      max: 2000,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ],
  ),
  WidgetbookComponent(
    name: 'PanelTextAction',
    useCases: [
      WidgetbookUseCase(
        name: 'Playground',
        builder: (context) => Stage(
          children: [
            PanelTextAction(
              label: context.label('New'),
              icon: _icon(context, StrikedIcons.add),
              onTap: _noop,
            ),
          ],
        ),
      ),
    ],
  ),
  WidgetbookComponent(
    name: 'ToolbarIconAction',
    useCases: [
      WidgetbookUseCase(
        name: 'Playground',
        builder: (context) => Stage(
          children: [
            Specimen(
              'Press and hold to see the pressed state',
              child: Row(
                children: [
                  ToolbarIconAction(
                    label: context.label('Search'),
                    icon: _icon(context, StrikedIcons.search),
                    onTap: _noop,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ],
  ),
  WidgetbookComponent(
    name: 'KeyCell',
    useCases: [
      WidgetbookUseCase(
        name: 'Playground',
        builder: (context) => Stage(
          children: [
            Row(
              children: [
                KeyCell(
                  label: context.label('ESC'),
                  armed: context.knobs.boolean(label: 'Armed'),
                  locked: context.knobs.boolean(label: 'Locked'),
                  inert: context.knobs.boolean(label: 'Inert'),
                  repeat: context.knobs.int.slider(
                    label: 'Repeat',
                    initialValue: 1,
                    min: 1,
                    max: 9,
                  ),
                  onTap: _noop,
                ),
              ],
            ),
          ],
        ),
      ),
      WidgetbookUseCase(
        name: 'States',
        builder: (context) => Stage(
          children: [
            Specimen(
              'Normal · armed · locked · inert · repeated',
              note: 'Pressed is the cell\'s own state: press one.',
              child: Row(
                children: [
                  KeyCell(label: 'CTRL', onTap: _noop),
                  KeyCell(label: 'CTRL', armed: true, onTap: _noop),
                  KeyCell(label: 'CTRL', locked: true, onTap: _noop),
                  KeyCell(label: 'TAB', inert: true, onTap: _noop),
                  KeyCell(label: 'UP', repeat: 3, onTap: _noop),
                ],
              ),
            ),
          ],
        ),
      ),
    ],
  ),
  WidgetbookComponent(
    name: 'KeyBar',
    useCases: [
      WidgetbookUseCase(
        name: 'Shell keys',
        builder: (context) => Stage(
          children: [
            KeyBar(
              keys: [
                for (final key in const [
                  'ESC',
                  'TAB',
                  'CTRL',
                  'ALT',
                  '|',
                  '~',
                  '/',
                  '-',
                  'HOME',
                  'END',
                  'PGUP',
                  'PGDN',
                ])
                  KeyCell(label: key, onTap: _noop),
              ],
              pinned: [
                KeyCell(
                  label: 'KEYBOARD',
                  icon: StrikedIcons.keyboard,
                  onTap: _noop,
                ),
              ],
            ),
          ],
        ),
      ),
    ],
  ),
  WidgetbookComponent(
    name: 'CloseTarget',
    useCases: [
      WidgetbookUseCase(
        name: 'Playground',
        builder: (context) => Stage(
          children: [
            Specimen(
              'Hot is a drag held over it',
              child: SizedBox.square(
                dimension: TapTargets.minHeight,
                child: CloseTarget(hot: context.knobs.boolean(label: 'Hot')),
              ),
            ),
          ],
        ),
      ),
    ],
  ),
];

void _noop() {}

StrikedIcons _icon(BuildContext context, StrikedIcons initial) =>
    context.knobs.object.dropdown(
      label: 'Icon',
      options: StrikedIcons.values,
      initialOption: initial,
      labelBuilder: (icon) => icon.slug,
    );
