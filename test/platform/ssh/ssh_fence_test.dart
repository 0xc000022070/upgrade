@Timeout(Duration(minutes: 5))
// ignore_for_file: implementation_imports
library;

import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/diagnostic/diagnostic.dart';
import 'package:analyzer/file_system/overlay_file_system.dart';
import 'package:analyzer/file_system/physical_file_system.dart';
import 'package:analyzer/src/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/src/dart/analysis/file_byte_store.dart';
import 'package:flutter_test/flutter_test.dart';

const _supervisor = 'lib/platform/ssh/connection_supervisor.dart';
const _reasons = 'lib/platform/ssh/reasons.dart';
const _hostLinks = 'lib/platform/ssh/host_links.dart';
const _shellScreen = 'lib/features/shell/host_shell_screen.dart';
const _shellSheet = 'lib/features/shell/sheets/shell_sheet.dart';
const _shellSessions = 'lib/features/shell/session/shell_sessions.dart';

const _sshUri = 'package:upgrade/platform/ssh/connection_supervisor.dart';
const _agentsUri = 'package:upgrade/application/agents/agents.dart';
const _widgetsUri = 'package:flutter/src/widgets/framework.dart';

const _seam =
    "a new call site needs the owner's approval before it joins this list";

const _wrappers = {
  'UserIntent': {'onGesture', 'onGestureWith', 'onNotificationTap'},
  'PlatformSignal': {'onLaunch', 'onLifecycle', 'onNetwork'},
};

const _tokenTypes = {
  'UserIntent',
  'PlatformSignal',
  'UserAction',
  'AppResumed',
  'NetworkChanged',
  'UserClosed',
  'AppSuspended',
  'OpenReason',
  'ReopenReason',
  'DropReason',
};

const _lifecycles = {'appVisibleProvider', 'appForegroundProvider'};

const _lifecycleCalls = {
  'didChangeAppLifecycleState',
  'handleAppLifecycleStateChanged',
};

const _deferrers = {'Timer', 'Future', 'Stream', 'StreamSubscription'};

const _frameCallbacks = {
  'addPostFrameCallback',
  'addPersistentFrameCallback',
  'scheduleFrameCallback',
  'scheduleMicrotask',
};

const _holders = {
  'Expando',
  'WeakReference',
  'Sink',
  'StreamSink',
  'StreamController',
  'Completer',
};

typedef Carriers = Map<String, Map<String, String>>;

const Carriers _carriers = {
  _shellSessions: {
    'ShellSessions._leftOn':
        'the app going away, held for the grace timer and spent by the suspend '
        'it ends in on every tab it puts to sleep',
    'ShellSession._networkOwed':
        'a network change that arrived while a rehome was in flight, spent by '
        'the rehome that follows it',
  },
  _shellScreen: {
    'HostShellRoute.intent':
        'the tap that pushed the route, spent on the frame it lands on',
  },
  _shellSheet: {
    'ShellSheetRoute.intent': 'the tap that pushed the sheet, handed down',
    '_SheetContents.intent': 'handed to the state that builds the route',
    '_SheetContentsState._intent': 'the tap behind the host in front, replaced when the sheet changes host',
  },
};

final _handlerName = RegExp(r'^on[A-Z]\w*$');
final _driven = RegExp(r'^(state|override\w*)$');

final _root = Directory.current.path;

String _abs(String rel) => '$_root/$rel';

final _files = OverlayResourceProvider(PhysicalResourceProvider.INSTANCE);

final _cache = Directory('$_root/.dart_tool/ssh_fence')
  ..createSync(recursive: true);

final AnalysisContext _context = AnalysisContextCollectionImpl(
  includedPaths: [_abs('lib')],
  resourceProvider: _files,
  byteStore: EvictingFileByteStore(_cache.path, 512 << 20),
  sdkPath: '${Platform.environment['FLUTTER_ROOT']}/bin/cache/dart-sdk',
).contextFor(_abs(_supervisor));

Future<ResolvedUnitResult> _resolved(String rel) async {
  final result = await _context.currentSession.getResolvedUnit(_abs(rel));
  if (result is ResolvedUnitResult) return result;
  throw StateError('$rel did not resolve: $result');
}

late final Map<String, CompilationUnit> _lib;
late final Set<String> _sshLibrary;

Map<String, CompilationUnit> get _outside => {
  for (final MapEntry(:key, :value) in _lib.entries)
    if (!_sshLibrary.contains(key)) key: value,
};

