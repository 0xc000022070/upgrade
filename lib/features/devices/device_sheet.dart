import 'dart:async';

import 'package:flutter/material.dart';

import 'package:upgrade/application/reason_lines.dart';
import 'package:upgrade/design/components/action_block.dart';
import 'package:upgrade/design/components/upgrade_field.dart';
import 'package:upgrade/design/components/inline_confirm.dart';
import 'package:upgrade/design/components/list_row.dart';
import 'package:upgrade/design/components/panel_sheet.dart';
import 'package:upgrade/design/components/panel_text_action.dart';
import 'package:upgrade/design/components/picker_row.dart';
import 'package:upgrade/design/components/segment_switch.dart';
import 'package:upgrade/design/components/solid_action_bar.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/platform/devices/device_link.dart';
import 'package:upgrade/features/devices/device_controllers.dart';

Future<void> showDeviceSheet(BuildContext context, DevicesController group) {
  final title = '${group.host.name.toUpperCase()} DEVICES';
  return showPanelSheet<void>(
    context,
    title: title,
    builder: (_) => _DeviceSheet(group: group, title: title),
  );
}

class _DeviceSheet extends StatefulWidget {
  const _DeviceSheet({required this.group, required this.title});

  final DevicesController group;
  final String title;

  @override
  State<_DeviceSheet> createState() => _DeviceSheetState();
}

class _DeviceSheetState extends State<_DeviceSheet> {
  StoppedListing? _listing;
  String? _failure;
  bool _making = false;
  StoppedDevice? _opened;
  final _deleting = <StoppedDevice>{};
  final _reasons = <StoppedDevice, String>{};
  int _attempt = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final attempt = ++_attempt;
    setState(() {
      _listing = null;
      _failure = null;
      _opened = null;
      _reasons.clear();
    });
    try {
      final listing = await widget.group.stopped();
      if (!mounted || attempt != _attempt) return;
      setState(() => _listing = listing);
    } catch (error) {
      if (!mounted || attempt != _attempt) return;
      setState(() => _failure = widget.group.reasonFor(error));
    }
  }

  void _boot(StoppedDevice device, {required bool cold}) {
    Navigator.of(context).pop();
    unawaited(widget.group.boot(device, cold: cold));
  }

  Future<void> _delete(StoppedDevice device) async {
    setState(() {
      _opened = null;
      _deleting.add(device);
      _reasons.remove(device);
    });
    final reason = await widget.group.deleteStopped(device);
    if (!mounted) return;
    setState(() => _deleting.remove(device));
    if (reason == null) return _load();
    setState(() => _reasons[device] = reason);
  }

  @override
  Widget build(BuildContext context) {
    final listing = _listing;
    return PanelSheetBody(
      key: const ValueKey('device-sheet'),
      title: widget.title,
      children: [
        if (_making && listing != null)
          _NewDevice(
            group: widget.group,
            tools: listing.tools,
            onCancel: () => setState(() => _making = false),
            onMade: () {
              setState(() => _making = false);
              unawaited(_load());
            },
          )
        else
          ..._list(context),
      ],
    );
  }

  List<Widget> _list(BuildContext context) {
    final tokens = context.tokens;
    final listing = _listing;
    final failure = _failure;
    if (failure != null) {
      return [ListRow(title: failure, titleColor: tokens.warning)];
    }
    if (listing == null) {
      return [ListRow(title: '…', titleColor: tokens.textDisabled)];
    }
    if (listing.tools.isEmpty) {
      return [
        ListRow(
          title: ReasonLine.noDeviceTools.words,
          titleColor: tokens.textDisabled,
        ),
      ];
    }
    return [
      if (listing.devices.isEmpty)
        ListRow(title: 'NONE', titleColor: tokens.textDisabled),
      for (final device in listing.devices) _row(context, device),
      const SizedBox(height: Spacing.md),
      PanelTextAction(
        key: const ValueKey('device-sheet-new'),
        label: 'NEW',
        onTap: () => setState(() => _making = true),
      ),
    ];
  }

  Widget _row(BuildContext context, StoppedDevice device) {
    final tokens = context.tokens;
    final deleting = _deleting.contains(device);
    final Widget trailing;
    if (deleting) {
      trailing = Text('…', style: tokens.rowTitle);
    } else if (_opened == device) {
      trailing = InlineConfirmBlock(
        key: ValueKey('device-delete-${device.id}'),
        label: 'DELETE',
        confirmLabel: 'CONFIRM DELETE',
        compact: true,
        onConfirmed: () => unawaited(_delete(device)),
      );
    } else {
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ActionBlock(
            key: ValueKey('device-boot-${device.id}'),
            label: 'BOOT',
            onTap: () => _boot(device, cold: false),
          ),
          const SizedBox(width: Spacing.sm),
          ActionBlock(
            key: ValueKey('device-cold-${device.id}'),
            label: 'COLD BOOT',
            onTap: () => _boot(device, cold: true),
          ),
        ],
      );
    }
    return ListRow(
      key: ValueKey('device-stopped-${device.id}'),
      title: device.name,
      literalTitle: true,
      titleMaxLines: 2,
      subtitle: _reasons[device],
      subtitleColor: tokens.warning,
      trailing: trailing,
      onLongPress: deleting
          ? null
          : () => setState(() => _opened = _opened == device ? null : device),
    );
  }
}

