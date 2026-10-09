import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:flutter_test/flutter_test.dart';

const _supervisor = 'lib/platform/ssh/connection_supervisor.dart';
const _reasons = 'lib/platform/ssh/reasons.dart';
const _hostLinks = 'lib/platform/host_links.dart';
const _shellScreen = 'lib/features/shell/host_shell_screen.dart';
const _shellSheet = 'lib/features/shell/shell_sheet.dart';

const _seam =
    "a new call site needs the owner's approval before it joins this list";

const _gestures = {'onGesture', 'onGestureWith'};

const _wrappers = {
  'UserIntent': {..._gestures, 'onNotificationTap'},
  'PlatformSignal': {'onLaunch', 'onLifecycle', 'onNetwork'},
};

const _lifecycles = {'appVisibleProvider', 'appForegroundProvider'};

const _carriers = {
  'lib/features/shell/shell_sessions.dart': {'ShellSessions._leftOn'},
  _shellScreen: {'HostShellRoute.intent'},
  _shellSheet: {
    'ShellSheetRoute.intent',
    '_SheetContents.intent',
    '_SheetContentsState._intent',
  },
};

final _driven = RegExp(r'^(state|didChangeAppLifecycleState|override\w*)$');
final _handlerName = RegExp(r'^on[A-Z]\w*$');
final _typeName = RegExp(r'^_*[A-Z]');

CompilationUnit _parse(String path, String source) =>
    parseString(content: source, path: path).unit;

final Map<String, CompilationUnit> _lib = {
  for (final file in Directory('lib').listSync(recursive: true))
    if (file is File && file.path.endsWith('.dart'))
      file.path: _parse(file.path, file.readAsStringSync()),
};

final Set<String> _sshLibrary = {
  _supervisor,
  for (final part in _lib[_supervisor]!.directives.whereType<PartDirective>())
    '${File(_supervisor).parent.path}/${part.uri.stringValue}',
};

String _at(String path, AstNode node) {
  final unit = node.root as CompilationUnit;
  return '$path:${unit.lineInfo.getLocation(node.offset).lineNumber}: '
      '${node.toSource()}';
}

class _Code extends GeneralizingAstVisitor<void> {
  _Code(this.onNode);

  final void Function(AstNode node) onNode;

  @override
  void visitComment(Comment node) {}

  @override
  void visitNode(AstNode node) {
    onNode(node);
    super.visitNode(node);
  }
}

void _walk(CompilationUnit unit, void Function(AstNode node) onNode) =>
    unit.accept(_Code(onNode));

typedef MintScan = ({List<String> violations, Map<String, int> mints});

MintScan scanMints(
  String path,
  CompilationUnit unit, {
  bool inLibrary = false,
}) {
  final violations = <String>[];
  final mints = <String, int>{};
  _walk(unit, (node) {
    if (node is SimpleIdentifier &&
        node.thisOrAncestorOfType<Combinator>() == null &&
        node.parent is! ConstructorDeclaration) {
      final name = node.name;
      final wrappers = _wrappers[name];
      final parent = node.parent;
      if (inLibrary) {
        if (wrappers != null && !_privateMint(path, node, wrappers)) {
          violations.add(
            '${_at(path, parent ?? node)} ($name outside a wrapper)',
          );
        }
      } else if (name == 'ShellEnded') {
        violations.add(
          '${_at(path, parent ?? node)} (ShellEnded is the library\'s)',
        );
      } else if (wrappers != null) {
        if (parent is MethodInvocation &&
            identical(parent.target, node) &&
            wrappers.contains(parent.methodName.name)) {
          final wrapper = parent.methodName.name;
          mints[wrapper] = (mints[wrapper] ?? 0) + 1;
          if (!_inSlot(path, wrapper, parent)) {
            violations.add('${_at(path, parent)} ($wrapper outside its slot)');
          }
        } else {
          violations.add('${_at(path, parent ?? node)} ($name not called)');
        }
      }
    }
    if (_member(node) case (final name, final target)) {
      final owner = _wrappers.entries
          .where((entry) => entry.value.contains(name))
          .map((entry) => entry.key)
          .firstOrNull;
      final direct =
          node is MethodInvocation &&
          target is SimpleIdentifier &&
          target.name == owner;
      if (owner != null && !direct) {
        violations.add('${_at(path, node)} ($name off something not $owner)');
      }
    }
  });
  return (violations: violations, mints: mints);
}

