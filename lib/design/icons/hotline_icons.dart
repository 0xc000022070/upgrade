/// Hand-written mirror of assets/icons/hl-*.svg. Kept explicit rather than
/// generated so a missing or renamed file is a compile error, not a runtime
/// asset exception.
enum HotlineIcons {
  acknowledged('acknowledged'),
  active('active'),
  activity('activity'),
  add('add'),
  attachment('attachment'),
  back('back'),
  blocked('blocked'),
  channel('channel'),
  checkboxChecked('checkbox-checked'),
  checkboxEmpty('checkbox-empty'),
  close('close'),
  collapse('collapse'),
  connection('connection'),
  critical('critical'),
  device('device'),
  done('done'),
  edit('edit'),
  encrypted('encrypted'),
  event('event'),
  expand('expand'),
  failed('failed'),
  filter('filter'),
  forward('forward'),
  goal('goal'),
  home('home'),
  inbox('inbox'),
  message('message'),
  more('more'),
  note('note'),
  pending('pending'),
  pin('pin'),
  priority('priority'),
  progressMarker('progress-marker'),
  project('project'),
  projects('projects'),
  relay('relay'),
  search('search'),
  submit('submit'),
  sync('sync'),
  task('task'),
  vault('vault'),
  verified('verified'),
  warning('warning');

  const HotlineIcons(this.slug);

  final String slug;

  String get asset => 'assets/icons/hl-$slug.svg';

  /// SPEC.md §16b: one glitch frame swaps the icon for its nodes-only "signal"
  /// variant. Every icon in the family ships one, so this needs no fallback.
  String get signalAsset => 'assets/icons/signal/hl-$slug-signal.svg';
}
