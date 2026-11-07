import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/application/providers.dart';
import 'package:upgrade/data/repositories/settings_repository.dart';

enum SearchEngine {
  duckduckgo(
    'DUCKDUCKGO',
    'https://duckduckgo.com/',
    'https://duckduckgo.com/',
  ),
  brave(
    'BRAVE',
    'https://search.brave.com/',
    'https://search.brave.com/search',
  ),
  google('GOOGLE', 'https://www.google.com/', 'https://www.google.com/search'),
  bing('BING', 'https://www.bing.com/', 'https://www.bing.com/search');

  const SearchEngine(this.label, this.home, this._search);

  final String label;
  final String home;
  final String _search;

  Uri search(String query) =>
      Uri.parse(_search).replace(queryParameters: {'q': query});
}

enum BrowserBar {
  top('ABOVE'),
  bottom('BELOW');

  const BrowserBar(this.label);

  final String label;
}

final _ipv4 = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$');
final _tld = RegExp(r'\.[a-z][a-z0-9-]*\.?$');

Uri? browserTarget(String typed, SearchEngine engine) {
  final text = typed.trim();
  if (text.isEmpty) return null;
  if (!text.contains(RegExp(r'\s'))) {
    final schemed = text.contains('://');
    final uri = Uri.tryParse(schemed ? text : 'http://$text');
    if (uri != null && uri.host.isNotEmpty) {
      final host = uri.host;
      // A colon before the path is a port or an IPv6 address; Uri drops a
      // scheme's default port, so `nyx:80` would not show one.
      if (schemed ||
          text.split(RegExp('[/?#]')).first.contains(':') ||
          host == 'localhost' ||
          _ipv4.hasMatch(host) ||
          _tld.hasMatch(host)) {
        return uri;
      }
    }
  }
  return engine.search(text);
}

T _named<T extends Enum>(List<T> values, String name, T orElse) =>
    values.firstWhere((v) => v.name == name, orElse: () => orElse);

final searchEngineProvider = StreamProvider<SearchEngine>(
  (ref) => ref
      .watch(settingsRepositoryProvider)
      .watchText(
        SettingsRepository.browserEngine,
        orElse: SearchEngine.duckduckgo.name,
      )
      .map(
        (name) => _named(SearchEngine.values, name, SearchEngine.duckduckgo),
      ),
);

final browserBarProvider = StreamProvider<BrowserBar>(
  (ref) => ref
      .watch(settingsRepositoryProvider)
      .watchText(SettingsRepository.browserBar, orElse: BrowserBar.top.name)
      .map((name) => _named(BrowserBar.values, name, BrowserBar.top)),
);
