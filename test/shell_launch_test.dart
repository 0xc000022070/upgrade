import 'dart:convert';

import 'package:dazzle/platform/shell/shell_launch.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a tag parses back to the launch that wrote it', () {
    expect(ShellLaunch.parse('tmux:work'), TmuxLaunch('work'));
    expect(ShellLaunch.parse('herdr:hub'), HerdrLaunch('hub'));
    expect(ShellLaunch.parse(TmuxLaunch('0').tag), TmuxLaunch('0'));
    final other = TmuxLaunch('drop', socket: '/tmp/tmux-1000/default');
    expect(other.tag, 'tmux:drop@/tmp/tmux-1000/default');
    expect(ShellLaunch.parse(other.tag), other);
    expect(ShellLaunch.parse('tmux:drop'), isNot(other));
  });

  test('a tag with a name that does not fit is no launch', () {
    expect(ShellLaunch.parse(null), isNull);
    expect(ShellLaunch.parse('tmux:a;rm -rf ~'), isNull);
    expect(ShellLaunch.parse("herdr:x'y"), isNull);
    expect(ShellLaunch.parse('screen:0'), isNull);
    expect(ShellLaunch.parse('tmux'), isNull);
    expect(ShellLaunch.parse("tmux:0@/tmp/x'y"), isNull);
    expect(ShellLaunch.parse('tmux:0@tmp/tmux-1000/default'), isNull);
    expect(() => TmuxLaunch('a b'), throwsArgumentError);
    expect(() => HerdrLaunch('a b'), throwsArgumentError);
  });

  test('tmux attaches or creates by name', () {
    expect(TmuxLaunch('work').command, "exec tmux new-session -A -s 'work'");
    expect(
      TmuxLaunch('drop', socket: '/tmp/tmux-1000/default').command,
      "mkdir -p -m 700 '/tmp/tmux-1000'; "
      "exec tmux -S '/tmp/tmux-1000/default' new-session -A -s 'drop'",
    );
    expect(
      TmuxLaunch('drop', socket: '/sock').command,
      "mkdir -p -m 700 '/'; exec tmux -S '/sock' new-session -A -s 'drop'",
    );
  });

  test('herdr attaches by session, the unnamed one without a flag', () {
    expect(HerdrLaunch('hub').command, "exec herdr --session 'hub'");
    expect(HerdrLaunch('default').command, 'exec herdr');
  });

  test('tmux sessions parse off list-sessions, odd names dropped', () {
    final entries = LaunchCommands.parseTmux(
      '\t0\t1\t1\n\twork\t3\t0\n\tbad.name\t1\t0\n'
      '/tmp/tmux-1000/default\tdrop\t1\t1\n'
      '/tmp/tmux-1000/default\tdrop\t1\t1\n'
      'tmp/x\tloose\t1\t0\n',
    );
    expect(
      [for (final e in entries) (e.name, e.windows, e.attached, e.socket)],
      [
        ('0', 1, 1, null),
        ('work', 3, 0, null),
        ('drop', 1, 1, '/tmp/tmux-1000/default'),
      ],
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
      ...utf8.encode('\tutf8'),
      0xff,
      ...utf8.encode('\t1\t0\n\twork\t2\t0\n'),
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
