import 'package:striked/data/database.dart';

enum ProjectTaskFilter {
  open,
  next,
  blocked,
  done;

  bool matches(Task task, String query) {
    final statusMatches = switch (this) {
      open => !task.done,
      next => !task.done && task.isNext,
      blocked => !task.done && (task.blockedReason?.trim().isNotEmpty ?? false),
      done => task.done,
    };
    final needle = query.trim().toLowerCase();
    return statusMatches &&
        (needle.isEmpty ||
            task.title.toLowerCase().contains(needle) ||
            (task.blockedReason?.toLowerCase().contains(needle) ?? false));
  }
}
