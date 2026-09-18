String two(int value) => value.toString().padLeft(2, '0');

String timeOfDay(DateTime at) {
  final local = at.toLocal();
  return '${two(local.hour)}:${two(local.minute)}';
}

String relativeAge(DateTime at, {DateTime? now}) {
  final delta = (now ?? DateTime.now().toUtc()).difference(at);
  if (delta.inMinutes < 1) return 'now';
  if (delta.inMinutes < 60) return '${delta.inMinutes}m';
  if (delta.inHours < 24) return '${delta.inHours}h';
  if (delta.inDays < 7) return '${delta.inDays}d';
  return '${(delta.inDays / 7).floor()}w';
}
