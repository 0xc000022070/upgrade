class PluginPlacementException implements Exception {
  const PluginPlacementException(this.message);

  final String message;

  @override
  String toString() => message;
}

class PluginAction {
  const PluginAction(this.id, this.title);

  final String id;
  final String title;
}

enum PluginPlacementLocation {
  homeCard('home.card', exclusive: false),
  homeComposer('home.composer', exclusive: true);

  const PluginPlacementLocation(this.id, {required this.exclusive});

  final String id;
  final bool exclusive;

  static PluginPlacementLocation? fromId(String id) {
    for (final location in values) {
      if (location.id == id) return location;
    }
    return null;
  }
}

class PluginWidgetSize {
  const PluginWidgetSize.fixed({
    required this.id,
    required this.title,
    required double width,
    this.height,
  }) : fixedWidth = width,
       minWidth = null,
       maxWidth = null;

  const PluginWidgetSize.range({
    required this.id,
    required this.title,
    required this.minWidth,
    required this.maxWidth,
    this.height,
  }) : fixedWidth = null;

  final String id;
  final String title;
  final double? fixedWidth;
  final double? minWidth;
  final double? maxWidth;
  final double? height;

  bool supportsWidth(double width) {
    final fixed = fixedWidth;
    return fixed != null
        ? width == fixed
        : width >= minWidth! && width <= maxWidth!;
  }

  double resolveWidth(double available, {double? selected}) {
    if (!available.isFinite || available <= 0) {
      throw const PluginPlacementException('Available width is invalid');
    }
    final fixed = fixedWidth;
    final width =
        fixed ?? selected ?? (available > maxWidth! ? maxWidth! : available);
    if (!supportsWidth(width) || width > available) {
      throw PluginPlacementException(unsupportedWidthMessage(width));
    }
    return width;
  }

  String unsupportedWidthMessage(double width) {
    final fixed = fixedWidth;
    final expected = fixed != null
        ? '${fixed.toStringAsFixed(0)} logical pixels'
        : '${minWidth!.toStringAsFixed(0)}-${maxWidth!.toStringAsFixed(0)} logical pixels';
    return 'Widget supports $expected, not ${width.toStringAsFixed(0)}';
  }
}

class PluginWidgetContribution {
  const PluginWidgetContribution({
    required this.id,
    required this.title,
    required this.surface,
    required this.locations,
    required this.defaultLocation,
    required this.sizes,
    required this.defaultSize,
  });

  final String id;
  final String title;
  final String surface;
  final Set<PluginPlacementLocation> locations;
  final PluginPlacementLocation defaultLocation;
  final List<PluginWidgetSize> sizes;
  final String defaultSize;

  PluginWidgetSize size(String id) =>
      sizes.singleWhere((size) => size.id == id);

  String stableId(String pluginId) => '$pluginId:widget:$id';
}

class PluginPageContribution extends PluginAction {
  const PluginPageContribution({
    required String id,
    required String title,
    this.surface,
    this.defaultPinned = false,
  }) : super(id, title);
  final String? surface;
  final bool defaultPinned;

  String stableId(String pluginId) => '$pluginId:page:$id';
}
