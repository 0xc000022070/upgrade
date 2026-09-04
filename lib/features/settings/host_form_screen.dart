import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../app/static_surface.dart';
import '../../application/agents.dart';
import '../../application/formatting.dart';
import '../../application/providers.dart';
import '../../data/enums.dart';
import '../../data/repositories/host_repository.dart';
import '../../data/repositories/key_repository.dart';
import '../../data/repositories/path_repository.dart';
import '../../design/colors.dart';
import '../../design/components/action_block.dart';
import '../../design/components/field_panel.dart';
import '../../design/components/list_row.dart';
import '../../design/components/meta.dart';
import '../../design/components/panel.dart';
import '../../design/components/panel_sheet.dart';
import '../../design/components/picker_row.dart';
import '../../design/components/section.dart';
import '../../design/components/solid_action_bar.dart';
import '../../design/icons/hotline_icon.dart';
import '../../design/icons/hotline_icons.dart';
import '../../design/spacing.dart';
import '../../design/typography.dart';
import '../../platform/host_keys.dart';
import '../home/agent_mark.dart';
import '../screen/screen_preview.dart';
import '../screen_scaffold.dart';

void openHostForm(BuildContext context, {Host? host}) {
  Navigator.of(
    context,
    rootNavigator: true,
  ).push(MaterialPageRoute<void>(builder: (_) => HostFormScreen(host: host)));
}

class HostFormScreen extends ConsumerStatefulWidget {
  const HostFormScreen({super.key, this.host});

  final Host? host;

  @override
  ConsumerState<HostFormScreen> createState() => _HostFormScreenState();
}

/// What a new host is dialled on until the user says otherwise, and the value
/// the port field is measured against when the form asks whether it is dirty.
const _defaultPort = 22;

/// The kinds a path can name, in the order the editor's toggle draws them. The
/// marks are the same set: an agent the app cannot draw is one the gate does
/// not accept either.
final _agents = agentMarkKinds.toList();

class _HostFormScreenState extends ConsumerState<HostFormScreen> {
  late final TextEditingController _name;
  late final TextEditingController _address;
  late final TextEditingController _port;
  late final TextEditingController _user;
  String? _keyId;
  bool _submitting = false;

  /// The pin as the form found it, dropped in place when `FORGET KEY` is
  /// tapped. Not part of the draft the save writes: forgetting a key takes
  /// effect at once, because the reason to reach for it is a connection that is
  /// being refused right now.
  PinnedHostKey? _hostKey;

  /// Null until the host's rows are read back; an existing host must not have
  /// its integrations rewritten from a set that has not loaded yet.
  Set<IntegrationKind>? _integrations;

  /// What the form opened with. The form asks before dropping a draft, and the
  /// question is whether anything the *user* did is unsaved — so a key the form
  /// preselected on their behalf moves this baseline with it, and an untouched
  /// form on a one-key device still leaves without a word.
  String? _baseKeyId;
  Set<IntegrationKind>? _baseIntegrations;

  /// The paths block, edited as a draft. Nothing here reaches the database
  /// until the form is saved, which is what lets DISCARD take a path back out
  /// with the rest of the form. Null until an existing host's rows are read.
  List<AgentPath>? _paths;
  List<AgentPath>? _basePaths;

  /// The inline editor. Open with [_editingId] null is a path being added; open
  /// with an id is that row being edited in place.
  bool _editing = false;
  String? _editingId;
  late final TextEditingController _directory;
  late final TextEditingController _label;
  String _agent = _agents.first;

  /// Set before a pop that has already committed, so the back handler does not
  /// offer to discard what it has just written.
  bool _leaving = false;
  bool _asking = false;

  @override
  void initState() {
    super.initState();
    _hostKey = widget.host?.hostKey;
    final host = widget.host;
    _name = TextEditingController(text: host?.name ?? '');
    _address = TextEditingController(text: host?.address ?? '');
    // 22 is prefilled rather than left empty and defaulted on save, so
    // the field says which port the host will be dialled on before it is.
    _port = TextEditingController(text: '${host?.port ?? _defaultPort}');
    _user = TextEditingController(text: host?.user ?? '');
    _directory = TextEditingController();
    _label = TextEditingController();
    _keyId = host?.keyId;
    _baseKeyId = _keyId;
    if (host == null) {
      _integrations = <IntegrationKind>{};
      _baseIntegrations = <IntegrationKind>{};
      _paths = <AgentPath>[];
      _basePaths = <AgentPath>[];
      // One key is not a choice, and a picker holding a single row
      // reads as already chosen. The keys are a stream that has usually not
      // emitted by the time this runs, so the value present now is taken here
      // and every later one through the subscription; the first list holding
      // exactly one key preselects it, two or more preselect nothing.
      _preselect(ref.read(managedKeysProvider).valueOrNull);
      ref.listenManual(managedKeysProvider, (_, next) {
        final before = _keyId;
        _preselect(next.valueOrNull);
        if (_keyId != before) setState(() {});
      });
    } else {
      unawaited(_loadIntegrations(host.id));
      unawaited(_loadPaths(host.id));
    }
  }