String _at(String rel, AstNode node) {
  final unit = node.root as CompilationUnit;
  final source = node.toSource();
  final shown = source.length > 100 ? '${source.substring(0, 100)}…' : source;
  return '$rel:${unit.lineInfo.getLocation(node.offset).lineNumber}: $shown';
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

void _walk(AstNode node, void Function(AstNode node) onNode) =>
    node.accept(_Code(onNode));

String? _uri(Element? element) => element?.library?.uri.toString();

bool _ssh(Element? element, Set<String> names) =>
    element is InterfaceElement &&
    names.contains(element.name) &&
    _uri(element) == _sshUri;

final _tokenClasses = _wrappers.keys.toSet();

String? _wrapper(Element? element) {
  final base = element?.baseElement;
  if (base is! MethodElement) return null;
  final owner = base.enclosingElement;
  if (!_ssh(owner, _tokenClasses)) return null;
  return _wrappers[owner!.name]!.contains(base.name) ? base.name : null;
}

bool _isMember(Element? element, String owner, String name) {
  final base = element?.baseElement;
  return base != null &&
      base.name == name &&
      base.enclosingElement?.name == owner &&
      (_uri(base)?.startsWith('package:upgrade/') ?? false);
}

bool _holdsToken(DartType? type) => switch (type) {
  InterfaceType(:final element, :final typeArguments) =>
    _ssh(element, _tokenTypes) || typeArguments.any(_holdsToken),
  RecordType(:final positionalFields, :final namedFields) => [
    for (final field in positionalFields) field.type,
    for (final field in namedFields) field.type,
  ].any(_holdsToken),
  FunctionType(:final returnType) => _holdsToken(returnType),
  _ => false,
};

bool _holder(DartType? type) =>
    type is InterfaceType &&
    [type, ...type.element.allSupertypes].any(
      (t) =>
          t.isDartCoreIterable ||
          t.isDartCoreMap ||
          _holders.contains(t.element.name),
    );

bool _open(DartType? type) => switch (type) {
  null ||
  DynamicType() ||
  InvalidType() ||
  TypeParameterType() ||
  FunctionType() ||
  RecordType() => true,
  final InterfaceType interface =>
    interface.isDartCoreObject ||
        interface.isDartAsyncFutureOr ||
        _holder(interface),
  _ => false,
};

Element? _elementOf(Expression? expression) => switch (expression) {
  Identifier(:final element) => element,
  PropertyAccess(:final propertyName) => propertyName.element,
  _ => null,
};

Expression? _bare(Expression? expression) => switch (expression) {
  ParenthesizedExpression(:final expression) => _bare(expression),
  PostfixExpression(:final operand, :final operator)
      when operator.type == TokenType.BANG =>
    _bare(operand),
  AsExpression(:final expression) => _bare(expression),
  _ => expression,
};

bool _nonLocal(Element? element) =>
    element is FieldElement || element is TopLevelVariableElement;

String _qualified(Element variable) {
  final owner = variable.enclosingElement;
  return '${owner is LibraryElement ? '<top>' : owner?.name}.${variable.name}';
}

PropertyInducingElement? _carrierRead(Expression? expression) {
  final element = _elementOf(_bare(expression));
  if (element is! GetterElement) return null;
  final variable = element.variable;
  return _nonLocal(variable) && _holdsToken(variable.type) ? variable : null;
}

Set<Element> _declaredWithin(AstNode node) {
  final inner = <Element>{};
  _walk(node, (n) {
    final element = switch (n) {
      FormalParameter() => n.declaredFragment?.element,
      VariableDeclaration() => n.declaredFragment?.element,
      DeclaredVariablePattern() => n.declaredFragment?.element,
      DeclaredIdentifier() => n.declaredFragment?.element,
      _ => null,
    };
    if (element != null) inner.add(element);
  });
  return inner;
}

bool _tainted(AstNode? node) {
  if (node == null) return false;
  final inner = _declaredWithin(node);
  var tainted = false;
  _walk(node, (n) {
    if (n is SimpleIdentifier &&
        !inner.contains(n.element) &&
        _holdsToken(n.staticType)) {
      tainted = true;
    }
  });
  return tainted;
}

bool _references(AstNode node, Set<Element> elements) {
  var found = false;
  _walk(node, (n) {
    if (n is SimpleIdentifier && elements.contains(n.element)) found = true;
  });
  return found;
}

AstNode _access(SimpleIdentifier node) => switch (node.parent) {
  final PrefixedIdentifier parent when identical(parent.identifier, node) =>
    parent,
  final PropertyAccess parent when identical(parent.propertyName, node) =>
    parent,
  _ => node,
};

bool _written(SimpleIdentifier node) {
  final access = _access(node);
  final parent = access.parent;
  return parent is AssignmentExpression &&
      identical(parent.leftHandSide, access) &&
      parent.operator.type == TokenType.EQ;
}

bool _nullTest(SimpleIdentifier node) {
  final parent = node.parent;
  return parent is BinaryExpression &&
      (parent.operator.type == TokenType.EQ_EQ ||
          parent.operator.type == TokenType.BANG_EQ) &&
      (parent.leftOperand is NullLiteral || parent.rightOperand is NullLiteral);
}

bool _constructed(Expression? expression) =>
    _bare(expression) is InstanceCreationExpression;

bool _isWidget(InterfaceElement? element) =>
    element != null &&
    element.allSupertypes.any(
      (t) => t.element.name == 'Widget' && _uri(t.element) == _widgetsUri,
    );

typedef MintScan = ({List<String> violations, Map<String, int> mints});

MintScan scanMints(
  String rel,
  CompilationUnit unit, {
  bool inLibrary = false,
  String entry = 'lib/main.dart',
}) {
  final violations = <String>[];
  final mints = <String, int>{};
  void flag(AstNode node, String why) =>
      violations.add('${_at(rel, node)} ($why)');
  final bodies = _bodies(unit);
  _walk(unit, (node) {
    switch (node) {
      case SimpleIdentifier(:final element, :final parent):
        if (_wrapper(element) case final wrapper?) {
          if (parent is! MethodInvocation ||
              !identical(parent.methodName, node)) {
            flag(parent ?? node, '$wrapper not called');
          } else if (inLibrary) {
            flag(parent, '$wrapper called inside the ssh library');
          } else {
            mints.update(wrapper, (count) => count + 1, ifAbsent: () => 1);
            if (!_inSlot(rel, wrapper, parent, entry)) {
              flag(parent, '$wrapper outside its slot');
            }
            for (final (leak, why) in _handlerLeaks(parent, bodies)) {
              flag(leak, why);
            }
          }
        } else if (_ssh(element, _tokenClasses) &&
            parent is! ConstructorDeclaration &&
            parent is! Combinator &&
            !_wrapperTarget(node)) {
          flag(parent ?? node, '${node.name} used as a value');
        }
      case TypeLiteral(:final type) when _ssh(type.element, _tokenClasses):
        flag(node, '${type.name.lexeme} used as a value');
      case ConstructorName(:final element):
        final owner = element?.baseElement.enclosingElement;
        if (_ssh(owner, _tokenClasses) && !_privateMint(rel, node)) {
          flag(
            node.parent ?? node,
            '${owner?.name} built outside its wrappers',
          );
        }
        if (!inLibrary && _ssh(owner, const {'ShellEnded'})) {
          flag(node.parent ?? node, "ShellEnded is the library's");
        }
      case PropertyAccess(:final propertyName, :final realTarget)
          when _handlerName.hasMatch(propertyName.name) &&
              _constructed(realTarget) &&
              !_assigned(node):
        flag(node, 'a callback read back off what it was handed to');
      case MethodInvocation(:final methodName, :final realTarget)
          when _handlerName.hasMatch(methodName.name) &&
              _constructed(realTarget):
        flag(node, 'a callback called on what it was handed to');
    }
  });
  return (violations: violations, mints: mints);
}

bool _assigned(Expression node) {
  final parent = node.parent;
  return parent is AssignmentExpression && identical(parent.leftHandSide, node);
}

bool _wrapperTarget(SimpleIdentifier node) {
  final access = _access(node);
  final call = access.parent;
  return call is MethodInvocation &&
      identical(call.target, access) &&
      _wrapper(call.methodName.element) != null;
}

bool _privateMint(String rel, ConstructorName node) {
  final type = node.element?.enclosingElement.name;
  final method = node.thisOrAncestorOfType<MethodDeclaration>();
  final owner = node.thisOrAncestorOfType<ClassDeclaration>();
  return rel == _reasons &&
      node.parent is InstanceCreationExpression &&
      method != null &&
      (_wrappers[type]?.contains(method.name.lexeme) ?? false) &&
      owner?.namePart.typeName.lexeme == type;
}

bool _inSlot(String rel, String wrapper, MethodInvocation call, String entry) {
  final parent = call.parent;
  switch (wrapper) {
    case 'onGesture' || 'onGestureWith':
      return _handlerSlot(call);
    case 'onNotificationTap':
      return parent is NamedArgument &&
          parent.name.lexeme == 'onResponse' &&
          _invokes(parent.parent?.parent, 'AlertNotifications', 'initialize');
    case 'onLaunch':
      final function = parent?.parent?.parent;
      return rel == entry &&
          parent is ExpressionFunctionBody &&
          function is FunctionDeclaration &&
          function.name.lexeme == 'main' &&
          function.parent is CompilationUnit;
    case 'onLifecycle':
      final listen = parent?.parent;
      if (parent is! ArgumentList ||
          listen is! MethodInvocation ||
          listen.methodName.name != 'listen' ||
          !(_uri(listen.methodName.element)?.contains('riverpod') ?? false)) {
        return false;
      }
      final arguments = parent.arguments;
      final provider = _elementOf(arguments.first.argumentExpression);
      return arguments.length == 2 &&
          identical(arguments.last, call) &&
          provider is GetterElement &&
          _lifecycles.contains(provider.variable.name) &&
          _uri(provider) == _agentsUri;
    case 'onNetwork':
      final listen = parent?.parent;
      return parent is ArgumentList &&
          parent.arguments.length == 1 &&
          listen is MethodInvocation &&
          listen.methodName.name == 'listen' &&
          _invokes(listen.target, 'Device', 'networkChanges');
  }
  return false;
}

bool _invokes(AstNode? node, String owner, String name) =>
    node is MethodInvocation && _isMember(node.methodName.element, owner, name);

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
  final creation = parent.parent?.parent;
  return creation is InstanceCreationExpression &&
      _isWidget(creation.constructorName.element?.enclosingElement);
}

