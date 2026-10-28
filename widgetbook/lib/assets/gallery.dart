import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:widgetbook/widgetbook.dart';

import 'package:striked/design/ascii/grid.dart';
import 'package:striked/design/components/ascii_mascot.dart';
import 'package:striked/design/components/meta.dart';
import 'package:striked/design/components/section.dart';
import 'package:striked/design/components/segment_switch.dart';
import 'package:striked/design/components/striked_field.dart';
import 'package:striked/design/components/dot_spinner.dart';
import 'package:striked/design/spacing.dart';
import 'package:striked/design/tokens.dart';

enum AssetKind {
  all('ALL'),
  svg('SVG'),
  png('PNG'),
  sprite('SPRITE'),
  font('FONT'),
  data('DATA');

  const AssetKind(this.label);

  final String label;

  static AssetKind of(String path) {
    if (path.endsWith('.svg')) return svg;
    if (path.endsWith('.png')) return png;
    if (path.endsWith('.ttf') || path.endsWith('.otf')) return font;
    if (path.startsWith('assets/sprites/')) return sprite;
    return data;
  }
}

class CatalogAsset {
  const CatalogAsset({
    required this.path,
    required this.kind,
    this.variants = const [],
    this.family,
  });

  final String path;
  final AssetKind kind;

  final List<String> variants;

  final String? family;

  String get name => path.split('/').last;

  String get folder => path.substring(0, path.lastIndexOf('/'));
}

Future<List<CatalogAsset>> loadCatalogAssets() async {
  final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
  final families = <String, String>{};
  final fonts = jsonDecode(await rootBundle.loadString('FontManifest.json'));
  for (final font in fonts as List<Object?>) {
    final entry = font! as Map<String, Object?>;
    for (final file in entry['fonts']! as List<Object?>) {
      final asset = (file! as Map<String, Object?>)['asset']! as String;
      families[asset] = entry['family']! as String;
    }
  }
  final assets = [
    for (final path in manifest.listAssets())
      if (path.startsWith('assets/') && !path.endsWith('OFL.txt'))
        CatalogAsset(
          path: path,
          kind: AssetKind.of(path),
          family: families[path],
          variants: [
            for (final variant in manifest.getAssetVariants(path) ?? const [])
              if (variant.key != path) variant.key,
          ],
        ),
  ]..sort((a, b) => a.path.compareTo(b.path));
  return assets;
}

final assetUseCases = [
  WidgetbookUseCase(
    name: 'Gallery',
    builder: (context) => _Gallery(
      tile: context.knobs.double.slider(
        label: 'Tile size',
        initialValue: 132,
        min: 88,
        max: 240,
      ),
    ),
  ),
];

class _Gallery extends StatefulWidget {
  const _Gallery({required this.tile});

  final double tile;

  @override
  State<_Gallery> createState() => _GalleryState();
}

class _GalleryState extends State<_Gallery> {
  static final _assets = loadCatalogAssets();

  final _query = TextEditingController();
  AssetKind _kind = AssetKind.all;
  CatalogAsset? _picked;