  void _preselect(List<ManagedKey>? keys) {
    if (_keyId != null || keys == null || keys.length != 1) return;
    _keyId = keys.single.id;
    _baseKeyId = _keyId;
  }

  Future<void> _loadIntegrations(String hostId) async {
    final current = await ref.read(hostIntegrationsProvider(hostId).future);
    if (!mounted) return;
    setState(() {
      _integrations = current.toSet();
      _baseIntegrations = current.toSet();
    });
  }

  Future<void> _loadPaths(String hostId) async {
    final current = await ref.read(pathRepositoryProvider).listForHost(hostId);
    if (!mounted) return;
    setState(() {
      _paths = current.toList();
      _basePaths = current.toList();
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    _port.dispose();
    _user.dispose();
    _directory.dispose();
    _label.dispose();
    super.dispose();
  }

  /// In field order: the first part of the host that is not there yet.
  /// Null when there is none, which is the same thing as the form being valid.
  String? get _missing {
    if (_name.text.trim().isEmpty) return 'NAME MISSING';
    if (_address.text.trim().isEmpty) return 'ADDRESS MISSING';
    if (_parsedPort == null) return 'PORT MISSING';
    if (_user.text.trim().isEmpty) return 'USER MISSING';
    if (_keyId == null) return 'KEY MISSING';
    return null;
  }

  /// Empty, not a number, or outside the range a TCP port has. All
  /// three read as the same missing part, because the field is asking for one
  /// thing and none of the three is it.
  int? get _parsedPort {
    final port = int.tryParse(_port.text.trim());
    if (port == null || port < 1 || port > 65535) return null;
    return port;
  }

  bool get _valid => _missing == null;

  /// Anything the user would lose by leaving. Measured against the
  /// values the form opened with, so it reads the same for a new host — whose
  /// baseline is three empty fields — and for one being edited.
  bool get _dirty {
    final host = widget.host;
    if (_name.text.trim() != (host?.name ?? '')) return true;
    if (_address.text.trim() != (host?.address ?? '')) return true;
    // The port counts like any field, against the 22 the form filled in
    // rather than against an empty box, so an untouched new form is still clean.
    if (_port.text.trim() != '${host?.port ?? _defaultPort}') return true;
    if (_user.text.trim() != (host?.user ?? '')) return true;
    if (_keyId != _baseKeyId) return true;
    final base = _baseIntegrations;
    final current = _integrations;
    // An existing host's rows are still in flight until both of these are set,
    // and nothing has been changed against a baseline that has not landed.
    if (base == null || current == null) return false;
    if (!setEquals(base, current)) return true;
    // A directory typed into the editor and not yet added is unsaved work too:
    // what the question asks is what leaving would lose.
    if (_editing && _directory.text.trim().isNotEmpty) return true;
    final basePaths = _basePaths;
    final paths = _paths;
    if (basePaths == null || paths == null) return false;
    return !_samePaths(basePaths, paths);
  }

  /// Order counts, because it is the order the rows are drawn in. Ids are
  /// compared alongside the fields: a row replaced by another with the same
  /// directory is still a different path to anything pointing at it.
  bool _samePaths(List<AgentPath> a, List<AgentPath> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id ||
          a[i].directory != b[i].directory ||
          a[i].agent != b[i].agent ||
          a[i].label != b[i].label) {
        return false;
      }
    }
    return true;
  }

  void _openEditor([AgentPath? path]) {
    setState(() {
      _editing = true;
      _editingId = path?.id;
      _directory.text = path?.directory ?? '';
      _label.text = path?.label ?? '';
      _agent = path?.agent ?? _agents.first;
    });
  }

  void _closeEditor() {
    setState(() {
      _editing = false;
      _editingId = null;
      _directory.clear();
      _label.clear();
    });
  }

