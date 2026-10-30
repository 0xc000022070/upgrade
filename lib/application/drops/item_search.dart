import 'package:upgrade/data/views.dart';

enum SearchMark {
  attachment('ATTACHMENT'),
  image('IMAGE'),
  link('LINK'),
  prompt('PROMPT'),
  sent('SENT'),
  open('OPEN'),
  done('DONE');

  const SearchMark(this.label);

  final String label;

  bool holds(SearchHit hit) => switch (this) {
    attachment => hit.images > 0 || hit.links.isNotEmpty,
    image => hit.images > 0,
    link => hit.links.isNotEmpty,
    prompt => hit.task.prompt != null,
    sent => hit.sent,
    open => !hit.task.done,
    done => hit.task.done,
  };

  SearchMark? get excludes => switch (this) {
    open => done,
    done => open,
    _ => null,
  };
}

Set<SearchMark> toggleMark(Set<SearchMark> marks, SearchMark mark) {
  if (marks.contains(mark)) return {...marks}..remove(mark);
  return {...marks.where((lit) => lit != mark.excludes), mark};
}

bool matchesWords(SearchHit hit, String query) {
  final words = query.toLowerCase().split(RegExp(r'\s+'))
    ..removeWhere((word) => word.isEmpty);
  if (words.isEmpty) return true;
  final haystack = [
    hit.task.title,
    ?hit.task.prompt,
    ...hit.links,
  ].join('\n').toLowerCase();
  return words.every(haystack.contains);
}

List<SearchHit> searchItems(
  List<SearchHit> hits,
  String query,
  Set<SearchMark> marks,
) => [
  for (final hit in hits)
    if (matchesWords(hit, query) && marks.every((mark) => mark.holds(hit))) hit,
];
