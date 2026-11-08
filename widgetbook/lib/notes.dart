import 'package:flutter/material.dart';
import 'package:widgetbook/widgetbook.dart';

import 'package:upgrade/design/components/flash_block.dart';
import 'package:upgrade/design/components/inline_confirm.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/design/tokens.dart';

const _byName = {
  'playground': 'Try every option with the knobs on the right.',
  'states': 'Every state side by side.',
  'interactive': 'Tap it: this one works.',
};

final notes = {
  'foundations/colors': 'Every color the app paints with, and its hex value.',
  'foundations/colors/chrome':
      'Backgrounds, text, borders and accents of the app\'s own screens.',
  'foundations/colors/code-and-diff':
      'Syntax highlighting, and added or removed lines in diffs.',
  'foundations/colors/terminal':
      'The colors the terminal draws shell output in.',
  'foundations/typography': 'The text styles the app uses and their fonts.',
  'foundations/typography/roles': 'Each named text style, with a sample.',
  'foundations/typography/families': 'The fonts bundled with the app.',
  'foundations/geometry': 'Sizes shared by every screen.',
  'foundations/geometry/spacing': 'The steps used for gaps and padding.',
  'foundations/geometry/radii-and-borders':
      'Corner rounding and border widths.',
  'foundations/geometry/icon-sizes': 'The sizes an icon can be drawn at.',
  'foundations/geometry/shadows': 'Shadows under things that float.',
  'foundations/geometry/motion': 'How long animations take, and their curves.',
  'components/actions/actionblock':
      'The main button: a bordered block with an uppercase label. '
      'Used in forms and sheets.',
  'components/actions/solidactionbar':
      'Full-width filled button at the bottom of a form, like SAVE.',
  'components/actions/inlineconfirmblock':
      'A button that asks twice: the first tap arms it, a second tap within '
      '${inlineConfirmWindow.inSeconds} s does it. Used for deleting things.',
  'components/actions/flashactionblock':
      'A button whose label changes for ${flashWindow.inSeconds} s after it '
      'worked, like COPY becoming COPIED.',
  'components/actions/paneltextaction':
      'Small text-only action at the edge of a panel, like RETRY or EDIT.',
  'components/actions/toolbariconaction':
      'Icon button in a screen\'s top bar (Home, Hosts).',
  'components/actions/keycell':
      'One key of the strip above the phone keyboard in a shell '
      '(ESC, TAB, CTRL...).',
  'components/actions/keybar':
      'The row of extra keys above the phone keyboard in a shell or a '
      'mirrored screen.',
  'components/actions/keybar/shell-keys': 'The keys a shell session shows.',
  'components/actions/closetarget':
      'Drop zone shown while you drag a floating window (voice, device '
      'mirror). Drop it there to close it; it lights up when you are over it.',
  'components/rows/listrow':
      'The standard list row: title, subtitle, value on the right. '
      'Hosts, projects and keys are listed with it.',
  'components/rows/pickerrow':
      'A row you pick from a list, marked when chosen '
      '(project icon, files to send).',
  'components/rows/pickerrow/interactive-list': 'Tap rows to pick them.',
  'components/rows/prioritymark':
      'Roman numeral next to a task or project giving its priority '
      '(I, II, III). Low priority shows none.',
  'components/rows/labels': 'Small pieces of text used inside rows and panels.',
  'components/rows/labels/meta,-metarow,-bracketlabel,-statustag':
      'Meta: muted secondary text. MetaRow: label and value pairs. '
      'BracketLabel: a [ LABEL ] heading. StatusTag: a colored state word.',
  'components/rows/labels/itemline-and-pathline':
      'ItemLine: a one-line summary of an item. PathLine: a file path that '
      'drops its folders before its file name when it does not fit.',
  'components/containers/panel':
      'A bordered box grouping related things under a title. '
      'Most settings sections are panels.',
  'components/containers/panel/variants': 'Each kind of panel side by side.',
  'components/containers/segmentswitch':
      'Tabs inside a screen to switch between two or three views.',
  'components/containers/screenscaffold':
      'The frame of a detail or form screen: back button, title and a '
      'scrolling body.',
  'components/containers/asyncsection':
      'A section that shows loading, an error, or its content once the data '
      'arrives.',
  'components/containers/emptystate': 'What a list shows when it is empty.',
  'components/containers/panel-sheet':
      'The sheet that slides up from the bottom for choices and '
      'confirmations.',
  'components/containers/panel-sheet/body-with-footer':
      'Content with the buttons pinned at the bottom.',
  'components/containers/panel-sheet/confirm': 'A yes or no question.',
  'components/inputs/upgradefield':
      'Text input in the app\'s style (host form, search, prompt bar).',
  'components/inputs/fieldpanel': 'A labelled input box used in forms.',
  'components/inputs/choicepanel':
      'A labelled set of options where you pick one (project form).',
  'components/feedback/progressbar': 'Progress of a file upload or download.',
  'components/feedback/spinners':
      'DotSpinner: loading dots. DelayedSpinner: the same, shown only if the '
      'wait lasts, so quick loads do not flicker.',
  'components/feedback/spinners/dotspinner-and-delayedspinner':
      'Both spinners side by side.',
  'components/feedback/connectionglyph':
      'Small animated mark when you open a shell: whether it shares a '
      'connection or gets its own.',
  'components/feedback/scansweep':
      'A band of light sweeping across text while the shell header is '
      'connecting.',
  'components/feedback/signaltext':
      'Text that scrambles in like a decoding signal. Titles of panels and '
      'screens use it.',
  'components/graphics/upgradeicon': 'The app\'s icon set.',
  'components/graphics/asciimascot': 'The mascot, drawn in ASCII characters.',
  'components/graphics/asciimascot/all-states': 'Every mood of the mascot.',
  'components/graphics/ditherfield':
      'Dotted texture behind the composer and the boot screen.',
  'components/graphics/asciibackground':
      'Faint ASCII pattern behind the app\'s screens.',
  'components/graphics/asciibackground/static-surface':
      'As the app draws it behind a screen.',
  'assets/bundle':
      'Every image, icon, sprite and font the app ships. Search, filter, and '
      'tap one for its details.',
  'assets/bundle/gallery': 'All of them in one grid.',
  'screens/usage-panel':
      'Home card: how much of each AI agent\'s plan (Claude, Codex) is used, '
      'per host.',
  'screens/usage-panel/accounts': 'Several agents on several hosts.',
  'screens/usage-panel/single-account': 'One agent on one host.',
  'screens/usage-panel/empty': 'No usage reported yet.',
  'screens/host-key-sheet':
      'Asks you to trust a host the first time you connect to it over SSH.',
  'screens/host-key-sheet/new-key': 'A host never seen before.',
  'screens/host-key-sheet/changed-key':
      'The host\'s key differs from the one saved: it was reinstalled, or '
      'someone is in between.',
  'screens/hook-sheet':
      'Offers to add Upgrade\'s hooks to an agent\'s config on a host, so the '
      'app hears when the agent needs you.',
  'screens/hook-sheet/installed': 'Already in place.',
  'screens/hook-sheet/missing': 'Not there yet: INSTALL adds them.',
  'screens/hook-sheet/declared-by-nix':
      'The config is a read-only Nix file: it shows the lines to add by hand.',
  'screens/device-sheet':
      'Lists the Android emulators and iOS simulators on a host, to open one.',
  'screens/device-sheet/listed': 'Devices found.',
  'screens/device-sheet/no-stopped-devices': 'Every device is already running.',
  'screens/device-sheet/no-tools': 'The host has no emulator tooling.',
  'screens/device-sheet/host-unreachable': 'The host did not answer.',
  'screens/device-sheet/loading': 'Still asking the host.',
  'screens/link-preview-card':
      'Preview of a link saved in a task: title, site and description.',
  'screens/link-preview-card/variants': 'With full details, and URL only.',
  'screens/project-icon-picker': 'Grid to choose a project\'s icon.',
  'screens/diff-stat':
      'Lines added and removed in a change, as counts and a bar.',
  'plugins/board':
      'Board plugin: a whiteboard where you place notes and link them with '
      'lines. Ships with Upgrade.',
  'plugins/board/mounted': 'First open: no boards yet.',
  'plugins/board/empty-board': 'A new board with no notes.',
  'plugins/board/note-selected': 'Two notes, one selected and open to edit.',
  'plugins/board/linked': 'The link tool joined the two notes with a line.',
  'plugins/board/boards': 'The list of boards, to open, rename or delete.',
  'plugins/kanban':
      'Kanban plugin: your AI agent sessions on every host, as cards in '
      'columns.',
  'plugins/kanban/waiting': 'Before the sessions arrive.',
  'plugins/kanban/board':
      'Sessions from three hosts, one of them waiting for your approval.',
  'plugins/kanban/inbox-card':
      'The plugin\'s card on the home screen: a pending approval and the '
      'columns at a glance.',
  'plugins/agent-tasks':
      'Agent tasks plugin: have an AI agent (Codex, Claude) run a task on a '
      'host now, later or daily, even while your phone is off.',
  'plugins/agent-tasks/no-hosts': 'No host added yet.',
  'plugins/agent-tasks/unsupported':
      'The host cannot keep tasks running after you log out.',
  'plugins/agent-tasks/setup': 'Background tasks not turned on yet.',
  'plugins/agent-tasks/tasks': 'One daily task, with the host\'s controls.',
  'plugins/agent-tasks/composer': 'Writing a new task.',
};

class NotesAddon extends WidgetbookAddon<Object?> {
  NotesAddon() : super(name: 'Notes');

  @override
  List<Field> get fields => const [];

  @override
  Object? valueFromQueryGroup(Map<String, String> group) => null;

  @override
  Widget buildUseCase(BuildContext context, Widget child, Object? setting) {
    final useCase = WidgetbookState.of(context).useCase;
    final parent = useCase?.parent;
    final about = parent == null ? null : notes[parent.path];
    final state = useCase == null
        ? null
        : notes[useCase.path] ?? _byName[useCase.path.split('/').last];
    if (about == null && state == null) return child;
    final tokens = context.tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(Spacing.md),
          decoration: BoxDecoration(
            color: tokens.backgroundSecondary,
            border: Border(bottom: BorderSide(color: tokens.borderNormal)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (about != null)
                Text(
                  about,
                  style: tokens.prose.copyWith(color: tokens.textPrimary),
                ),
              if (state != null)
                Text(
                  '${useCase!.name}: $state',
                  style: tokens.prose.copyWith(color: tokens.textMuted),
                ),
            ],
          ),
        ),
        Expanded(child: child),
      ],
    );
  }
}