  void _commitEditor() {
    final directory = _directory.text.trim();
    final paths = _paths;
    if (directory.isEmpty || paths == null) return;
    final typed = _label.text.trim();
    // Never stored empty: an unnamed path takes the directory's last segment,
    // so every row and every sent line has a word to show.
    final label = typed.isEmpty ? defaultPathLabel(directory) : typed;
    final id = _editingId;
    setState(() {
      if (id == null) {
        paths.add(
          AgentPath(
            id: const Uuid().v4(),
            // Empty for a host that does not exist yet: the id arrives with the
            // save, and the repository files every row under the host it is
            // given rather than under the one the row remembers.
            hostId: widget.host?.id ?? '',
            directory: directory,
            agent: _agent,
            label: label,
            createdAt: DateTime.now(),
          ),
        );
      } else {
        final at = paths.indexWhere((path) => path.id == id);
        if (at >= 0) {
          paths[at] = paths[at].copyWith(
            directory: directory,
            agent: _agent,
            label: label,
          );
        }
      }
    });
    _closeEditor();
  }

  void _removePath(String id) {
    setState(() => _paths?.removeWhere((path) => path.id == id));
    if (_editingId == id) _closeEditor();
  }

  /// The back arrow and the system gesture are one door. [PopScope]
  /// holds the route so both arrive here and the pop is issued once, after the
  /// question when there is one to ask.
  Future<void> _handleBack() async {
    if (_asking) return;
    if (_leaving || !_dirty) {
      Navigator.of(context).pop();
      return;
    }
    _asking = true;
    final discard = await confirmSheet(
      context,
      title: 'DISCARD HOST?',
      confirmLabel: 'DISCARD',
    );
    _asking = false;
    if (discard && mounted) Navigator.of(context).pop();
  }

  Future<void> _submit() async {
    if (!_valid || _submitting) return;
    setState(() => _submitting = true);
    final host = Host(
      id: widget.host?.id ?? const Uuid().v4(),
      name: _name.text.trim(),
      address: _address.text.trim(),
      port: _parsedPort!,
      user: _user.text.trim(),
      keyId: _keyId!,
    );
    final hosts = ref.read(hostRepositoryProvider);
    await hosts.save(host);
    // A host is a machine and its integrations are rows beside it, so
    // the form writes both under one action. The switches are local until here
    // because a new host has no id to hang them on until it is saved.
    final integrations = _integrations;
    if (integrations != null) {
      for (final kind in IntegrationKind.values) {
        await hosts.setIntegration(host.id, kind, integrations.contains(kind));
      }
    }
    // Written whether or not HERDR is on. The block is hidden when it is off,
    // not emptied: switching it back on brings the same directories back
    // instead of asking for them again.
    final paths = _paths;
    if (paths != null) {
      await ref.read(pathRepositoryProvider).replaceForHost(host.id, paths);
    }
    if (mounted) {
      _leaving = true;
      Navigator.of(context).pop();
    }
  }

  Future<void> _delete() async {
    final host = widget.host;
    if (host == null) return;
    final confirmed = await confirmSheet(
      context,
      title: 'DELETE HOST?',
      confirmLabel: 'DELETE',
    );
    if (!confirmed || !mounted) return;
    await ref.read(hostRepositoryProvider).delete(host.id);
    if (!mounted) return;
    await _deletePreview(host.id);
    if (mounted) {
      _leaving = true;
      Navigator.of(context).pop();
    }
  }

