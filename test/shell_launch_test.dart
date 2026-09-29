import 'dart:convert';

import 'package:dazzle/platform/shell/shell_launch.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a tag parses back to the launch that wrote it', () {
    expect(ShellLaunch.parse('tmux:work'), TmuxLaunch('work'));
    expect(ShellLaunch.parse('herdr:hub'), HerdrLaunch('hub'));
    expect(ShellLaunch.parse(TmuxLaunch('0').tag), TmuxLaunch('0'));
  });

  test('a tag with a name that does not fit is no launch', () {
    expect(ShellLaunch.parse(null), isNull);
    expect(ShellLaunch.parse('tmux:a;rm -rf ~'), isNull);
    expect(ShellLaunch.parse("herdr:x'y"), isNull);
    expect(ShellLaunch.parse('screen:0'), isNull);
    expect(ShellLaunch.parse('tmux'), isNull);
    expect(() => TmuxLaunch('a b'), throwsArgumentError);
    expect(() => HerdrLaunch('a b'), throwsArgumentError);
  });

  test('tmux attaches or creates by name', () {
    expect(TmuxLaunch('work').command, "exec tmux new-session -A -s 'work'");
  });

  test('herdr attaches by session, the unnamed one without a flag', () {
    expect(HerdrLaunch('hub').command, "exec herdr --session 'hub'");
    expect(HerdrLaunch('default').command, 'exec herdr');
  });

  test('tmux sessions parse off list-sessions, odd names dropped', () {
    final entries = LaunchCommands.parseTmux(
      '0\t1\t1\nwork\t3\t0\nbad.name\t1\t0\n',
    );
    expect(
      [for (final e in entries) (e.name, e.windows, e.attached)],
      [('0', 1, 1), ('work', 3, 0)],
    );
    const targets = LaunchTargets(
      herdrSessions: [],
      workspaces: [],
      tmux: [
        TmuxSessionEntry(name: '0', windows: 1, attached: 1),
        TmuxSessionEntry(name: '1', windows: 1, attached: 0),
      ],
      hasHerdr: false,
      hasTmux: true,
    );
    expect(targets.nextTmuxName, '2');
  });

  test('a tmux name with bytes that are not UTF-8 is dropped, not thrown', () {
    final source = utf8.decode([
      ...utf8.encode('utf8'),
      0xff,
      ...utf8.encode('\t1\t0\nwork\t2\t0\n'),
    ], allowMalformed: true);
    expect(
      [for (final e in LaunchCommands.parseTmux(source)) e.name],
      ['work'],
    );
    expect(ShellLaunch.isTmuxName('utf8\u{FFFD}'), isFalse);
    expect(() => utf8.decode([0xff]), throwsFormatException);
  });

  test('herdr workspaces parse off workspace list', () {
    const source =
        '{"id":"cli:workspace:list","result":{"type":"workspace_list",'
        '"workspaces":[{"agent_status":"idle","focused":false,"label":"repbit",'
        '"workspace_id":"w1G"},{"agent_status":"working","focused":true,'
        '"label":"dazzle","workspace_id":"w1H"}]}}';
    final entries = LaunchCommands.parseWorkspaces('hub', source);
    expect(
      [
        for (final e in entries)
          (e.session, e.id, e.label, e.status, e.focused),
      ],
      [
        ('hub', 'w1G', 'repbit', 'idle', false),
        ('hub', 'w1H', 'dazzle', 'working', true),
      ],
    );
    expect(LaunchCommands.parseWorkspaces('hub', 'not json'), isEmpty);
  });
}
