import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../database.dart';
import '../enums.dart';

/// One attachment that does not exist yet: what the capture bar and the quick
/// view collect while a field is open, and hand over when it commits. Keeping
/// the two kinds in one list is what preserves the order they were attached in.
class NewAttachment {
  const NewAttachment(this.kind, this.value);

  const NewAttachment.url(String url) : this(AttachmentKind.url, url);
  const NewAttachment.image(String path) : this(AttachmentKind.image, path);

  final AttachmentKind kind;

  /// The URL, or the path relative to the app support directory.
  final String value;
}

/// Replaces the link repository. Attachments carry no activity
/// events: they hang off an item the stream already reports, and one capture
/// can add several at once.
///
/// File IO is deliberately absent — an image row stores a path relative to the
/// app support directory, and the copying and deleting of the file itself is
/// the picker's business, so the repository stays a database and the tests stay
/// free of platform channels.
class AttachmentRepository {
  AttachmentRepository(this._db);

  final AppDatabase _db;
  static const _uuid = Uuid();

  Stream<List<Attachment>> watchForItem(String itemId) {
    return (_db.select(_db.attachments)
          ..where((a) => a.itemId.equals(itemId))
          ..orderBy([(a) => OrderingTerm.asc(a.createdAt)]))
        .watch();
  }

  Future<List<Attachment>> forItem(String itemId) {
    return (_db.select(
      _db.attachments,
    )..where((a) => a.itemId.equals(itemId))).get();
  }

  Future<String> create({
    required String itemId,
    required AttachmentKind kind,
    required String value,
    DateTime? at,
  }) async {
    final id = _uuid.v7();
    await _db
        .into(_db.attachments)
        .insert(
          AttachmentsCompanion.insert(
            id: id,
            itemId: itemId,
            kind: kind,
            value: value,
            createdAt: at ?? DateTime.now().toUtc(),
          ),
        );
    return id;
  }

  /// How many links each item holds, keyed by item. One query for a whole
  /// screen rather than one stream per row: a panel of thirty drops would
  /// otherwise open thirty subscriptions to answer a glyph. Items with no link
  /// are absent rather than zero.
  Stream<Map<String, int>> watchLinkCounts() {
    final item = _db.attachments.itemId;
    final total = _db.attachments.id.count();
    final query = _db.selectOnly(_db.attachments)
      ..addColumns([item, total])
      ..where(_db.attachments.kind.equalsValue(AttachmentKind.url))
      ..groupBy([item]);
    return query.watch().map(
      (rows) => {for (final row in rows) row.read(item)!: row.read(total)!},
    );
  }

  Future<void> delete(String id) =>
      (_db.delete(_db.attachments)..where((a) => a.id.equals(id))).go();
}

/// What a URL attachment shows as a row or a chip: the host,
/// stripped of `www.`, falling back to the raw text when it will not parse — a
/// malformed link is still worth showing.
String attachmentLabel(Attachment attachment) {
  final uri = Uri.tryParse(attachment.value);
  final host = uri?.host ?? '';
  if (host.isEmpty) return attachment.value;
  return host.startsWith('www.') ? host.substring(4) : host;
}