bool _privateMint(String path, SimpleIdentifier node, Set<String> wrappers) {
  final call = node.parent;
  final method = node.thisOrAncestorOfType<MethodDeclaration>();
  final owner = node.thisOrAncestorOfType<ClassDeclaration>();
  return path == _reasons &&
      call is MethodInvocation &&
      identical(call.target, node) &&
      call.methodName.name == '_' &&
      method != null &&
      wrappers.contains(method.name.lexeme) &&
      owner?.namePart.typeName.lexeme == node.name;
}

bool _inSlot(String path, String wrapper, MethodInvocation call) {
  final parent = call.parent;
  switch (wrapper) {
    case 'onGesture' || 'onGestureWith':
      return _handlerSlot(call);
    case 'onNotificationTap':
      return parent is NamedArgument &&
          parent.name.lexeme == 'onResponse' &&
          _calls(parent.parent?.parent, 'AlertNotifications', 'initialize');
    case 'onLaunch':
      final body = parent;
      final function = body?.parent?.parent;
      return path == 'lib/main.dart' &&
          body is ExpressionFunctionBody &&
          function is FunctionDeclaration &&
          function.name.lexeme == 'main' &&
          function.parent is CompilationUnit;
    case 'onLifecycle':
      final listen = parent?.parent;
      if (parent is! ArgumentList || !_calls(listen, 'ref', 'listen')) {
        return false;
      }
      final arguments = parent.arguments;
      final provider = arguments.first;
      return arguments.length == 2 &&
          identical(arguments.last, call) &&
          provider is SimpleIdentifier &&
          _lifecycles.contains(provider.name);
    case 'onNetwork':
      final listen = parent?.parent;
      return parent is ArgumentList &&
          parent.arguments.length == 1 &&
          listen is MethodInvocation &&
          listen.methodName.name == 'listen' &&
          _calls(listen.target, 'Device', 'networkChanges');
  }
  return false;
}

bool _calls(AstNode? node, String target, String method) => switch (node) {
  MethodInvocation(:final methodName, target: SimpleIdentifier(:final name)) =>
    methodName.name == method && name == target,
  _ => false,
};

(String, Expression?)? _member(AstNode node) => switch (node) {
  MethodInvocation(:final methodName, :final target) => (
    methodName.name,
    target,
  ),
  PropertyAccess(:final propertyName, :final target) => (
    propertyName.name,
    target,
  ),
  PrefixedIdentifier(:final identifier, :final prefix) => (
    identifier.name,
    prefix,
  ),
  _ => null,
};

bool _handlerSlot(MethodInvocation call) {
  Expression node = call;
  var parent = node.parent;
  while (parent is ParenthesizedExpression ||
      parent is ConditionalExpression && !identical(parent.condition, node)) {
    node = parent as Expression;
    parent = node.parent;
  }
  if (parent is! NamedArgument || !_handlerName.hasMatch(parent.name.lexeme)) {
    return false;
  }
  return switch (parent.parent?.parent) {
    InstanceCreationExpression() => true,
    MethodInvocation(target: null, :final methodName) => _typeName.hasMatch(
      methodName.name,
    ),
    _ => false,
  };
}

Set<String> tokenFields(CompilationUnit unit) {
  final found = <String>{};
  _walk(unit, (node) {
    final (VariableDeclarationList? list, String owner) = switch (node) {
      FieldDeclaration(:final fields) => (
        fields,
        node
                .thisOrAncestorOfType<ClassDeclaration>()
                ?.namePart
                .typeName
                .lexeme ??
            '?',
      ),
      TopLevelVariableDeclaration(:final variables) => (variables, '<top>'),
      _ => (null, ''),
    };
    if (list == null || !_namesToken(list.type)) return;
    for (final variable in list.variables) {
      found.add('$owner.${variable.name.lexeme}');
    }
  });
  return found;
}

bool _namesToken(TypeAnnotation? type) {
  var named = false;
  type?.accept(
    _Code((node) {
      if (node is NamedType &&
          _wrappers.containsKey(node.name.lexeme) &&
          node.thisOrAncestorOfType<GenericFunctionType>() == null) {
        named = true;
      }
    }),
  );
  return named;
}

