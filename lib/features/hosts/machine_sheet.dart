import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/features/hosts/host_rows.dart';
import 'package:upgrade/application/phone_linux.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/design/components/panel_sheet.dart';

Future<void> showMachineSheet(BuildContext context, Host host) =>
    showPanelSheet<void>(
      context,
      title: host.name.toUpperCase(),
      builder: (context) => PanelSheetBody(
        title: host.name.toUpperCase(),
        children: [
          Consumer(
            builder: (context, ref, _) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                MetaRow('ADDRESS', '${host.address}:${host.port}'),
                LinkRow(host: host, outcome: null),
                if (ref.isPhoneLinux(host.id))
                  PhoneLinuxRow(host: host, system: false),
              ],
            ),
          ),
        ],
      ),
    );
