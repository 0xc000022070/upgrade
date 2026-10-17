import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:striked/application/agents/agent_kind.dart';
import 'package:striked/application/agents/agents.dart';
import 'package:striked/application/agents/send.dart';
import 'package:striked/application/prompt/prompt_target.dart';
import 'package:striked/application/providers.dart';
import 'package:striked/data/database.dart';
import 'package:striked/data/repositories/dispatch_repository.dart';
import 'package:striked/data/repositories/host_repository.dart';
import 'package:striked/data/repositories/path_repository.dart';
import 'package:striked/data/repositories/settings_repository.dart';

const _nyx = Host(
  id: 'host-1',
  name: 'nyx',
  address: '100.64.0.1',
  port: 22,
  user: 'luisnquin',
  keyId: 'key-1',
);

const _rose = Host(
  id: 'host-2',
  name: 'rose',
  address: '100.64.0.2',
  port: 22,
  user: 'luisnquin',
  keyId: 'key-1',
);

PathTarget _at(Host host, String id, String label) => PathTarget(
  path: AgentPath(
    id: id,
    hostId: host.id,
    directory: '~/src/$label',
    label: label,
    createdAt: DateTime.utc(2026, 9, 3),
  ),
  host: host,
);

final _striked = _at(_nyx, 'path-1', 'striked');
final _dotfiles = _at(_rose, 'path-2', 'dotfiles');

void main() {
  test('a saved target reads back as it was written', () {
    const target = PromptTarget(
      pathId: 'path-1',
      agent: 'codex',
      model: 'gpt-5',
    );
    final back = PromptTarget.decode(target.encode())!;
    expect((back.pathId, back.agent, back.model), ('path-1', 'codex', 'gpt-5'));
    final bare = PromptTarget.decode(
      const PromptTarget(pathId: 'path-1', agent: 'claude').encode(),
    )!;
    expect(bare.model, isNull);
  });

  test('a row that does not parse is no target', () {
    for (final raw in [
      null,
      '',
      'not json',
      '[]',
      '{"path":1,"agent":"claude"}',
      '{"agent":"claude"}',
    ]) {
      expect(PromptTarget.decode(raw), isNull, reason: raw);
    }
  });

  test('a target falls away once its directory or agent is gone', () {
    const saved = PromptTarget(pathId: 'path-1', agent: 'claude');
    final choice = saved.resolve([_striked, _dotfiles])!;
    expect(choice.target, same(_striked));
    expect(choice.kind, isA<ClaudeKind>());
    expect(saved.resolve([_dotfiles]), isNull);
    expect(
      const PromptTarget(pathId: 'path-1', agent: 'gone').resolve([_striked]),
      isNull,
    );
  });

  test('only directories on a multiplexed host are offered', () {
    expect(promptOffered([_striked, _dotfiles], [_rose]), [_dotfiles]);
    expect(promptOffered([_striked, _dotfiles], const []), isEmpty);
  });

  test('the label names host, directory and agent, then any model', () {
    expect(
      promptTargetLabel(SendChoice(target: _striked, kind: const ClaudeKind())),
      'nyx · striked · claude',
    );
    expect(
      promptTargetLabel(
        SendChoice(target: _striked, kind: const CodexKind(), model: 'gpt-5'),
      ),
      'nyx · striked · codex · gpt-5',
    );
  });

  group('the saved choice', () {
    late AppDatabase db;
    late SettingsRepository settings;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      settings = SettingsRepository(db);
    });

    tearDown(() => db.close());

    ProviderContainer scope(
      List<Host> multiplexed, {
      List<Dispatch> sends = const [],
    }) {
      final container = ProviderContainer(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(settings),
          sendsProvider.overrideWith((ref) => Stream.value(sends)),
          pathTargetsProvider.overrideWith(
            (ref) => Stream.value([_striked, _dotfiles]),
          ),
          herdrHostsProvider.overrideWith((ref) => Stream.value(multiplexed)),
        ],
      );
      addTearDown(container.dispose);
      container.listen(promptSummaryProvider, (_, _) {});
      return container;
    }

    test('persists and comes back as the chip line', () async {
      final container = scope([_nyx, _rose]);
      await pumpEventQueue();
      expect(container.read(promptSummaryProvider), isNull);

      await savePromptTarget(
        settings,
        SendChoice(target: _dotfiles, kind: const CodexKind(), model: 'o3'),
      );
      await pumpEventQueue();
      expect(
        container.read(promptSummaryProvider),
        'rose · dotfiles · codex · o3',
      );
      expect(container.read(promptChoiceProvider)!.target, same(_dotfiles));
    });

    test('is none once its host has no multiplexer', () async {
      await savePromptTarget(
        settings,
        SendChoice(target: _striked, kind: const ClaudeKind()),
      );
      final container = scope([_rose]);
      await pumpEventQueue();
      expect(container.read(promptChoiceProvider), isNull);
      expect(container.read(promptSummaryProvider), isNull);
    });

    test('falls back to the newest send still offered', () async {
      final container = scope(
        [_rose],
        sends: [_sent('striked', 'path-1'), _sent('dotfiles', 'path-2')],
      );
      await pumpEventQueue();
      expect(container.read(promptSummaryProvider), 'rose · dotfiles · claude');
    });

    test('a saved target outranks the sends', () async {
      await savePromptTarget(
        settings,
        SendChoice(target: _striked, kind: const CodexKind()),
      );
      final container = scope(
        [_nyx, _rose],
        sends: [_sent('dotfiles', 'path-2')],
      );
      await pumpEventQueue();
      expect(container.read(promptSummaryProvider), 'nyx · striked · codex');
    });
  });
}

Dispatch _sent(String id, String pathId) => Dispatch(
  id: id,
  pathId: pathId,
  hostId: '',
  hostName: '',
  label: '',
  directory: '',
  agent: 'claude',
  sentAt: DateTime(2026),
);
