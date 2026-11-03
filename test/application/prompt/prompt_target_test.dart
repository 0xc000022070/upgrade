import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/application/agents/agent_kind.dart';
import 'package:upgrade/application/agents/agents.dart';
import 'package:upgrade/application/agents/send.dart';
import 'package:upgrade/application/prompt/prompt_target.dart';
import 'package:upgrade/application/providers.dart';
import 'package:upgrade/data/database.dart';
import 'package:upgrade/data/repositories/dispatch_repository.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/data/repositories/path_repository.dart';
import 'package:upgrade/data/repositories/settings_repository.dart';

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

final _upgrade = _at(_nyx, 'path-1', 'upgrade');
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
    final choice = saved.resolve([_upgrade, _dotfiles])!;
    expect(choice.target, same(_upgrade));
    expect(choice.kind, isA<ClaudeKind>());
    expect(saved.resolve([_dotfiles]), isNull);
    expect(
      const PromptTarget(pathId: 'path-1', agent: 'gone').resolve([_upgrade]),
      isNull,
    );
  });

  test('only directories on a multiplexed host are offered', () {
    expect(promptOffered([_upgrade, _dotfiles], [_rose]), [_dotfiles]);
    expect(promptOffered([_upgrade, _dotfiles], const []), isEmpty);
  });

  test('the label names host, directory and agent, then any model', () {
    expect(
      promptTargetLabel(SendChoice(target: _upgrade, kind: const ClaudeKind())),
      'nyx · upgrade · claude',
    );
    expect(
      promptTargetLabel(
        SendChoice(target: _upgrade, kind: const CodexKind(), model: 'gpt-5'),
      ),
      'nyx · upgrade · codex · gpt-5',
    );
  });

  test(
    'a folder name shared with another offered directory gets its parent',
    () {
      PathTarget under(String id, String directory, [String? label]) =>
          PathTarget(
            path: AgentPath(
              id: id,
              hostId: _nyx.id,
              directory: directory,
              label: label ?? defaultPathLabel(directory),
              createdAt: DateTime.utc(2026, 9, 3),
            ),
            host: _nyx,
          );
      final mine = under('a', '~/Projects/github.com/0xc000022070/upgrade');
      final fork = under('b', '~/Projects/github.com/luisnquin/upgrade/');
      expect(promptDirectoryLabel(mine, [mine, _dotfiles]), 'upgrade');
      expect(promptDirectoryLabel(mine, [mine, fork]), '0xc000022070/upgrade');
      expect(promptDirectoryLabel(fork, [mine, fork]), 'luisnquin/upgrade');
      final named = under('c', '~/work/upgrade', 'work');
      expect(
        promptDirectoryLabel(named, [named, under('d', '~/x/work')]),
        'work',
      );
    },
  );

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
        retry: noRetry,
        overrides: [
          settingsRepositoryProvider.overrideWithValue(settings),
          sendsProvider.overrideWith((ref) => Stream.value(sends)),
          pathTargetsProvider.overrideWith(
            (ref) => Stream.value([_upgrade, _dotfiles]),
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
        SendChoice(target: _upgrade, kind: const ClaudeKind()),
      );
      final container = scope([_rose]);
      await pumpEventQueue();
      expect(container.read(promptChoiceProvider), isNull);
      expect(container.read(promptSummaryProvider), isNull);
    });

    test('falls back to the newest send still offered', () async {
      final container = scope(
        [_rose],
        sends: [_sent('upgrade', 'path-1'), _sent('dotfiles', 'path-2')],
      );
      await pumpEventQueue();
      expect(container.read(promptSummaryProvider), 'rose · dotfiles · claude');
    });

    test('a saved target outranks the sends', () async {
      await savePromptTarget(
        settings,
        SendChoice(target: _upgrade, kind: const CodexKind()),
      );
      final container = scope(
        [_nyx, _rose],
        sends: [_sent('dotfiles', 'path-2')],
      );
      await pumpEventQueue();
      expect(container.read(promptSummaryProvider), 'nyx · upgrade · codex');
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
