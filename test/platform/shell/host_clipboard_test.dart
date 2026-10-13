import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/platform/shell/host_clipboard.dart';
import 'package:upgrade/platform/shell/shell_connection.dart';

ExecResult printed(String stdout, {int exitCode = 0}) => ExecResult(
  exitCode: exitCode,
  stdout: Uint8List.fromList(utf8.encode(stdout)),
  stderr: Uint8List(0),
);

const _wayland = '''
os=Linux
runtime=/run/user/1000
wayland=wayland-1
display=:0
xauthority=
has=wl-copy
has=wl-paste
has=xclip
has=timeout
''';

void main() {
  group('the probe', () {
    test('a wlroots desktop reads WAYLAND with its socket carried', () {
      final clipboard = parseProbe(
        printed('${_wayland}watch=124\nwatcherror='),
      );
      expect(clipboard.backend, ClipboardBackend.wayland);
      expect(clipboard.environment, {
        'XDG_RUNTIME_DIR': '/run/user/1000',
        'WAYLAND_DISPLAY': 'wayland-1',
      });
      expect(clipboard.line, 'WAYLAND');
    });

    test('a compositor without data-control is NONE and says why', () {
      final clipboard = parseProbe(
        printed(
          '${_wayland}watch=1\nwatcherror=Watch mode requires a compositor '
          'that supports the data-control protocol',
        ),
      );
      expect(clipboard.backend, ClipboardBackend.none);
      expect(clipboard.line, 'NONE · compositor without data-control');
      expect(clipboardCommand(clipboard, 'a.png'), isNull);
    });

    test('wayland wins over the X display the same session also has', () {
      final clipboard = parseProbe(
        printed('${_wayland}watch=124\nwatcherror='),
      );
      expect(clipboard.backend, ClipboardBackend.wayland);
    });

    test('a wayland session missing wl-copy names the package', () {
      final probe = _wayland.replaceAll('has=wl-copy\n', '');
      expect(parseProbe(printed(probe)).line, 'NONE · no wl-copy');
    });

    test('an X session reads X11 with DISPLAY and XAUTHORITY carried', () {
      final clipboard = parseProbe(
        printed(
          'os=Linux\nruntime=/run/user/1000\nwayland=\ndisplay=:1\n'
          'xauthority=/home/u/.Xauthority\nhas=xclip\n',
        ),
      );
      expect(clipboard.backend, ClipboardBackend.x11);
      expect(clipboard.environment, {
        'DISPLAY': ':1',
        'XAUTHORITY': '/home/u/.Xauthority',
      });
    });

    test('a mac reads MACOS off osascript alone', () {
      final clipboard = parseProbe(printed('os=Darwin\nhas=osascript\n'));
      expect(clipboard.backend, ClipboardBackend.macos);
    });

    test('a headless box is NONE with no display server', () {
      final clipboard = parseProbe(
        printed('os=Linux\nruntime=/run/user/1000\nwayland=\ndisplay=\n'),
      );
      expect(clipboard.usable, isFalse);
      expect(clipboard.line, 'NONE · no display server');
    });

    test('a probe the host refused says the exit and the first line', () {
      expect(
        parseProbe(printed('', exitCode: 127)).line,
        'NONE · probe exit 127',
      );
      expect(
        parseProbe(
          ExecResult(
            exitCode: 1,
            stdout: Uint8List(0),
            stderr: Uint8List.fromList(
              utf8.encode('key not approved yet\nsee the admin\n'),
            ),
          ),
        ).line,
        'NONE · probe exit 1 · key not approved yet',
      );
      expect(
        parseProbe(
          ExecResult(
            exitCode: null,
            stdout: Uint8List(0),
            stderr: Uint8List(0),
          ),
        ).line,
        'NONE · probe exit ?',
      );
    });
  });

  group('the commands', () {
    test('wayland copies the file under the session it found', () {
      const clipboard = HostClipboard(
        ClipboardBackend.wayland,
        environment: {
          'XDG_RUNTIME_DIR': '/run/user/1000',
          'WAYLAND_DISPLAY': 'wayland-1',
        },
      );
      expect(
        clipboardCommand(clipboard, 'a.png'),
        "sh -c 'XDG_RUNTIME_DIR='\\''/run/user/1000'\\'' "
        "WAYLAND_DISPLAY='\\''wayland-1'\\'' wl-copy --type image/png "
        "< '\\''/tmp/upgrade/a.png'\\'' >/dev/null 2>&1'",
      );
    });

    test('x11 hands xclip the display', () {
      const clipboard = HostClipboard(
        ClipboardBackend.x11,
        environment: {'DISPLAY': ':0'},
      );
      expect(
        clipboardCommand(clipboard, 'a.png'),
        contains(
          "DISPLAY='\\'':0'\\'' xclip -selection clipboard -t image/png",
        ),
      );
    });

    String script(String? command) {
      expect(command, startsWith("sh -c '"));
      return command!
          .substring("sh -c '".length, command.length - 1)
          .replaceAll("'\\''", "'");
    }

    test('macos reads the file as PNGf', () {
      expect(
        script(
          clipboardCommand(const HostClipboard(ClipboardBackend.macos), 'a.png'),
        ),
        allOf(
          contains('«class PNGf»'),
          contains("'end run' '/tmp/upgrade/a.png' >"),
        ),
      );
    });

    test('macos hands the path to osascript as an argument', () {
      const path = '/tmp/a" & do shell script "id\' \$(id)';
      expect(
        script(
          clipboardImageCommand(
            const HostClipboard(ClipboardBackend.macos),
            path,
          ),
        ),
        contains("'end run' ${shellQuote(path)} >"),
      );
    });

    test('a jpeg goes on as a jpeg, and a type that is not one as a png', () {
      const clipboard = HostClipboard(ClipboardBackend.wayland);
      expect(
        clipboardImageCommand(clipboard, '/a.jpg', mime: 'image/jpeg'),
        contains('wl-copy --type image/jpeg'),
      );
      expect(
        clipboardImageCommand(clipboard, '/a', mime: "image/x; rm -rf ~"),
        contains('wl-copy --type image/png'),
      );
      expect(
        clipboardImageCommand(
          const HostClipboard(ClipboardBackend.macos),
          '/a.webp',
          mime: 'image/webp',
        ),
        isNull,
      );
    });

    test('text is read off stdin by each tool', () {
      expect(
        clipboardTextCommand(const HostClipboard(ClipboardBackend.wayland)),
        contains('wl-copy --type'),
      );
      expect(
        clipboardTextCommand(const HostClipboard(ClipboardBackend.x11)),
        contains('xclip -selection clipboard -i'),
      );
      expect(
        clipboardTextCommand(const HostClipboard(ClipboardBackend.macos)),
        contains('pbcopy'),
      );
      expect(
        clipboardTextCommand(const HostClipboard(ClipboardBackend.none)),
        isNull,
      );
    });

    test('a quote in a path survives the quoting', () {
      expect(shellQuote("it's"), "'it'\\''s'");
    });
  });
}
