import 'package:flutter/foundation.dart';

import 'package:upgrade/data/database.dart';
import 'package:upgrade/data/enums.dart';
import 'package:upgrade/data/repositories/note_repository.dart';
import 'package:upgrade/data/repositories/project_repository.dart';
import 'package:upgrade/data/repositories/task_repository.dart';

Future<void> seedDevData(
  AppDatabase db, {
  required ProjectRepository projects,
  required TaskRepository tasks,
  required NoteRepository notes,
}) async {
  const fixturesEnabled = bool.fromEnvironment('UPGRADE_SEED_FIXTURES');
  if (!kDebugMode || !fixturesEnabled) return;
  final existing = await db.select(db.projects).get();
  if (existing.isNotEmpty) return;

  final now = DateTime.now().toUtc();
  DateTime ago(Duration d) => now.subtract(d);

  final infra = await projects.create(
    name: 'Infra personal',
    description: 'Servicios propios, fuera de SaaS.',
    objective: 'Reduce SaaS dependency',
    priority: Priority.high,
    at: ago(const Duration(days: 10)),
  );
  final cuentacero = await projects.create(
    name: 'Cuentacero',
    description: 'Control de gastos personal, sin banca agregada.',
    objective: 'Build in public progress',
    priority: Priority.high,
    at: ago(const Duration(days: 10, hours: -1)),
  );
  final rommy = await projects.create(
    name: 'Rommy',
    description: 'Asistente personal con memoria propia.',
    objective: 'Ship MVP and iterate',
    at: ago(const Duration(days: 10, hours: -2)),
  );
  final dotfiles = await projects.create(
    name: 'Dotfiles',
    description: 'Configuración reproducible con Nix.',
    objective: 'Keep envs reproducible',
    priority: Priority.low,
    at: ago(const Duration(days: 10, hours: -3)),
  );
  final homelab = await projects.create(
    name: 'Homelab',
    description: 'El armario bajo las escaleras.',
    objective: 'One rack, everything on it',
    parentId: infra,
    at: ago(const Duration(days: 10, hours: -4)),
  );
  final networking = await projects.create(
    name: 'Networking',
    description: 'VLANs, DNS y el router.',
    objective: 'Segment the house',
    parentId: homelab,
    priority: Priority.low,
    at: ago(const Duration(days: 10, hours: -5)),
  );

  Future<List<String>> tasksFor(
    String projectId, {
    required List<String> titles,
    required int done,
    required Duration createdAgo,
    required Duration transitionsAgo,
  }) async {
    final ids = <String>[];
    for (var i = 0; i < titles.length; i++) {
      ids.add(
        await tasks.create(
          projectId: projectId,
          title: titles[i],
          at: ago(createdAgo - Duration(minutes: 5 * (i + 1))),
        ),
      );
    }
    for (var i = 0; i < done; i++) {
      await tasks.setDone(
        ids[i],
        true,
        at: ago(transitionsAgo - Duration(hours: 3 * i)),
      );
    }
    return ids;
  }

  await tasksFor(
    dotfiles,
    titles: const [
      'Migrar a flakes',
      'Home-manager para el shell',
      'Módulo de neovim',
      'Secrets con sops-nix',
      'Perfil para el portátil del trabajo',
    ],
    done: 4,
    createdAgo: const Duration(days: 9),
    transitionsAgo: const Duration(days: 8),
  );

  await tasksFor(
    cuentacero,
    titles: const [
      'Importar movimientos del banco',
      'Categorización automática',
      'Publicar el primer reporte',
    ],
    done: 2,
    createdAgo: const Duration(days: 8),
    transitionsAgo: const Duration(days: 7),
  );

  final rommyTasks = await tasksFor(
    rommy,
    titles: const [
      'Definir el protocolo de comandos',
      'Cliente de terminal',
      'Memoria persistente',
      'Integración con calendario',
      'Empaquetar para Nix',
    ],
    done: 1,
    createdAgo: const Duration(days: 7),
    transitionsAgo: const Duration(days: 6),
  );
  await tasks.block(
    rommyTasks[2],
    'Decidir el formato del store antes de escribirlo',
    at: ago(const Duration(days: 2, hours: 4)),
  );

  await tasksFor(
    homelab,
    titles: const [
      'Montar el rack',
      'Switch gestionable',
      'UPS para el armario',
      'Etiquetar el cableado',
    ],
    done: 3,
    createdAgo: const Duration(days: 6),
    transitionsAgo: const Duration(days: 5),
  );

  await tasksFor(
    networking,
    titles: const ['VLAN para IoT', 'DNS interno', 'Reglas de salida'],
    done: 0,
    createdAgo: const Duration(days: 4),
    transitionsAgo: const Duration(days: 4),
  );

  final infraTasks = await tasksFor(
    infra,
    titles: const [
      'Postgres propio',
      'Redis propio',
      'Object storage',
      'Backups externos',
      'Monitoring',
    ],
    done: 2,
    createdAgo: const Duration(days: 5),
    transitionsAgo: const Duration(days: 3),
  );

  for (final capture in const [
    'revisar pgbouncer',
    'idea para Rommy',
    'comprar cable USB-C',
    'probar paquete de Nix',
  ]) {
    await tasks.capture(capture, at: ago(const Duration(days: 1, hours: 6)));
  }

  await tasks.block(
    infraTasks[2],
    'Esperando proveedor S3 compatible',
    at: ago(const Duration(days: 1, hours: 2)),
  );
  await notes.create(
    content: 'Probar Garage y MinIO antes de firmar nada.',
    projectId: infra,
    taskId: infraTasks[2],
    at: ago(const Duration(days: 1, hours: 2)),
  );

  final next = await tasks.create(
    projectId: infra,
    title: 'Configurar backup externo',
    at: ago(const Duration(hours: 1)),
  );
  await tasks.setNext(next, at: ago(const Duration(hours: 1)));
}