int fieldReads(CompilationUnit unit, String carrier) {
  final [owner, field] = carrier.split('.');
  var reads = 0;
  _walk(unit, (node) {
    final inside = node.thisOrAncestorOfType<ClassDeclaration>();
    final within = inside?.namePart.typeName.lexeme == owner;
    final state = _supertypeNames(inside).contains(owner);
    switch (node) {
      case PrefixedIdentifier(
            prefix: SimpleIdentifier(name: 'widget'),
            :final identifier,
          )
          when state && identifier.name == field:
        reads++;
      case PropertyAccess(:final target, :final propertyName)
          when propertyName.name == field &&
              (within && target is ThisExpression ||
                  state &&
                      target is SimpleIdentifier &&
                      target.name == 'widget'):
        reads++;
      case SimpleIdentifier(:final name, :final parent)
          when within &&
              name == field &&
              parent is! PrefixedIdentifier &&
              parent is! PropertyAccess &&
              !(parent is AssignmentExpression &&
                  identical(parent.leftHandSide, node)):
        reads++;
    }
  });
  return reads;
}

Set<String> _supertypeNames(ClassDeclaration? declaration) {
  final names = <String>{};
  declaration?.extendsClause?.accept(
    _Code((node) {
      if (node is NamedType) names.add(node.name.lexeme);
    }),
  );
  return names;
}

List<String> carrierViolations(
  Map<String, CompilationUnit> units,
  Map<String, Set<String>> allowed,
) => [
  for (final MapEntry(key: path, value: unit) in units.entries) ...[
    for (final field in tokenFields(unit))
      if (!(allowed[path]?.contains(field) ?? false))
        '$path: $field holds a token',
    for (final field in allowed[path] ?? const <String>{})
      if (!tokenFields(unit).contains(field))
        '$path: $field is gone'
      else if (fieldReads(unit, field) case final reads when reads != 1)
        '$path: $field read $reads times',
  ],
];

Map<String, int> _members(
  bool Function(String name, Expression? target, AstNode node) match, {
  String? except,
}) {
  final found = <String, int>{};
  for (final MapEntry(key: path, value: unit) in _lib.entries) {
    if (path == except || path == _reasons) continue;
    _walk(unit, (node) {
      if (_member(node) case (final name, final target)
          when match(name, target, node)) {
        found[path] = (found[path] ?? 0) + 1;
      }
    });
  }
  return found;
}

bool Function(String, Expression?, AstNode) _named(String member) =>
    (name, _, _) => name == member;

String? _lastName(Expression? target) => switch (target) {
  SimpleIdentifier(:final name) => name,
  PrefixedIdentifier(:final identifier) => identifier.name,
  PropertyAccess(:final propertyName) => propertyName.name,
  _ => null,
};

MintScan _scanSnippet(String source, {String path = 'lib/snippet.dart'}) =>
    scanMints(path, _parse(path, source));