Map<Element, FunctionBody> _bodies(CompilationUnit unit) {
  final found = <Element, FunctionBody>{};
  _walk(unit, (node) {
    switch (node) {
      case MethodDeclaration(:final declaredFragment?, :final body):
        found[declaredFragment.element] = body;
      case FunctionDeclaration(
        :final declaredFragment?,
        :final functionExpression,
      ):
        found[declaredFragment.element] = functionExpression.body;
    }
  });
  return found;
}

List<(AstNode, String)> _handlerLeaks(
  MethodInvocation call,
  Map<Element, FunctionBody> bodies,
) {
  final arguments = call.argumentList.arguments;
  if (arguments.isEmpty) return const [];
  final handler = arguments.first;
  final (FunctionBody? body, Set<Element> tokens) = switch (handler) {
    FunctionExpression(:final body, :final parameters) => (
      body,
      {
        for (final parameter in parameters?.parameters ?? <FormalParameter>[])
          if (parameter.declaredFragment?.element case final element?
              when _holdsToken(element.type))
            element,
      },
    ),
    Identifier(:final element?) => (
      bodies[element.baseElement],
      {
        if (element.baseElement case final ExecutableElement executable)
          for (final parameter in executable.formalParameters)
            if (_holdsToken(parameter.type)) parameter,
      },
    ),
    _ => (null, const <Element>{}),
  };
  if (body == null || tokens.isEmpty) return const [];
  final leaks = <(AstNode, String)>[];
  _walk(body, (node) {
    final (Element? callee, AstNode? passed) = switch (node) {
      MethodInvocation(:final methodName, :final argumentList) => (
        methodName.element,
        argumentList,
      ),
      InstanceCreationExpression(:final constructorName, :final argumentList) =>
        (constructorName.element, argumentList),
      _ => (null, null),
    };
    if (passed != null && _defers(callee) && _references(passed, tokens)) {
      leaks.add((node, 'the token handed to a timer, a future or a stream'));
    }
    if (node is FunctionExpression &&
        _stored(node) &&
        _references(node, tokens)) {
      leaks.add((node, 'a closure over the token kept for later'));
    }
  });
  return leaks;
}

