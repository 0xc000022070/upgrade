import 'package:flutter/foundation.dart';

import 'database.dart';
import 'enums.dart';
import 'repositories/note_repository.dart';
import 'repositories/project_repository.dart';
import 'repositories/task_repository.dart';

/// Debug-only fixture so the screens have something real to render. It runs the
/// same repository calls the UI does, which means the activity stream it
/// produces is genuine — the `completed` and `blocked` events below are emitted
/// by the transitions, not hand-written.
Future<void> seedDevData(
  AppDatabase db, {
  required ProjectRepository projects,
  required TaskRepository tasks,
  required NoteRepository notes,
}) async {
  if (!kDebugMode) return;
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

  /// Creates a project's tasks, then closes the first [done] of them so the
  /// audit stream carries real `completed` events rather than seeded rows.
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