  @override
  void initState() {
    super.initState();
    _query.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return ColoredBox(
      color: tokens.backgroundPrimary,
      child: FutureBuilder(
        future: _assets,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Padding(
              padding: const EdgeInsets.all(Spacing.screenEdge),
              child: Meta(
                'manifest: ${snapshot.error}',
                color: tokens.danger,
                maxLines: 4,
              ),
            );
          }
          final all = snapshot.data;
          if (all == null) return const Center(child: DotSpinner());
          final query = _query.text.trim().toLowerCase();
          final shown = [
            for (final asset in all)
              if ((_kind == AssetKind.all || asset.kind == _kind) &&
                  (query.isEmpty || asset.path.toLowerCase().contains(query)))
                asset,
          ];
          final picked = _picked;
          return Padding(
            padding: const EdgeInsets.all(Spacing.screenEdge),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.all(Spacing.md),
                  decoration: BoxDecoration(
                    color: tokens.surfacePrimary,
                    border: Border.all(
                      color: tokens.borderNormal,
                      width: Borders.hairline,
                    ),
                  ),
                  child: StrikedField(
                    controller: _query,
                    hint: 'search name or path',
                    style: tokens.value,
                  ),
                ),
                const SizedBox(height: Spacing.md),
                SegmentSwitch(
                  labels: [for (final kind in AssetKind.values) kind.label],
                  currentIndex: _kind.index,
                  onSelected: (index) =>
                      setState(() => _kind = AssetKind.values[index]),
                ),
                const SizedBox(height: Spacing.md),
                Meta('${shown.length} OF ${all.length} ASSETS'),
                const SizedBox(height: Spacing.md),
                Expanded(
                  child: shown.isEmpty
                      ? const Align(
                          alignment: Alignment.topLeft,
                          child: EmptyState('no asset matches'),
                        )
                      : GridView.builder(
                          gridDelegate:
                              SliverGridDelegateWithMaxCrossAxisExtent(
                                maxCrossAxisExtent: widget.tile,
                                mainAxisExtent: widget.tile + 52,
                                crossAxisSpacing: Spacing.md,
                                mainAxisSpacing: Spacing.md,
                              ),
                          itemCount: shown.length,
                          itemBuilder: (context, index) => _Tile(
                            asset: shown[index],
                            selected: shown[index] == picked,
                            onTap: () => setState(
                              () => _picked = shown[index] == picked
                                  ? null
                                  : shown[index],
                            ),
                          ),
                        ),
                ),
                if (picked != null) _Detail(asset: picked),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.asset,
    required this.selected,
    required this.onTap,
  });

  final CatalogAsset asset;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(Spacing.md),
              decoration: BoxDecoration(
                color: tokens.surfacePrimary,
                border: Border.all(
                  color: selected ? tokens.accent : tokens.borderSubtle,
                  width: Borders.hairline,
                ),
              ),
              child: Preview(asset: asset),
            ),
          ),
          const SizedBox(height: Spacing.xs),
          Meta(
            asset.name,
            strong: true,
            color: selected ? tokens.accent : null,
          ),
          Meta(asset.folder),
        ],
      ),
    );
  }
}

class _Detail extends StatelessWidget {
  const _Detail({required this.asset});

  final CatalogAsset asset;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final family = asset.family;
    return Container(
      margin: const EdgeInsets.only(top: Spacing.md),
      padding: const EdgeInsets.all(Spacing.panelPadding),
      decoration: BoxDecoration(
        color: tokens.surfacePrimary,
        border: Border.all(color: tokens.accent, width: Borders.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          SelectableText(asset.path, style: tokens.valueStrong),
          Meta('kind ${asset.kind.label}'),
          if (family != null) Meta('family $family'),
          for (final variant in asset.variants) Meta('variant $variant'),
        ],
      ),
    );
  }
}

class Preview extends StatelessWidget {
  const Preview({super.key, required this.asset});

  final CatalogAsset asset;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final path = asset.path;
    return switch (asset.kind) {
      AssetKind.svg => SvgPicture.asset(
        path,
        fit: BoxFit.contain,
        theme: SvgTheme(currentColor: tokens.textPrimary),
      ),
      AssetKind.png => Image.asset(
        path,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.none,
      ),
      AssetKind.sprite => FittedBox(
        child: AsciiMascot(
          state: _mascotState(path),
          colour: tokens.textSecondary,
          accent: tokens.accent,
          animated: false,
        ),
      ),
      AssetKind.font => FittedBox(
        child: Text(
          'Aa 01',
          style: TextStyle(
            fontFamily: asset.family,
            fontSize: 32,
            color: tokens.textPrimary,
          ),
        ),
      ),
      AssetKind.data || AssetKind.all => _TextHead(path: path),
    };
  }

  static String _mascotState(String path) {
    final state = path.split('/').last.replaceAll('.txt', '');
    return state == mascotCompact || mascotStates.contains(state)
        ? state
        : mascotStates.first;
  }
}

class _TextHead extends StatelessWidget {
  const _TextHead({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: rootBundle.loadString(path),
      builder: (context, snapshot) => Text(
        (snapshot.data ?? '').split('\n').take(8).join('\n'),
        style: context.tokens.capture,
        overflow: TextOverflow.fade,
      ),
    );
  }
}