bool _defers(Element? callee) {
  final base = callee?.baseElement;
  if (base == null) return false;
  if (_frameCallbacks.contains(base.name)) return true;
  return _uri(base) == 'dart:async' &&
      _deferrers.contains(base.enclosingElement?.name);
}

bool _stored(Expression closure) {
  AstNode node = closure;
  var parent = node.parent;
  while (parent is ParenthesizedExpression) {
    node = parent;
    parent = node.parent;
  }
  return parent is VariableDeclaration ||
      parent is AssignmentExpression && identical(parent.rightHandSide, node) ||
      parent is ListLiteral ||
      parent is SetOrMapLiteral ||
      parent is MapLiteralEntry ||
      parent is ReturnStatement;
}

List<String> carrierViolations(
  Map<String, CompilationUnit> units,
  Carriers allowed,
) {
  final violations = <String>[];
  final declared = <String>{};
  final reads = <String, int>{};
  for (final MapEntry(key: rel, value: unit) in units.entries) {
    void flag(AstNode node, String why) =>
        violations.add('${_at(rel, node)} ($why)');
    _walk(unit, (node) {
      switch (node) {
        case VariableDeclaration(:final declaredFragment?, :final initializer):
          final element = declaredFragment.element;
          if (!_nonLocal(element)) return;
          final name = _qualified(element);
          if (_holdsToken(element.type)) {
            declared.add(name);
            if (!(allowed[rel]?.containsKey(name) ?? false)) {
              flag(node, '$name holds a token');
            }
          } else if (_open(element.type) && _tainted(initializer)) {
            flag(node, '$name is handed a token');
          }
        case MethodDeclaration(
              isGetter: true,
              :final declaredFragment?,
              :final body,
            ) ||
            FunctionDeclaration(
              isGetter: true,
              :final declaredFragment?,
              functionExpression: FunctionExpression(:final body),
            ):
          final returned = declaredFragment.element;
          if (_holdsToken(returned.returnType)) {
            flag(node, 'a getter hands a token out');
          } else if (_open(returned.returnType) && _tainted(body)) {
            flag(node, 'a getter hands a token out');
          }
        case AssignmentExpression(
          :final leftHandSide,
          :final rightHandSide,
          :final writeElement,
        ):
          if (leftHandSide is IndexExpression) {
            if (_storedHolder(leftHandSide.realTarget) &&
                _tainted(rightHandSide)) {
              flag(node, 'a token put in a stored holder');
            }
          } else if (writeElement is SetterElement &&
              _nonLocal(writeElement.variable) &&
              _open(writeElement.variable.type) &&
              _tainted(rightHandSide)) {
            flag(
              node,
              '${_qualified(writeElement.variable)} is handed a token',
            );
          }
        case MethodInvocation(:final realTarget?, :final argumentList)
            when _storedHolder(realTarget) && _tainted(argumentList):
          flag(node, 'a token put in a stored holder');
        case SimpleIdentifier(:final element)
            when element is GetterElement &&
                _nonLocal(element.variable) &&
                _holdsToken(element.variable.type) &&
                !_written(node):
          final name = _qualified(element.variable);
          reads[name] = (reads[name] ?? 0) + 1;
      }
    });
  }
  for (final MapEntry(key: rel, value: fields) in allowed.entries) {
    if (!units.containsKey(rel)) continue;
    for (final name in fields.keys) {
      if (!declared.contains(name)) {
        violations.add('$rel: $name is gone');
      } else if (reads[name] != 1) {
        violations.add('$rel: $name read ${reads[name] ?? 0} times');
      }
    }
  }
  return violations;
}

bool _storedHolder(Expression? target) {
  final element = _elementOf(_bare(target));
  return element is GetterElement &&
      _nonLocal(element.variable) &&
      _holder(element.variable.type);
}

List<String> aliasViolations(String rel, CompilationUnit unit) {
  final violations = <String>[];
  _walk(unit, (node) {
    final Element? local = switch (node) {
      VariableDeclaration(:final declaredFragment?, :final initializer)
          when declaredFragment.element is LocalVariableElement &&
              _carrierRead(initializer) != null =>
        declaredFragment.element,
      DeclaredVariablePattern(:final declaredFragment?)
          when _carrierRead(_scrutinee(node)) != null =>
        declaredFragment.element,
      _ => null,
    };
    final scope = node.thisOrAncestorOfType<FunctionBody>();
    if (local == null || scope == null) return;
    var uses = 0;
    _walk(scope, (n) {
      if (n is SimpleIdentifier && n.element == local && !_nullTest(n)) {
        uses++;
      }
    });
    if (uses > 1) {
      violations.add('${_at(rel, node)} (a carrier read spent $uses times)');
    }
  });
  return violations;
}

Expression? _scrutinee(AstNode pattern) {
  for (AstNode? node = pattern.parent; node != null; node = node.parent) {
    switch (node) {
      case IfStatement(:final expression, caseClause: _?):
        return expression;
      case IfElement(:final expression, caseClause: _?):
        return expression;
      case SwitchStatement(:final expression):
        return expression;
      case SwitchExpression(:final expression):
        return expression;
      case PatternVariableDeclaration(:final expression):
        return expression;
      case PatternAssignment(:final expression):
        return expression;
      case FunctionBody():
        return null;
    }
  }
  return null;
}

List<String> lifecycleForgeries(String rel, CompilationUnit unit) {
  final violations = <String>[];
  void flag(AstNode node) => violations.add(_at(rel, node));
  _walk(unit, (node) {
    switch (node) {
      case SimpleIdentifier(:final name, :final parent)
          when _lifecycleCalls.contains(name) && !_forwarded(node):
        flag(parent ?? node);
      case AssignmentExpression(:final leftHandSide, :final writeElement)
          when writeElement?.name == 'state' && _forgesReading(leftHandSide):
        flag(node);
    }
    if (_member(node) case (final name, final target?)
        when _driven.hasMatch(name) && _readsLifecycle(target)) {
      flag(node);
    }
  });
  return violations;
}

