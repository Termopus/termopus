import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A single active file transfer (computer -> phone).
class ActiveTransfer {
  final String transferId;
  final String filename;
  final int fileSize;
  final ActiveTransferStatus status;
  final double progress; // 0.0-1.0
  final String? localFilePath;
  final bool? success;
  final DateTime createdAt;

  const ActiveTransfer({
    required this.transferId,
    required this.filename,
    required this.fileSize,
    this.status = ActiveTransferStatus.offer,
    this.progress = 0.0,
    this.localFilePath,
    this.success,
    required this.createdAt,
  });

  ActiveTransfer copyWith({
    ActiveTransferStatus? status,
    double? progress,
    String? localFilePath,
    bool? success,
  }) {
    return ActiveTransfer(
      transferId: transferId,
      filename: filename,
      fileSize: fileSize,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      localFilePath: localFilePath ?? this.localFilePath,
      success: success ?? this.success,
      createdAt: createdAt,
    );
  }
}

enum ActiveTransferStatus { offer, progress, complete }

/// Provider for the active file transfers list.
final activeTransfersProvider =
    NotifierProvider<ActiveTransfersNotifier, List<ActiveTransfer>>(
  ActiveTransfersNotifier.new,
);

/// Tracks all active file transfers (offer -> progress -> complete).
class ActiveTransfersNotifier extends Notifier<List<ActiveTransfer>> {
  @override
  List<ActiveTransfer> build() => [];

  /// A new file offer arrived from the computer.
  void addOffer(String transferId, String filename, int fileSize) {
    // Dedup by transfer ID
    if (state.any((t) => t.transferId == transferId)) return;
    state = [
      ...state,
      ActiveTransfer(
        transferId: transferId,
        filename: filename,
        fileSize: fileSize,
        status: ActiveTransferStatus.offer,
        createdAt: DateTime.now(),
      ),
    ];
  }

  /// Update download progress for a transfer.
  void updateProgress(String transferId, double progress) {
    state = [
      for (final t in state)
        if (t.transferId == transferId)
          t.copyWith(status: ActiveTransferStatus.progress, progress: progress)
        else
          t,
    ];
  }

  /// Mark a transfer as complete.
  void complete(String transferId, bool success, String? localPath) {
    state = [
      for (final t in state)
        if (t.transferId == transferId)
          t.copyWith(
            status: ActiveTransferStatus.complete,
            success: success,
            localFilePath: localPath,
            progress: success ? 1.0 : t.progress,
          )
        else
          t,
    ];
  }

  /// Remove a transfer (dismiss).
  void remove(String transferId) {
    state = state.where((t) => t.transferId != transferId).toList();
  }

  /// Clear all transfers (on disconnect / session switch).
  void clear() {
    if (state.isNotEmpty) state = [];
  }
}
