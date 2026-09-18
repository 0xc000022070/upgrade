import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../database.dart';
import '../enums.dart';

class NewAttachment {
  const NewAttachment(this.kind, this.value);

  const NewAttachment.url(String url) : this(AttachmentKind.url, url);
  const NewAttachment.image(String path) : this(AttachmentKind.image, path);

  final AttachmentKind kind;

  final String value;
}

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

  /// Items with no attachment are absent rather than empty, and each list keeps the order
  /// the attachments were made in.
  Future<Map<String, List<Attachment>>> forItems(
    Iterable<String> itemIds,
  ) async {
    final ids = itemIds.toList();
    if (ids.isEmpty) return const {};
    final rows =
        await (_db.select(_db.attachments)
              ..where((a) => a.itemId.isIn(ids))
              ..orderBy([(a) => OrderingTerm.asc(a.createdAt)]))
            .get();
    final byItem = <String, List<Attachment>>{};
    for (final row in rows) {
      byItem.putIfAbsent(row.itemId, () => []).add(row);
    }
    return byItem;
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

  /// One query for a whole screen: a panel of thirty drops must not open thirty streams to
  /// draw a glyph. Items with no link are absent rather than zero.
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

String attachmentLabel(Attachment attachment) {
  final uri = Uri.tryParse(attachment.value);
  final host = uri?.host ?? '';
  if (host.isEmpty) return attachment.value;
  return host.startsWith('www.') ? host.substring(4) : host;
}
