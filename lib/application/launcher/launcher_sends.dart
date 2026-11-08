import 'package:upgrade/application/agents/send.dart';
import 'package:upgrade/application/agents/send_queue.dart';
import 'package:upgrade/platform/launcher_widget/launcher_widget.dart';

String launcherSendTarget(PendingSend job) =>
    [job.target.host.name, job.target.path.label, job.kind.name].join(' · ');

LauncherSend launcherRow(
  PendingSend job,
  LauncherSendState state,
  DateTime at,
) => LauncherSend(
  id: job.id,
  state: state,
  title: job.title,
  target: launcherSendTarget(job),
  at: at,
  reason: switch (job.state) {
    SendFailed(:final reason) when state == LauncherSendState.failed =>
      reason.toUpperCase(),
    _ => null,
  },
  host: job.target.host.id,
  session: state == LauncherSendState.sent ? job.sent?.session : null,
  pane: state == LauncherSendState.sent ? job.sent?.paneId : null,
);

List<LauncherSend> launcherRowsMoved(
  List<PendingSend> previous,
  List<PendingSend> next,
  Map<String, DateTime> started,
  DateTime now,
) {
  final rows = <LauncherSend>[];
  final before = {for (final job in previous) job.id: job};
  final after = {for (final job in next) job.id};
  for (final job in next) {
    final at = started.putIfAbsent(job.id, () => now);
    final state = switch (job.state) {
      SendFailed() => LauncherSendState.failed,
      _ => LauncherSendState.sending,
    };
    final was = before[job.id];
    final wasState = switch (was?.state) {
      null => null,
      SendFailed() => LauncherSendState.failed,
      _ => LauncherSendState.sending,
    };
    if (wasState != state) rows.add(launcherRow(job, state, at));
  }
  for (final job in previous) {
    if (after.contains(job.id)) continue;
    final at = started.remove(job.id) ?? now;
    if (job.state is SendFailed) continue;
    rows.add(launcherRow(job, LauncherSendState.sent, at));
  }
  return rows;
}
