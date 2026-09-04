/// Hand-written mirror of assets/icons/hl-*.svg. Kept explicit rather than
/// generated so a missing or renamed file is a compile error, not a runtime
/// asset exception.
enum HotlineIcons {
  acknowledged('acknowledged'),
  active('active'),
  activity('activity'),
  add('add'),
  arrowDown('arrow-down'),
  arrowLeft('arrow-left'),
  arrowRight('arrow-right'),
  arrowUp('arrow-up'),
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
  crop('crop'),
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
  hosts('hosts'),
  inbox('inbox'),
  keyboard('keyboard'),
  keys('keys'),
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
  superKey('super'),
  sync('sync'),
  task('task'),
  vault('vault'),
  verified('verified'),
  warning('warning');

  const HotlineIcons(this.slug);

  final String slug;

  String get asset => 'assets/icons/hl-$slug.svg';

  /// One glitch frame swaps the icon for its nodes-only "signal" variant. Only
  /// the icons a [GlitchController] is ever attached to are read this way — see
  /// `glitchIcons` — and the key strip's eight marks ship none, because none of
  /// them is ever glitched: the strip and the rail have no glitch event, and
  /// the nav bar's frames recolour the plain glyph rather than swapping it.
  String get signalAsset => 'assets/icons/signal/hl-$slug-signal.svg';
}
