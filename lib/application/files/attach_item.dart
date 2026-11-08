enum AttachStage {
  queued,
  sending,
  landed,
  pasting,
  pasted,
  path,
  failed,
  stopped,
}

final class AttachItem {
  const AttachItem({
    required this.bytes,
    this.stage = AttachStage.queued,
    this.sent = 0,
    this.detail,
    this.down = false,
  });

  final int bytes;
  final AttachStage stage;

  final int sent;
  final String? detail;

  final bool down;

  double get fraction => bytes == 0 ? 1 : sent / bytes;

  bool get settled => !const {
    AttachStage.queued,
    AttachStage.sending,
    AttachStage.landed,
    AttachStage.pasting,
  }.contains(stage);

  AttachItem to(AttachStage stage, {int? sent, String? detail, bool? down}) =>
      AttachItem(
        bytes: bytes,
        stage: stage,
        sent: sent ?? this.sent,
        detail: detail ?? this.detail,
        down: down ?? this.down,
      );
}