bool _forwarded(SimpleIdentifier node) {
  final call = node.parent;
  final method = node.thisOrAncestorOfType<MethodDeclaration>();
  return call is MethodInvocation &&
      call.target is SuperExpression &&
      method?.name.lexeme == node.name;
}

bool _isReading(DartType? type) =>
    type is InterfaceType &&
    [type, ...type.element.allSupertypes].any(
      (t) =>
          t.element.name == 'AppLifecycleReading' &&
          _uri(t.element) == _agentsUri,
    );

bool _forgesReading(Expression target) {
  final DartType? owner = switch (target) {
    PropertyAccess(:final realTarget) => realTarget.staticType,
    PrefixedIdentifier(:final prefix) => prefix.staticType,
    _ => switch (target.thisOrAncestorOfType<ClassDeclaration>()) {
      ClassDeclaration(:final declaredFragment?) =>
        declaredFragment.element.thisType,
      _ => null,
    },
  };
  final method = target.thisOrAncestorOfType<MethodDeclaration>();
  return _isReading(owner) &&
      !(method?.name.lexeme == 'didChangeAppLifecycleState' &&
          _isReading(
            target
                .thisOrAncestorOfType<ClassDeclaration>()
                ?.declaredFragment
                ?.element
                .thisType,
          ));
}

bool _readsLifecycle(Expression target) {
  var found = false;
  _walk(target, (n) {
    if (n is SimpleIdentifier &&
        n.element is GetterElement &&
        _lifecycles.contains(n.name) &&
        _uri(n.element) == _agentsUri) {
      found = true;
    }
  });
  return found;
}

List<String> testImports(String rel, CompilationUnit unit) => [
  for (final directive in unit.directives.whereType<UriBasedDirective>())
    if (Uri.file(_abs(rel)).resolve(directive.uri.stringValue ?? '')
        case final target
        when target.scheme == 'file' &&
            target.toFilePath().startsWith('$_root/test/'))
      '${_at(rel, directive)} (lib reaches into test/)',
];

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

Element? _invoked(AstNode node) => switch (node) {
  MethodInvocation(:final methodName) => methodName.element,
  PropertyAccess(:final propertyName) => propertyName.element,
  PrefixedIdentifier(:final identifier) => identifier.element,
  _ => null,
};

bool Function(String, Expression?, AstNode) _declared(
  String library,
  String owner,
  Set<String> members,
) => (_, _, node) {
  final base = _invoked(node)?.baseElement;
  return base != null &&
      members.contains(base.name) &&
      base.enclosingElement?.name == owner &&
      _uri(base) == library;
};

const _hostLinksUri = 'package:upgrade/platform/ssh/host_links.dart';

/// Every read of [member]: a call, a property, a pattern field or an implicit `this`. A
/// declaration names it with a token, not an identifier, so it never counts.
Map<String, int> _reads(
  String library,
  String owner,
  String member, {
  String? except,
}) {
  final found = <String, int>{};
  for (final MapEntry(key: path, value: unit) in _lib.entries) {
    if (path == except || path == _reasons) continue;
    _walk(unit, (node) {
      final base = switch (node) {
        SimpleIdentifier(:final element) => element,
        PatternField(:final element) => element,
        _ => null,
      }?.baseElement;
      if (base != null &&
          base.name == member &&
          base.enclosingElement?.name == owner &&
          _uri(base) == library) {
        found[path] = (found[path] ?? 0) + 1;
      }
    });
  }
  return found;
}

bool Function(String, Expression?, AstNode) _links(Set<String> members) =>
    _declared(_hostLinksUri, 'HostLinks', members);

List<InstanceCreationExpression> _instances(CompilationUnit unit) {
  final found = <InstanceCreationExpression>[];
  _walk(unit, (node) {
    if (node is InstanceCreationExpression) found.add(node);
  });
  return found;
}

const _snippetImports = '''
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:upgrade/application/agents/agents.dart';
import 'package:upgrade/platform/notifications/alert_notifications.dart';
import 'package:upgrade/platform/device.dart';
import 'package:upgrade/platform/shell/shell_connection.dart';
''';

const _snippetHelpers = '''
void go(UserIntent intent) {}
void use(Object? value) {}
void listenTo({VoidCallback? onTap}) {}

class Block extends StatelessWidget {
  const Block({super.key, this.onTap, this.onPick, this.onToggle, this.child});

  final VoidCallback? onTap;
  final ValueChanged<int>? onPick;
  final ValueChanged<bool>? onToggle;
  final Widget? child;

  @override
  Widget build(BuildContext context) => const SizedBox();
}

class Fire {
  Fire({required VoidCallback onFire}) {
    onFire();
  }
}
''';

const _landingWidget = '''
class Landing extends StatefulWidget {
  const Landing({super.key, this.intent});

  final UserIntent? intent;

  @override
  State<Landing> createState() => LandingState();
}
''';

var _snippetCount = 0;

Future<CompilationUnit> _overlaid(String rel, String content) async {
  _files.setOverlay(
    _abs(rel),
    content: content,
    modificationStamp: ++_snippetCount,
  );
  _context.changeFile(_abs(rel));
  await _context.applyPendingFileChanges();
  return (await _resolved(rel)).unit;
}

Future<void> _restore(String rel) async {
  _files.removeOverlay(_abs(rel));
  _context.changeFile(_abs(rel));
  await _context.applyPendingFileChanges();
}

Future<List<String>> _errors(String rel) async => [
  for (final diagnostic in (await _resolved(rel)).diagnostics)
    if (diagnostic.severity == Severity.error) diagnostic.message,
];

typedef Snippet = ({String rel, CompilationUnit unit});