class _NewDevice extends StatefulWidget {
  const _NewDevice({
    required this.group,
    required this.tools,
    required this.onCancel,
    required this.onMade,
  });

  final DevicesController group;
  final Set<DeviceKind> tools;
  final VoidCallback onCancel;
  final VoidCallback onMade;

  @override
  State<_NewDevice> createState() => _NewDeviceState();
}

class _NewDeviceState extends State<_NewDevice> {
  late DeviceKind _kind = widget.tools.contains(DeviceKind.android)
      ? DeviceKind.android
      : DeviceKind.simulator;
  final _name = TextEditingController();
  DeviceCatalog? _catalog;
  String? _failure;
  CatalogEntry? _profile;
  CatalogEntry? _image;
  bool _creating = false;
  String? _reason;
  int _attempt = 0;

  bool get _android => _kind == DeviceKind.android;

  @override
  void initState() {
    super.initState();
    _name.addListener(_changed);
    unawaited(_load());
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _changed() => setState(() {});

  Future<void> _load() async {
    final attempt = ++_attempt;
    setState(() {
      _catalog = null;
      _failure = null;
      _profile = null;
      _image = null;
      _reason = null;
    });
    try {
      final catalog = await widget.group.catalog(_kind);
      if (!mounted || attempt != _attempt) return;
      setState(() {
        _catalog = catalog;
        final offered = catalog.offered;
        if (offered.length == 1) _profile = offered.single;
        _settleImage();
      });
    } catch (error) {
      if (!mounted || attempt != _attempt) return;
      setState(() => _failure = widget.group.reasonFor(error));
    }
  }

  void _settleImage() {
    final images = _catalog?.imagesFor(_profile?.id) ?? const [];
    if (!images.any((image) => image.id == _image?.id)) _image = null;
    if (_image == null && images.length == 1) _image = images.single;
  }

  bool get _named {
    final name = _name.text.trim();
    if (name.isEmpty) return false;
    return !_android || avdNamePattern.hasMatch(name);
  }

  bool get _ready => !_creating && _named && _profile != null && _image != null;

  Future<void> _create() async {
    final profile = _profile;
    final image = _image;
    if (!_ready || profile == null || image == null) return;
    setState(() {
      _creating = true;
      _reason = null;
    });
    final reason = await widget.group.create(
      NewDevice(
        kind: _kind,
        name: _name.text.trim(),
        profile: profile.id,
        image: image.id,
      ),
    );
    if (!mounted) return;
    if (reason == null) return widget.onMade();
    setState(() {
      _creating = false;
      _reason = reason;
    });
  }

  Future<void> _pick(
    String title,
    List<CatalogEntry> entries,
    CatalogEntry? current,
    void Function(CatalogEntry) onPick,
  ) async {
    FocusManager.instance.primaryFocus?.unfocus();
    final picked = await showPanelSheet<CatalogEntry>(
      context,
      title: title,
      builder: (context) => PanelSheetBody(
        title: title,
        children: [
          for (final entry in entries)
            PickerRow(
              key: ValueKey('device-pick-${entry.id}'),
              label: entry.name,
              selected: entry.id == current?.id,
              onTap: () => Navigator.of(context).pop(entry),
            ),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => onPick(picked));
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final both = widget.tools.length > 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (both) ...[
          SegmentSwitch(
            labels: const ['ANDROID', 'IOS'],
            currentIndex: _android ? 0 : 1,
            onSelected: (index) {
              final kind = index == 0
                  ? DeviceKind.android
                  : DeviceKind.simulator;
              if (kind == _kind) return;
              _kind = kind;
              unawaited(_load());
            },
          ),
          const SizedBox(height: Spacing.md),
        ],
        SheetField(
          label: 'NAME',
          child: UpgradeField(
            key: const ValueKey('device-new-name'),
            controller: _name,
            hint: _android ? 'Pixel_9' : 'iPhone 17',
          ),
        ),
        const SizedBox(height: Spacing.md),
        ..._choices(context),
        if (_reason case final reason?) ...[
          const SizedBox(height: Spacing.md),
          Text(reason, style: tokens.prose.copyWith(color: tokens.warning)),
        ],
        const SizedBox(height: Spacing.md),
        Row(
          children: [
            Expanded(
              child: ActionBlock(
                key: const ValueKey('device-new-cancel'),
                label: 'CANCEL',
                onTap: _creating ? null : widget.onCancel,
              ),
            ),
            if (_offersCreate) ...[
              const SizedBox(width: Spacing.md),
              Expanded(
                child: SolidActionBar(
                  key: const ValueKey('device-new-create'),
                  label: _creating ? '…' : 'CREATE',
                  enabled: _ready,
                  onTap: () => unawaited(_create()),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }

  bool get _offersCreate {
    final catalog = _catalog;
    return catalog != null &&
        catalog.available &&
        catalog.profiles.isNotEmpty &&
        catalog.images.isNotEmpty;
  }

  List<Widget> _choices(BuildContext context) {
    final tokens = context.tokens;
    final failure = _failure;
    if (failure != null) {
      return [
        Text(failure, style: tokens.prose.copyWith(color: tokens.warning)),
      ];
    }
    final catalog = _catalog;
    if (catalog == null) {
      return [ListRow(title: '…', titleColor: tokens.textDisabled)];
    }
    final missing = !catalog.available
        ? (_android ? ReasonLine.noAvdManager : ReasonLine.noDeviceTools)
        : catalog.images.isEmpty
        ? (_android ? ReasonLine.noSystemImage : ReasonLine.noRuntime)
        : null;
    if (missing != null) {
      return [
        Text(
          missing.words,
          style: tokens.prose.copyWith(color: tokens.warning),
        ),
      ];
    }
    final profileTitle = _android ? 'PROFILE' : 'DEVICE TYPE';
    final imageTitle = _android ? 'IMAGE' : 'RUNTIME';
    final profile = _profile;
    final image = _image;
    return [
      SheetField(
        label: profileTitle,
        child: PickerRow(
          key: const ValueKey('device-new-profile'),
          label: profile?.name ?? 'PICK',
          dim: profile == null,
          onTap: () => _pick(profileTitle, catalog.offered, profile, (entry) {
            _profile = entry;
            _settleImage();
          }),
        ),
      ),
      const SizedBox(height: Spacing.md),
      SheetField(
        label: imageTitle,
        child: PickerRow(
          key: const ValueKey('device-new-image'),
          label: image?.name ?? 'PICK',
          dim: image == null,
          onTap: () => _pick(
            imageTitle,
            catalog.imagesFor(profile?.id),
            image,
            (entry) => _image = entry,
          ),
        ),
      ),
    ];
  }
}