  /// The host's stored frame goes with the host, or the tile it belongs to
  /// would outlive its host on the next screen that reads the directory. A
  /// store that will not open costs a stray file and nothing else, which is not
  /// a reason to leave the user on a form for a host that is already gone.
  Future<void> _deletePreview(String hostId) async {
    try {
      final previews = await ref.read(screenPreviewsProvider.future);
      await previews.delete(hostId);
    } catch (error) {
      debugPrint('hotline.vnc $hostId: preview not removed: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final keys = ref.watch(managedKeysProvider);
    final loaded = _integrations != null;
    final integrations = _integrations ?? <IntegrationKind>{};
    return PopScope(
      // Always false: whether this form may leave depends on text the fields
      // own, and a [canPop] read at build time is a keystroke behind. The
      // decision is taken in the callback instead, where it is current.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        unawaited(_handleBack());
      },
      child: Scaffold(
        resizeToAvoidBottomInset: true,
        body: StaticSurface(
          child: ScreenScaffold(
            title: widget.host == null ? 'NEW HOST' : 'HOST',
            breadcrumb: '/ HOTLINE / ACCESS',
            onBack: _handleBack,
            children: [
              PanelStack(
                children: [
                  FieldPanel(label: '[ NAME ]', controller: _name),
                  FieldPanel(label: '[ ADDRESS ]', controller: _address),
                  FieldPanel(
                    label: '[ PORT ]',
                    controller: _port,
                    keyboardType: TextInputType.number,
                  ),
                  FieldPanel(label: '[ USER ]', controller: _user),
                  Panel(
                    title: '[ KEY ]',
                    bodyPadding: panelRowsPadding,
                    // A form cannot ask for a key the device does not
                    // have. With none, the body is the one dim line an empty
                    // list gets anywhere else, and it says where one is made.
                    child: AsyncSection<List<ManagedKey>>(
                      value: keys,
                      empty: 'no keys · new + in sys',
                      builder: (items) => Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final key in items)
                            PickerRow(
                              label: key.name.toUpperCase(),
                              subtitle: key.fingerprint,
                              selected: key.id == _keyId,
                              onTap: () => setState(() => _keyId = key.id),
                            ),
                        ],
                      ),
                    ),
                  ),
                  Panel(
                    title: '[ INTEGRATIONS ]',
                    bodyPadding: panelRowsPadding,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // The active value is the solid block, so an
                        // integration that is on is the accent row and one that
                        // is off is a plain row reading OFF. VNC came in as an
                        // enum value and nothing here moved, which is the point
                        // of the loop.
                        for (final kind in IntegrationKind.values)
                          PickerRow(
                            label: kind.label,
                            value: 'OFF',
                            selected: integrations.contains(kind),
                            onTap: loaded
                                ? () => setState(() {
                                    if (!integrations.remove(kind)) {
                                      integrations.add(kind);
                                    }
                                  })
                                : () {},
                          ),
                      ],
                    ),
                  ),
                  if (_hostKey != null) _hostKeyPanel(_hostKey!),
                  if (integrations.contains(IntegrationKind.herdr))
                    _pathsPanel(),
                ],
              ),
              const SizedBox(height: Spacing.xl),
              ListenableBuilder(
                listenable: Listenable.merge([_name, _address, _port, _user]),
                builder: (context, _) {
                  // The bar is always drawn. Invalid, it names the part
                  // that is missing and does nothing when tapped.
                  final missing = _missing;
                  return SolidActionBar(
                    label:
                        missing ??
                        (widget.host == null ? 'CREATE HOST' : 'SAVE'),
                    enabled: missing == null,
                    onTap: _submit,
                  );
                },
              ),
              if (widget.host != null) ...[
                const SizedBox(height: Spacing.md),
                SolidActionBar(
                  label: 'DELETE HOST',
                  tone: HotlineColors.warning,
                  onTap: _delete,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// What the app checks the machine against on every dial, and the one way
  /// out of a refusal. Drawn only for a host that has pinned something: there
  /// is nothing to say about a host that has never connected.
  Widget _hostKeyPanel(PinnedHostKey key) {
    return Panel(
      title: '[ HOST KEY ]',
      bodyPadding: panelRowsPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _KeyMetaRow('TYPE', key.type.toUpperCase()),
          _KeyMetaRow('FINGERPRINT', key.fingerprint, maxLines: 3),
          _KeyMetaRow('PINNED', relativeAge(key.pinnedAt.toUtc())),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
            child: Align(
              alignment: Alignment.centerLeft,
              child: ActionBlock(
                label: 'FORGET KEY',
                tone: HotlineColors.warning,
                onTap: _forgetHostKey,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Drops the pin and lets the next connection trust whatever answers. Asked
  /// about because the answer to a changed key is either this or a machine in
  /// the middle, and only the user knows which.
  Future<void> _forgetHostKey() async {
    final host = widget.host;
    if (host == null) return;
    final confirmed = await confirmSheet(
      context,
      title: 'FORGET HOST KEY?',
      confirmLabel: 'FORGET',
    );
    if (!confirmed || !mounted) return;
    await ref.read(hostRepositoryProvider).forgetHostKey(host.id);
    if (mounted) setState(() => _hostKey = null);
  }

  /// Drawn only while HERDR is on: a path exists to be sent to, and the send is
  /// what the integration is. The rows survive the switch going off — they are
  /// hidden, not dropped.
  ///
  /// The editor takes the last slot in the same group as the rows, so the rule
  /// above it is the one that separates any two rows and the block reads as one
  /// list that grows a form at the bottom.
  Widget _pathsPanel() {
    final paths = _paths ?? const <AgentPath>[];
    return Panel(
      title: '[ PATHS ]',
      bodyPadding: panelRowsPadding,
      child: ListRowGroup(
        children: [
          for (final path in paths)
            ListRow(
              leading: AgentMark(path.agent),
              leadingWidth: AgentMark.markBox,
              title: path.label.toUpperCase(),
              subtitle: path.directory,
              trailing: _RemoveAction(onTap: () => _removePath(path.id)),
              onTap: () => _openEditor(path),
            ),
          if (_editing) _editor() else _AddAction(onTap: _openEditor),
        ],
      ),
    );
  }

  Widget _editor() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Spacing.md),
      child: ListenableBuilder(
        // The label's hint is the directory's last segment, so it follows the
        // field above it as it is typed, and the confirm block turns on the
        // moment there is a directory to confirm.
        listenable: _directory,
        builder: (context, _) {
          final directory = _directory.text.trim();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _EditorField(
                label: 'DIRECTORY',
                controller: _directory,
                hint: '~/src/project',
                autofocus: true,
              ),
              const SizedBox(height: Spacing.lg),
              const Text('AGENT', style: HotlineText.panelHeader),
              const SizedBox(height: Spacing.sm),
              Row(
                children: [
                  for (final kind in _agents) ...[
                    if (kind != _agents.first)
                      const SizedBox(width: Spacing.md),
                    Expanded(
                      child: ActionBlock(
                        label: agentMarkName(kind),
                        filled: kind == _agent,
                        tone: kind == _agent
                            ? HotlineColors.accent
                            : HotlineColors.textSecondary,
                        onTap: () => setState(() => _agent = kind),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: Spacing.lg),
              _EditorField(
                label: 'LABEL',
                controller: _label,
                hint: directory.isEmpty
                    ? 'optional'
                    : defaultPathLabel(directory),
              ),
              const SizedBox(height: Spacing.lg),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  ActionBlock(label: 'CANCEL', onTap: _closeEditor),
                  const SizedBox(width: Spacing.md),
                  ActionBlock(
                    label: _editingId == null ? 'ADD' : 'SAVE PATH',
                    filled: directory.isNotEmpty,
                    tone: directory.isEmpty
                        ? HotlineColors.textDisabled
                        : HotlineColors.accent,
                    onTap: _commitEditor,
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

/// One field of the inline editor: the same box [FieldPanel] draws, without the
/// panel around it. A panel per field inside a panel would put a border inside
/// a border, and the editor is one block of the paths list rather than three
/// sections of the form.
class _EditorField extends StatelessWidget {
  const _EditorField({
    required this.label,
    required this.controller,
    this.hint = '',
    this.autofocus = false,
  });

  final String label;
  final TextEditingController controller;
  final String hint;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: HotlineText.panelHeader),
        TextField(
          controller: controller,
          autofocus: autofocus,
          maxLines: 1,
          style: HotlineText.rowTitle,
          cursorColor: HotlineColors.accent,
          cursorWidth: 2,
          cursorRadius: Radius.zero,
          textInputAction: TextInputAction.next,
          decoration: InputDecoration(
            isDense: true,
            border: InputBorder.none,
            contentPadding: const EdgeInsets.symmetric(vertical: Spacing.md),
            hintText: hint,
            hintStyle: HotlineText.rowSubtitle,
          ),
        ),
      ],
    );
  }
}

/// The `×` at a path row's right edge. Its own recognizer inside the row's, so
/// a tap here removes the path where a tap anywhere else opens it.
class _RemoveAction extends StatelessWidget {
  const _RemoveAction({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: TapTargets.minHeight,
        height: TapTargets.minHeight,
        child: Center(
          child: Text(
            '×',
            style: HotlineText.valueStrong.copyWith(
              color: HotlineColors.textMuted,
            ),
          ),
        ),
      ),
    );
  }
}

/// The last row of the paths block. A text action and not a header affordance:
/// the panel's header strip already carries the block's name, and the row sits
/// where the next path will appear.
class _AddAction extends StatelessWidget {
  const _AddAction({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: const SizedBox(
        height: TapTargets.minHeight,
        child: Row(
          children: [
            HotlineIcon(
              HotlineIcons.add,
              size: IconSizes.affordance,
              color: HotlineColors.textMuted,
            ),
            SizedBox(width: Spacing.sm),
            Text('ADD PATH', style: HotlineText.panelHeader),
          ],
        ),
      ),
    );
  }
}

/// The host form's read-only line: a label and a mono value, the shape ACCESS
/// draws a host's metadata in.
class _KeyMetaRow extends StatelessWidget {
  const _KeyMetaRow(this.label, this.value, {this.maxLines = 1});

  final String label;
  final String value;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 108, child: Text(label, style: HotlineText.label)),
          Expanded(child: Meta(value, maxLines: maxLines)),
        ],
      ),
    );
  }
}