Future<Snippet> _snippet(
  String source, {
  String imports = '',
  bool landing = false,
}) async {
  final rel = 'lib/fence_snippets/s$_snippetCount.dart';
  final widget = landing ? _landingWidget : '';
  final unit = await _overlaid(
    rel,
    '$_snippetImports$imports$_snippetHelpers$widget$source',
  );
  expect(await _errors(rel), isEmpty, reason: source);
  return (rel: rel, unit: unit);
}

List<String> _fence(Snippet snippet, {String? entry, bool landing = false}) => [
  ...scanMints(
    snippet.rel,
    snippet.unit,
    entry: entry ?? 'lib/main.dart',
  ).violations,
  ...carrierViolations(
    {snippet.rel: snippet.unit},
    {
      if (landing) snippet.rel: {'Landing.intent': 'the test route'},
    },
  ),
  ...aliasViolations(snippet.rel, snippet.unit),
  ...lifecycleForgeries(snippet.rel, snippet.unit),
  ...testImports(snippet.rel, snippet.unit),
];

void main() {
  setUpAll(() async {
    final paths = [
      for (final file in Directory('lib').listSync(recursive: true))
        if (file is File && file.path.endsWith('.dart')) file.path,
    ]..sort();
    _lib = {for (final path in paths) path: (await _resolved(path)).unit};
    _sshLibrary = {
      _supervisor,
      for (final part
          in _lib[_supervisor]!.directives.whereType<PartDirective>())
        '${File(_supervisor).parent.path}/${part.uri.stringValue}',
    };
  });

  test('the ssh library is the supervisor and its parts', () {
    expect(_sshLibrary, {
      _supervisor,
      'lib/platform/ssh/exec.dart',
      _reasons,
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
          'lib/features/agents/agent_shell.dart': 1,
          'lib/features/agents/agents_screen.dart': 2,
          'lib/features/agents/sent_screen.dart': 1,
          'lib/features/code/diff_sheet.dart': 1,
          'lib/features/code/workspace_sheet.dart': 1,
          'lib/features/home/agents_panel.dart': 2,
          'lib/features/hosts/hosts_screen.dart': 4,
          'lib/features/shell/sheets/attach_sheet.dart': 3,
          _shellScreen: 5,
          'lib/features/shell/sheets/launch_picker_sheet.dart': 5,
          'lib/features/shell/parked_shell_bar.dart': 2,
        },
        'onGestureWith': {
          _shellScreen: 2,
          'lib/features/shell/parked_shell_bar.dart': 1,
          'lib/features/plugins/plugin_card.dart': 1,
          'lib/features/plugins/plugin_page.dart': 1,
        },
        'onNotificationTap': {'lib/app/alerts_boot.dart': 1},
        'onLaunch': {'lib/main.dart': 1},
        'onLifecycle': {'lib/features/shell/session/shell_wake.dart': 2},
        'onNetwork': {'lib/features/shell/session/shell_wake.dart': 1},
      }, reason: 'mint where a gesture or the platform calls in; $_seam');
    });

    test('a close rides its gesture\'s action only where a tab closes', () {
      final found = <String, int>{};
      for (final MapEntry(key: path, value: unit) in _lib.entries) {
        _walk(unit, (node) {
          final element = switch (node) {
            InstanceCreationExpression(:final constructorName) ||
            ConstructorReference(
              :final constructorName,
            ) => constructorName.element,
            _ => null,
          };
          if (_ssh(element?.baseElement.enclosingElement, {'UserClosed'}) &&
              element?.name == 'by') {
            found[path] = (found[path] ?? 0) + 1;
          }
        });
      }
      expect(found, {
        _shellSessions: 1,
      }, reason: 'UserClosed.by spends no token of its own; $_seam');
    });

    test('ride only in the landing fields, each read once', () {
      expect(
        carrierViolations(_outside, _carriers),
        isEmpty,
        reason: 'pass a token as a parameter; a stored one can be spent twice',
      );
    });

    test('a landing field read into a local is spent once', () {
      expect([
        for (final MapEntry(:key, :value) in _outside.entries)
          ...aliasViolations(key, value),
      ], isEmpty);
    });

    test('the lifecycle readings change only from the binding', () {
      expect(
        [
          for (final MapEntry(:key, :value) in _lib.entries)
            ...lifecycleForgeries(key, value),
        ],
        isEmpty,
        reason: 'a lifecycle reading mints a PlatformSignal on every change',
      );
    });

    test('lib imports nothing from test/', () {
      expect([
        for (final MapEntry(:key, :value) in _lib.entries)
          ...testImports(key, value),
      ], isEmpty);
    });

    group('the fence', () {
      Future<void> rejects(
        String source, {
        String imports = '',
        bool landing = false,
        bool entry = false,
      }) async {
        final snippet = await _snippet(
          source,
          imports: imports,
          landing: landing,
        );
        expect(
          _fence(snippet, entry: entry ? snippet.rel : null, landing: landing),
          isNotEmpty,
          reason: source,
        );
      }

      Future<void> accepts(
        String source, {
        String imports = '',
        bool landing = false,
        bool entry = false,
      }) async {
        final snippet = await _snippet(
          source,
          imports: imports,
          landing: landing,
        );
        expect(
          _fence(snippet, entry: entry ? snippet.rel : null, landing: landing),
          isEmpty,
          reason: source,
        );
      }

      test('passes a callback handed to a widget', () async {
        await accepts('''
Widget a() => Block(onTap: UserIntent.onGesture((intent) => go(intent)));
Widget b() => Block(onPick: UserIntent.onGestureWith((intent, int value) => go(intent)));
Widget c(bool on) => Block(onTap: on ? null : (UserIntent.onGesture(go)));
''');
        await accepts(
          'Widget d() => Block(onTap: reasons.UserIntent.onGesture(go));',
          imports: "import 'package:upgrade/platform/shell/shell_connection.dart' as reasons;\n",
        );
      });

      test('passes the platform registrations', () async {
        await accepts(
          'Future<void> main() => PlatformSignal.onLaunch((launch) async {});',
          entry: true,
        );
        await accepts('''
void f(WidgetRef ref) {
  ref.listen<bool>(appVisibleProvider, PlatformSignal.onLifecycle((signal, was, now) {}));
  Device.networkChanges().listen(PlatformSignal.onNetwork((signal, up) {}));
  AlertNotifications.initialize(onResponse: UserIntent.onNotificationTap((intent, response) {}));
}
''');
      });

      test('passes a landing field read into a local spent once', () async {
        await accepts(landing: true, '''
class LandingState extends State<Landing> {
  void f() {
    final intent = widget.intent;
    if (intent != null) go(intent);
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}
''');
      });

      test('rejects a callback invoked on the spot', () async {
        await rejects('void f() => UserIntent.onGesture((intent) {})();');
        await rejects('void f() { UserIntent.onGesture(go)(); }');
      });

      test('rejects a callback stored or returned', () async {
        await rejects('final tap = UserIntent.onGesture(go);');
        await rejects('class A { late final tap = UserIntent.onGesture(go); }');
        await rejects(
          'void f() { final tap = UserIntent.onGesture(go); tap(); }',
        );
        await rejects('VoidCallback f() => UserIntent.onGesture(go);');
        await rejects('VoidCallback f() { return UserIntent.onGesture(go); }');
      });

      test('rejects a callback in any other argument', () async {
        await rejects(
          'void f(void Function(VoidCallback) take) => take(UserIntent.onGesture(go));',
        );
        await rejects('void f() => listenTo(onTap: UserIntent.onGesture(go));');
        await rejects(
          'Widget f() => Block(onTap: [UserIntent.onGesture(go)].first);',
        );
      });

      test('rejects a slot that is not a widget', () async {
        await rejects(
          'final c = StreamController<void>(onListen: UserIntent.onGesture(go));',
        );
        await rejects('final f = Fire(onFire: UserIntent.onGesture(go));');
      });

      test('rejects a callback read back off its widget', () async {
        await rejects(
          'void f() => Block(onTap: UserIntent.onGesture(go)).onTap!();',
        );
        await rejects(
          'void f() => (Block(onTap: UserIntent.onGesture(go))).onTap?.call();',
        );
        await rejects(
          'void f() => Block(onTap: UserIntent.onGesture(go))..onTap!();',
        );
      });

      test('rejects a handler that keeps its token for later', () async {
        await rejects('''
Widget f() => Block(onTap: UserIntent.onGesture((intent) {
  Timer(Duration.zero, () => go(intent));
}));
''');
        await rejects('''
Widget f() => Block(onTap: UserIntent.onGesture((intent) {
  Future<void>.delayed(Duration.zero, () => go(intent));
}));
''');
        await rejects('''
Widget f() => Block(onTap: UserIntent.onGesture((intent) {
  Future<void>.value().then((_) => go(intent));
}));
''');
        await rejects('''
Widget f() => Block(onTap: UserIntent.onGesture((intent) {
  const Stream<int>.empty().listen((_) => go(intent));
}));
''');
        await rejects('''
Widget f() => Block(onTap: UserIntent.onGesture((intent) {
  WidgetsBinding.instance.addPostFrameCallback((_) => go(intent));
}));
''');
        await rejects('''
Widget f(List<VoidCallback> later) => Block(onTap: UserIntent.onGesture((intent) {
  final replay = () => go(intent);
  later.add(replay);
}));
''');
        await rejects('''
void tapped(UserIntent intent) => Timer(Duration.zero, () => go(intent));
Widget f() => Block(onTap: UserIntent.onGesture(tapped));
''');
      });

      test('rejects a wrapper reached any other way', () async {
        await rejects('final tap = UserIntent.onGesture;');
        await rejects('final mint = UserIntent;');
        await rejects('final ended = ShellEnded.unbound();');
        await rejects(
          'final tap = reasons.UserIntent.onGesture(go);',
          imports: "import 'package:upgrade/platform/shell/shell_connection.dart' as reasons;\n",
        );
      });

      test('rejects a platform wrapper outside its registration', () async {
        await rejects(
          'Future<void> main() => PlatformSignal.onLaunch((launch) async {});',
        );
        await rejects(
          'Future<void> start() => PlatformSignal.onLaunch((launch) async {});',
          entry: true,
        );
        await rejects('''
final otherProvider = StateProvider<bool>((ref) => false);
void f(WidgetRef ref) =>
    ref.listen<bool>(otherProvider, PlatformSignal.onLifecycle((signal, was, now) {}));
''');
        await rejects(
          'void f(Stream<bool> ticks) => ticks.listen(PlatformSignal.onNetwork((signal, up) {}));',
        );
        await rejects(
          'void f() => AlertNotifications.initialize(onBackgroundResponse: UserIntent.onNotificationTap((intent, response) {}));',
        );
        await rejects(
          'Widget f() => Block(onToggle: PlatformSignal.onNetwork((signal, up) {}));',
        );
      });

      test('rejects a token kept outside the landing fields', () async {
        await rejects('''
class Bar extends StatefulWidget {
  const Bar({super.key});

  @override
  State<Bar> createState() => _BarState();
}

class _BarState extends State<Bar> {
  Object? lastTap;

  @override
  Widget build(BuildContext context) => Block(
    onTap: UserIntent.onGesture((intent) {
      lastTap = intent;
      go(intent);
    }),
  );
}
''');
        for (final member in [
          'late var kept = widget.intent;',
          'UserIntent? get tap => widget.intent;',
          'Object? get tap => widget.intent;',
          'late final VoidCallback replay = () => go(widget.intent!);',
          'late final Object held = [widget.intent];',
          'NetworkChanged? owed;',
          'final taps = Expando<UserIntent>();',
        ]) {
          await rejects(landing: true, '''
class LandingState extends State<Landing> {
  $member

  void f() => use(widget.intent);

  @override
  Widget build(BuildContext context) => const SizedBox();
}
''');
        }
        await rejects('''
final seen = Expando<Object>();
final held = <Object>[];
Widget f() => Block(onTap: UserIntent.onGesture((intent) {
  seen[held] = intent;
}));
''');
        await rejects('''
final held = <Object>[];
Widget f() => Block(onTap: UserIntent.onGesture((intent) {
  held.add(intent);
}));
''');
      });

      test('rejects a landing field unread or read twice', () async {
        await rejects(landing: true, '''
class LandingState extends State<Landing> {
  @override
  Widget build(BuildContext context) => const SizedBox();
}
''');
        await rejects(landing: true, '''
class LandingState extends State<Landing> {
  void f() => use(widget.intent);
  void g() => use(widget.intent);

  @override
  Widget build(BuildContext context) => const SizedBox();
}
''');
      });

      test('rejects a landing field read into a local spent twice', () async {
        await rejects(landing: true, '''
class LandingState extends State<Landing> {
  void f() {
    final intent = widget.intent;
    go(intent!);
    go(intent);
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}
''');
        await rejects(landing: true, '''
class LandingState extends State<Landing> {
  void f() {
    if (widget.intent case final intent?) {
      go(intent);
      go(intent);
    }
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}
''');
      });

      test('rejects a lifecycle change not from the binding', () async {
        await rejects('''
void f(WidgetRef ref) => ref
    .read(appVisibleProvider.notifier)
    .didChangeAppLifecycleState(AppLifecycleState.resumed);
''');
        await rejects('''
void f() => WidgetsBinding.instance
    .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
''');
        await rejects('''
// ignore_for_file: invalid_use_of_protected_member
void f(WidgetRef ref) => ref.read(appForegroundProvider.notifier).state = true;
''');
        await rejects('''
final forged = appVisibleProvider.overrideWith((ref) => AppLifecycleReading((state) => true));
''');
      });

      test('rejects lib reaching into test/', () async {
        await rejects(
          'Widget f() => Block(onTap: () => go(testIntent()));',
          imports: "import 'file://$_root/test/support/reasons.dart';\n",
        );
      });

      test('a reason gives no token back', () async {
        final rel = 'lib/fence_snippets/s$_snippetCount.dart';
        await _overlaid(rel, '''
$_snippetImports
UserIntent? back(UserAction action) => action.intent;
PlatformSignal? signal(NetworkChanged change) => change.signal;
''');
        expect(await _errors(rel), hasLength(2));
      });

      test('rejects a private mint outside its wrapper', () async {
        final source = File(_reasons).readAsStringSync();
        try {
          final unit = await _overlaid(
            _reasons,
            '${source.replaceFirst('  UserIntent._();\n', '  UserIntent._();\n\n  static UserIntent leak() => UserIntent._();\n')}'
            '\nfinal escaped = PlatformSignal._();\n',
          );
          expect(
            scanMints(_reasons, unit, inLibrary: true).violations,
            hasLength(2),
          );
        } finally {
          await _restore(_reasons);
        }
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
    expect(_members(_declared(_sshUri, 'SshConnector', {'establish'})), {
      'lib/platform/shell/shell_tunnel.dart': 1,
    }, reason: 'a supervisor comes only from establish; $_seam');
  });

  test('only the supervisor claims a host link for a tab', () {
    expect(_members(_links({'claim'}), except: _hostLinks), {
      _supervisor: 1,
    }, reason: 'a claim takes a tab\'s lane on the host; $_seam');
  });

  test('only the supervisor takes a link on the tab lane', () {
    expect(_reads(_hostLinksUri, 'HostUse', 'tab', except: _hostLinks), {
      _supervisor: 1,
    }, reason: 'HostLinks.lease forwards any use to claim; $_seam');
  });

  test('only the supervisor takes a link of a tab\'s own', () {
    expect(_reads(_hostLinksUri, 'HostUse', 'ownTab', except: _hostLinks), {
      _supervisor: 1,
    }, reason: 'an own link is dialed fresh and never shared; $_seam');
  });

  test('only the supervisor renounces a host link', () {
    expect(_members(_links({'renounce'}), except: _hostLinks), {
      _supervisor: 1,
    }, reason: 'a renounce ends a live control link; $_seam');
  });

  test('only the shell sessions put host links to sleep and wake them', () {
    expect(_members(_links({'sleep', 'wake'}), except: _hostLinks), {
      _shellSessions: 2,
    }, reason: 'a sleep ends every yielding lease; $_seam');
  });

  test('only the shell wake rechecks every host link', () {
    expect(_members(_links({'recheckAll'}), except: _hostLinks), {
      'lib/features/shell/session/shell_wake.dart': 1,
    }, reason: 'a recheck is a keepalive round on every link; $_seam');
  });

  test('only the known owners close host links', () {
    expect(_members(_links({'close'}), except: _hostLinks), {
      'lib/application/agents/agents.dart': 1,
      'lib/platform/herdr/agent_watcher.dart': 1,
      'lib/platform/notifications/alert_actions.dart': 1,
    }, reason: 'a close ends every link in the pool; $_seam');
  });

  test('only the named borrowers reach a lease\'s raw client', () {
    expect(
      _reads(_hostLinksUri, 'HostLease', 'client', except: _hostLinks),
      {
        'lib/platform/herdr/herdr_client.dart': 1,
        'lib/platform/vnc/vnc_tunnel.dart': 1,
      },
      reason: 'a raw client can close the connection under every lease; $_seam',
    );
  });
}
