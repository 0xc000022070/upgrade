import 'package:flutter/widgets.dart';

import '../../application/link_preview.dart';
import '../../application/urls.dart';
import '../../design/components/meta.dart';
import '../../design/spacing.dart';
import '../../design/tokens.dart';

/// One link drawn as what is at the other end of it. Presentational only: a
/// link with no answer is not a card with nothing in it, it is the row it
/// already was, and that is decided by whoever holds the answer.
///
/// [preview] is what came back, never a placeholder.
class LinkPreviewCard extends StatelessWidget {
  const LinkPreviewCard({
    super.key,
    required this.preview,
    this.onTap,
    this.onLongPress,
  });

  final LinkPreview preview;
  final VoidCallback? onTap;

  /// Null for a URL written into the title: that text is the item, and there
  /// is nothing to detach.
  final VoidCallback? onLongPress;

  static const imageRatio = 16 / 9;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(
            color: tokens.borderNormal,
            width: Borders.hairline,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (preview.imageUrl != null) _Thumbnail(url: preview.imageUrl!),
            Padding(
              padding: const EdgeInsets.all(Spacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Meta(_source()),
                  if (preview.title != null) ...[
                    const SizedBox(height: Spacing.sm),
                    Text(
                      preview.title!,
                      style: tokens.rowTitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  if (preview.description != null) ...[
                    const SizedBox(height: Spacing.sm),
                    Text(
                      preview.description!,
                      style: tokens.rowSubtitle,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// `X.COM · FAZT`. The host leads because it is never absent and never
  /// wrong; what a page calls itself is a nicer word for the same thing.
  String _source() {
    final site = preview.siteName ?? chipLabelFor(preview.url);
    final author = preview.author;
    return (author == null ? site : '$site · $author').toUpperCase();
  }
}

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: LinkPreviewCard.imageRatio,
      child: Image.network(
        url,
        fit: BoxFit.cover,
        // Not the four thousand pixels a site is free to serve.
        cacheWidth: 1024,
        errorBuilder: (_, _, _) => const SizedBox.shrink(),
        frameBuilder: (_, child, frame, wasSynchronous) =>
            frame == null && !wasSynchronous
            ? ColoredBox(color: context.tokens.surfaceSecondary)
            : child,
      ),
    );
  }
}