void main() {
  test('the ssh library is the supervisor and its parts', () {
    expect(_sshLibrary, {
      _supervisor,
      'lib/platform/ssh/exec.dart',
      _reasons,
      'lib/platform/ssh/ssh_host.dart',
    }, reason: "a new part needs the owner's approval");
  });

  group('reason tokens', () {
    test('are minted only through a wrapper, in the slot it is for', () {
      final violations = <String>[];
      final mints = <String, Map<String, int>>{};
      for (final MapEntry(key: path, value: unit) in _lib.entries) {
        final scan = scanMints(
          path,
          unit,
          inLibrary: _sshLibrary.contains(path),
        );
        violations.addAll(scan.violations);
        for (final MapEntry(key: wrapper, value: count) in scan.mints.entries) {
          (mints[wrapper] ??= {})[path] = count;
        }
      }
      expect(violations, isEmpty);
      expect(mints, {
        'onGesture': {
          'lib/features/agents/agent_chat_screen.dart': 1,
          'lib/features/agents/agents_screen.dart': 2,
          'lib/features/code/workspace_sheet.dart': 1,
          'lib/features/home/agents_panel.dart': 1,
          'lib/features/hosts/hosts_screen.dart': 2,
          'lib/features/shell/attach_sheet.dart': 2,
          _shellScreen: 5,
          'lib/features/shell/parked_shell_bar.dart': 1,
          'lib/features/shell/shell_card.dart': 1,
        },
        'onGestureWith': {_shellScreen: 2},
        'onNotificationTap': {'lib/app/alerts_boot.dart': 1},
        'onLaunch': {'lib/main.dart': 1},
        'onLifecycle': {'lib/features/shell/shell_wake.dart': 2},
        'onNetwork': {'lib/features/shell/shell_wake.dart': 1},
      }, reason: 'mint where a gesture or the platform calls in; $_seam');
    });

    test('ride only in the landing fields, each read once', () {
      final outside = {
        for (final entry in _lib.entries)
          if (!_sshLibrary.contains(entry.key)) entry.key: entry.value,
      };
      expect(
        carrierViolations(outside, _carriers),
        isEmpty,
        reason: 'pass a token as a parameter; a stored one can be spent twice',
      );
    });

    test('the lifecycle readings change only from the binding', () {
      final writes = <String>[];
      for (final MapEntry(key: path, value: unit) in _lib.entries) {
        _walk(unit, (node) {
          final inside = node.thisOrAncestorOfType<ClassDeclaration>();
          if (node is AssignmentExpression &&
              inside?.namePart.typeName.lexeme == 'AppLifecycleReading' &&
              node.thisOrAncestorOfType<MethodDeclaration>()?.name.lexeme !=
                  'didChangeAppLifecycleState') {
            writes.add(_at(path, node));
          }
          if (_member(node) case (final name, final target?)
              when _driven.hasMatch(name) &&
                  _lifecycles.any(target.toSource().contains)) {
            writes.add(_at(path, node));
          }
        });
      }
      expect(
        writes,
        isEmpty,
        reason: 'a lifecycle reading mints a PlatformSignal on every change',
      );
    });

    group('the fence', () {
      void rejects(String source, {String path = 'lib/snippet.dart'}) => expect(
        _scanSnippet(source, path: path).violations,
        isNotEmpty,
        reason: source,
      );

      void accepts(String source, {String path = 'lib/snippet.dart'}) => expect(
        _scanSnippet(source, path: path).violations,
        isEmpty,
        reason: source,
      );

      test('passes a callback handed to a widget', () {
        accepts('''
Widget a() => Block(onTap: UserIntent.onGesture((intent) => go(intent)));
Widget b() => const Row(onPick: UserIntent.onGestureWith(pick));
Widget c(bool on) => Block(onTap: on ? null : (UserIntent.onGesture(go)));
Widget d() => _Row(onTap: UserIntent.onGesture(go));
''');
      });

      test('passes the platform registrations', () {
        accepts(
          'Future<void> main() => PlatformSignal.onLaunch(boot);',
          path: 'lib/main.dart',
        );
        accepts('''
void build() {
  ref.listen<bool>(appVisibleProvider, PlatformSignal.onLifecycle(left));
  Device.networkChanges().listen(PlatformSignal.onNetwork(arrived));
  AlertNotifications.initialize(onResponse: UserIntent.onNotificationTap(tap));
}
''');
      });

      test('rejects a callback invoked on the spot', () {
        rejects('void f() => UserIntent.onGesture((intent) {})();');
        rejects('void f() { UserIntent.onGesture(go)(); }');
      });

      test('rejects a callback stored or returned', () {
        rejects('final tap = UserIntent.onGesture(go);');
        rejects('class A { late final tap = UserIntent.onGesture(go); }');
        rejects('void f() { final tap = UserIntent.onGesture(go); }');
        rejects('VoidCallback f() => UserIntent.onGesture(go);');
        rejects('VoidCallback f() { return UserIntent.onGesture(go); }');
      });

      test('rejects a callback in any other argument', () {
        rejects('Widget f() => Block(child: UserIntent.onGesture(go));');
        rejects('Widget f() => Block(UserIntent.onGesture(go));');
        rejects('void f() => store.listen(onTap: UserIntent.onGesture(go));');
        rejects('void f() => Block(onTap: [UserIntent.onGesture(go)]);');
      });

      test('rejects a wrapper reached any other way', () {
        rejects('final tap = UserIntent.onGesture;');
        rejects('Widget f() => Block(onTap: Tap.onGesture(go));');
        rejects(
          'Widget f() => Block(onTap: reasons.UserIntent.onGesture(go));',
        );
        rejects('final mint = UserIntent;');
        rejects('final intent = UserIntent();');
        rejects('final intent = UserIntent.fromGesture();');
        rejects('final ended = ShellEnded.unbound();');
      });

      test('rejects a platform wrapper outside its registration', () {
        rejects('Future<void> main() => PlatformSignal.onLaunch(boot);');
        rejects(
          'Future<void> start() => PlatformSignal.onLaunch(boot);',
          path: 'lib/main.dart',
        );
        rejects(
          'void f() => ref.listen<bool>(otherProvider, PlatformSignal.onLifecycle(go));',
        );
        rejects('void f() => ticks.listen(PlatformSignal.onNetwork(go));');
        rejects(
          'void f() => AlertNotifications.initialize(onTap: UserIntent.onNotificationTap(go));',
        );
        rejects('Widget f() => Block(onTap: PlatformSignal.onNetwork(go));');
      });

      test('rejects a private mint outside its wrapper', () {
        expect(
          scanMints(
            _supervisor,
            _parse(_supervisor, 'final intent = UserIntent._();'),
            inLibrary: true,
          ).violations,
          isNotEmpty,
        );
        expect(
          scanMints(
            _reasons,
            _parse(
              _reasons,
              'final class UserIntent { UserIntent._(); '
              'static UserIntent leak() => UserIntent._(); }',
            ),
            inLibrary: true,
          ).violations,
          isNotEmpty,
        );
      });

      test('rejects an extra carrier and one read twice', () {
        const path = 'lib/carrier.dart';
        List<String> scan(String source) => carrierViolations(
          {path: _parse(path, source)},
          const {
            path: {'Route.intent'},
          },
        );
        expect(
          scan('''
class Route {
  final UserIntent? intent;
  final void Function(UserIntent intent)? onOpen;
}
class _RouteState extends State<Route> { void f() => use(widget.intent); }
'''),
          isEmpty,
        );
        expect(
          scan('''
class Route { final UserIntent? intent; }
class _RouteState extends State<Route> {
  void f() => use(widget.intent);
  void g() => use(widget.intent);
}
'''),
          isNotEmpty,
        );
        expect(
          scan('''
class Route { final UserIntent? intent; }
class _RouteState extends State<Route> {
  UserIntent? kept;
  void f() => use(widget.intent);
}
'''),
          isNotEmpty,
        );
        expect(
          scan('''
class Route { final UserIntent? intent; }
final List<PlatformSignal> held = [];
class _RouteState extends State<Route> { void f() => use(widget.intent); }
'''),
          isNotEmpty,
        );
      });
    });
  });

  test('only HostLinks opens an ssh connection', () {
    expect(
      _members(
        (name, target, node) =>
            name == 'connect' &&
                target is SimpleIdentifier &&
                target.name == 'SSHSocket' ||
            name == 'SSHClient' && node is MethodInvocation && target == null,
        except: _hostLinks,
      ),
      isEmpty,
      reason: 'lease from HostLinks, or add a named dial to it',
    );
    final constructed = [
      for (final MapEntry(key: path, value: unit) in _lib.entries)
        if (path != _hostLinks)
          for (final node in _instances(unit))
            if (node.constructorName.type.name.lexeme == 'SSHClient') path,
    ];
    expect(constructed, isEmpty);
  });

  test('only the shell tunnel dials through SshConnector.establish', () {
    expect(_members(_named('establish')), {
      'lib/platform/shell/shell_tunnel.dart': 1,
    }, reason: 'a supervisor comes only from establish; $_seam');
  });

  test('only the supervisor renounces a host link', () {
    expect(_members(_named('renounce'), except: _hostLinks), {
      _supervisor: 1,
    }, reason: 'a renounce ends a live control link; $_seam');
  });

  test('only the shell sessions put host links to sleep and wake them', () {
    expect(
      _members(
        (name, _, node) =>
            (name == 'sleep' || name == 'wake') &&
            node is MethodInvocation &&
            node.argumentList.arguments.isEmpty,
        except: _hostLinks,
      ),
      {'lib/features/shell/shell_sessions.dart': 2},
      reason: 'a sleep ends every yielding lease; $_seam',
    );
  });

  test('only the shell wake rechecks every host link', () {
    expect(_members(_named('recheckAll'), except: _hostLinks), {
      'lib/features/shell/shell_wake.dart': 1,
    }, reason: 'a recheck is a keepalive round on every link; $_seam');
  });

  test('only the known owners close host links', () {
    expect(
      _members(
        (name, target, _) =>
            name == 'close' &&
            (_lastName(target)?.toLowerCase().endsWith('links') ?? false),
        except: _hostLinks,
      ),
      {
        'lib/application/agents.dart': 1,
        'lib/platform/agent_watcher.dart': 1,
        'lib/platform/alert_actions.dart': 1,
      },
      reason: 'a close ends every link in the pool; $_seam',
    );
  });

  test('only the named borrowers reach a lease\'s raw client', () {
    expect(
      _members(
        (name, target, _) => name == 'client' && target is! ThisExpression,
        except: _hostLinks,
      ),
      {
        'lib/platform/herdr_client.dart': 1,
        'lib/platform/ssh/ssh_host.dart': 1,
        'lib/platform/vnc/vnc_tunnel.dart': 1,
      },
      reason: 'a raw client can close the connection under every lease; $_seam',
    );
  });
}

List<InstanceCreationExpression> _instances(CompilationUnit unit) {
  final found = <InstanceCreationExpression>[];
  _walk(unit, (node) {
    if (node is InstanceCreationExpression) found.add(node);
  });
  return found;
}
