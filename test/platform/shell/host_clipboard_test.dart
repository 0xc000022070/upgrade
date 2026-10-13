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

    test('macos reads the file as PNGf', () {
      expect(
        clipboardCommand(const HostClipboard(ClipboardBackend.macos), 'a.png'),
        contains('POSIX file \\"/tmp/upgrade/a.png\\"'),
      );
    });

    test('the upload makes the directory and writes stdin under it', () {
      expect(
        uploadCommand('a.png'),
        "sh -c 'mkdir -p '\\''/tmp/upgrade'\\'' && cat > "
        "'\\''/tmp/upgrade/a.png'\\'''",
      );
    });

    test('a quote in a path survives the quoting', () {
      expect(shellQuote("it's"), "'it'\\''s'");
    });
  });
}
