import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mime/mime.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/platform/security_channel.dart';
import '../../../core/providers/active_transfers_provider.dart';
import '../../../shared/responsive.dart';
import '../../../shared/theme.dart';

/// Top bar showing active file transfers (computer → phone).
///
/// Follows the same pattern as [ActiveAgentsBar] and [TaskProgressBar]:
/// - Collapses to zero height when no transfers exist
/// - Shows summary text when collapsed
/// - Tapping opens a bottom sheet with per-transfer details + actions
class FileTransferBar extends ConsumerWidget {
  const FileTransferBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final transfers = ref.watch(activeTransfersProvider);

    // Check if there's a single pending offer — show inline Accept/Decline
    final pendingOffers = transfers
        .where((t) => t.status == ActiveTransferStatus.offer)
        .toList();
    final hasSingleOffer = pendingOffers.length == 1 && transfers.length == 1;

    return AnimatedSize(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOut,
      child: transfers.isEmpty
          ? const SizedBox.shrink()
          : hasSingleOffer
              ? _InlineOfferBar(transfer: pendingOffers.first)
              : GestureDetector(
                  onTap: () => _showTransferSheet(context, ref, transfers),
                  child: Container(
                    width: double.infinity,
                    padding:
                        EdgeInsets.symmetric(vertical: context.rSpacing, horizontal: context.rHorizontalPadding),
                    decoration: BoxDecoration(
                      color: AppTheme.surface,
                      border: Border(
                        top: BorderSide(
                            color: Colors.white.withValues(alpha: 0.04)),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          _barIcon(transfers),
                          size: context.rValue(mobile: 16.0, tablet: 18.0),
                          color: _barColor(transfers),
                        ),
                        SizedBox(width: context.rSpacing * 1.25),
                        Expanded(
                          child: Text(
                            _summaryText(transfers),
                            style: TextStyle(
                              fontSize: context.rFontSize(mobile: 13, tablet: 15),
                              color: AppTheme.textSecondary,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Icon(
                          Icons.expand_more_rounded,
                          size: context.rValue(mobile: 18.0, tablet: 20.0),
                          color: AppTheme.textMuted,
                        ),
                      ],
                    ),
                  ),
                ),
    );
  }

  IconData _barIcon(List<ActiveTransfer> transfers) {
    if (transfers.every((t) => t.status == ActiveTransferStatus.complete)) {
      return Icons.check_circle_rounded;
    }
    if (transfers.any((t) => t.status == ActiveTransferStatus.progress)) {
      return Icons.downloading_rounded;
    }
    return Icons.file_download_rounded;
  }

  Color _barColor(List<ActiveTransfer> transfers) {
    if (transfers.every((t) => t.status == ActiveTransferStatus.complete)) {
      return Colors.green;
    }
    if (transfers.any((t) => t.status == ActiveTransferStatus.progress)) {
      return AppTheme.accent;
    }
    return AppTheme.brandCyan;
  }

  String _summaryText(List<ActiveTransfer> transfers) {
    final offers =
        transfers.where((t) => t.status == ActiveTransferStatus.offer).length;
    final downloading = transfers
        .where((t) => t.status == ActiveTransferStatus.progress)
        .length;
    final ready = transfers
        .where((t) =>
            t.status == ActiveTransferStatus.complete && t.success == true)
        .length;

    if (transfers.length == 1) {
      final t = transfers.first;
      switch (t.status) {
        case ActiveTransferStatus.offer:
          return '${t.filename} — incoming';
        case ActiveTransferStatus.progress:
          return '${t.filename} — ${(t.progress * 100).toInt()}%';
        case ActiveTransferStatus.complete:
          return t.success == true
              ? '${t.filename} — ready'
              : '${t.filename} — failed';
      }
    }

    final parts = <String>[];
    if (offers > 0) parts.add('$offers incoming');
    if (downloading > 0) parts.add('$downloading downloading');
    if (ready > 0) parts.add('$ready ready');
    return '${transfers.length} files · ${parts.join(', ')}';
  }

  void _showTransferSheet(
      BuildContext context, WidgetRef ref, List<ActiveTransfer> transfers) {
    HapticFeedback.selectionClick();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => _TransferListSheet(transfers: transfers),
    );
  }
}

/// Inline bar with Accept/Decline for a single file offer — no extra tap needed.
class _InlineOfferBar extends ConsumerWidget {
  final ActiveTransfer transfer;

  const _InlineOfferBar({required this.transfer});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(vertical: context.rSpacing, horizontal: context.rHorizontalPadding),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: 0.04)),
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.file_download_rounded,
            size: context.rValue(mobile: 16.0, tablet: 18.0),
            color: AppTheme.brandCyan,
          ),
          SizedBox(width: context.rSpacing * 1.25),
          Expanded(
            child: Text(
              transfer.filename,
              style: TextStyle(
                fontSize: context.rFontSize(mobile: 13, tablet: 15),
                color: AppTheme.textSecondary,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton(
            onPressed: () {
              HapticFeedback.selectionClick();
              SecurityChannel().cancelFileTransfer(transfer.transferId);
              ref.read(activeTransfersProvider.notifier).remove(transfer.transferId);
            },
            style: TextButton.styleFrom(
              padding: EdgeInsets.symmetric(horizontal: context.rSpacing * 1.5),
              minimumSize: Size(0, context.rValue(mobile: 32.0, tablet: 38.0)),
            ),
            child: Text('Decline',
                style: TextStyle(color: AppTheme.textMuted, fontSize: context.rFontSize(mobile: 13, tablet: 15))),
          ),
          SizedBox(width: context.rSpacing * 0.5),
          FilledButton(
            onPressed: () {
              HapticFeedback.mediumImpact();
              SecurityChannel().acceptFileTransfer(transfer.transferId);
              ref.read(activeTransfersProvider.notifier).updateProgress(transfer.transferId, 0.0);
            },
            style: FilledButton.styleFrom(
              backgroundColor: AppTheme.brandCyan,
              padding: EdgeInsets.symmetric(horizontal: context.rSpacing * 1.75, vertical: context.rSpacing * 0.75),
              minimumSize: Size(0, context.rValue(mobile: 32.0, tablet: 38.0)),
            ),
            child: Text('Accept', style: TextStyle(fontSize: context.rFontSize(mobile: 13, tablet: 15))),
          ),
        ],
      ),
    );
  }
}

/// Bottom sheet with per-transfer details and action buttons.
class _TransferListSheet extends ConsumerWidget {
  final List<ActiveTransfer> transfers;

  const _TransferListSheet({required this.transfers});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watch live state so sheet updates in real-time
    final liveTransfers = ref.watch(activeTransfersProvider);
    final displayTransfers = liveTransfers.isNotEmpty ? liveTransfers : transfers;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.6,
      ),
      decoration: const BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Drag handle
            Container(
              margin: EdgeInsets.only(top: context.rSpacing * 1.5, bottom: context.rSpacing),
              width: context.rValue(mobile: 40.0, tablet: 48.0),
              height: 4,
              decoration: BoxDecoration(
                color: AppTheme.textMuted.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // Header
            Padding(
              padding: EdgeInsets.symmetric(horizontal: context.rHorizontalPadding * 2, vertical: context.rSpacing),
              child: Row(
                children: [
                  Text(
                    'File Transfers',
                    style: TextStyle(
                      fontSize: context.rFontSize(mobile: 16, tablet: 18),
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                  const Spacer(),
                  Container(
                    padding:
                        EdgeInsets.symmetric(horizontal: context.rSpacing, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppTheme.brandCyan.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '${displayTransfers.length}',
                      style: TextStyle(
                        fontSize: context.rFontSize(mobile: 13, tablet: 15),
                        fontWeight: FontWeight.w600,
                        color: AppTheme.brandCyan,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(height: context.rSpacing * 0.5),
            // Transfer list
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                padding: EdgeInsets.only(bottom: context.rSpacing * 2),
                itemCount: displayTransfers.length,
                itemBuilder: (context, index) =>
                    _TransferTile(transfer: displayTransfers[index]),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Single transfer row with status-dependent actions.
class _TransferTile extends ConsumerWidget {
  final ActiveTransfer transfer;

  const _TransferTile({required this.transfer});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: context.rHorizontalPadding * 2, vertical: context.rSpacing),
      child: Row(
        children: [
          // Status icon
          Container(
            width: context.rValue(mobile: 36.0, tablet: 44.0),
            height: context.rValue(mobile: 36.0, tablet: 44.0),
            decoration: BoxDecoration(
              color: _statusColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(_statusIcon, size: context.rIconSize, color: _statusColor),
          ),
          SizedBox(width: context.rSpacing * 1.5),
          // File info
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  transfer.filename,
                  style: TextStyle(
                    fontSize: context.bodyFontSize,
                    fontWeight: FontWeight.w500,
                    color: AppTheme.textPrimary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                SizedBox(height: context.rSpacing * 0.25),
                if (transfer.status == ActiveTransferStatus.progress)
                  _ProgressRow(transfer: transfer)
                else
                  Text(
                    _subtitle,
                    style: TextStyle(
                        fontSize: context.captionFontSize, color: AppTheme.textMuted),
                  ),
              ],
            ),
          ),
          // Actions
          ..._buildActions(context, ref),
        ],
      ),
    );
  }

  Color get _statusColor {
    switch (transfer.status) {
      case ActiveTransferStatus.complete:
        return transfer.success == true ? Colors.green : AppTheme.error;
      case ActiveTransferStatus.progress:
        return AppTheme.accent;
      case ActiveTransferStatus.offer:
        return AppTheme.brandCyan;
    }
  }

  IconData get _statusIcon {
    switch (transfer.status) {
      case ActiveTransferStatus.complete:
        return transfer.success == true
            ? Icons.check_circle_rounded
            : Icons.error_rounded;
      case ActiveTransferStatus.progress:
        return Icons.downloading_rounded;
      case ActiveTransferStatus.offer:
        return Icons.file_download_rounded;
    }
  }

  String get _subtitle {
    final size = _formatSize(transfer.fileSize);
    switch (transfer.status) {
      case ActiveTransferStatus.offer:
        return size;
      case ActiveTransferStatus.progress:
        return '${(transfer.progress * 100).toInt()}% · $size';
      case ActiveTransferStatus.complete:
        return transfer.success == true ? 'Downloaded · $size' : 'Failed';
    }
  }

  List<Widget> _buildActions(BuildContext context, WidgetRef ref) {
    switch (transfer.status) {
      case ActiveTransferStatus.offer:
        return [
          TextButton(
            onPressed: () {
              HapticFeedback.selectionClick();
              SecurityChannel().cancelFileTransfer(transfer.transferId);
              ref
                  .read(activeTransfersProvider.notifier)
                  .remove(transfer.transferId);
              Navigator.of(context).pop();
            },
            child: Text('Decline',
                style: TextStyle(color: AppTheme.textMuted, fontSize: context.rFontSize(mobile: 13, tablet: 15))),
          ),
          SizedBox(width: context.rSpacing * 0.5),
          FilledButton(
            onPressed: () {
              HapticFeedback.mediumImpact();
              SecurityChannel().acceptFileTransfer(transfer.transferId);
              // Immediately show progress state so UI responds
              ref
                  .read(activeTransfersProvider.notifier)
                  .updateProgress(transfer.transferId, 0.0);
              Navigator.of(context).pop();
            },
            style: FilledButton.styleFrom(
              backgroundColor: AppTheme.brandCyan,
              padding:
                  EdgeInsets.symmetric(horizontal: context.rSpacing * 1.75, vertical: context.rSpacing),
            ),
            child:
                Text('Accept', style: TextStyle(fontSize: context.rFontSize(mobile: 13, tablet: 15))),
          ),
        ];

      case ActiveTransferStatus.complete:
        return [
          if (transfer.localFilePath != null && transfer.success == true) ...[
            IconButton(
              icon: Icon(Icons.share_rounded, size: context.rIconSize),
              color: AppTheme.textSecondary,
              onPressed: () {
                HapticFeedback.selectionClick();
                SharePlus.instance.share(ShareParams(files: [XFile(transfer.localFilePath!)]));
              },
            ),
            FilledButton.icon(
              icon: Icon(Icons.open_in_new_rounded, size: context.rValue(mobile: 16.0, tablet: 18.0)),
              label:
                  Text('Open', style: TextStyle(fontSize: context.rFontSize(mobile: 13, tablet: 15))),
              onPressed: () {
                HapticFeedback.mediumImpact();
                final type = lookupMimeType(transfer.localFilePath!) ?? 'application/octet-stream';
                OpenFilex.open(transfer.localFilePath!, type: type);
              },
              style: FilledButton.styleFrom(
                backgroundColor: Colors.green,
                padding: EdgeInsets.symmetric(
                    horizontal: context.rSpacing * 1.75, vertical: context.rSpacing),
              ),
            ),
          ],
          IconButton(
            icon: Icon(Icons.close_rounded, size: context.rValue(mobile: 18.0, tablet: 20.0)),
            color: AppTheme.textMuted,
            onPressed: () {
              final notifier = ref.read(activeTransfersProvider.notifier);
              notifier.remove(transfer.transferId);
              // Close sheet if this was the last transfer
              if (ref.read(activeTransfersProvider).isEmpty) {
                Navigator.of(context).pop();
              }
            },
          ),
        ];

      case ActiveTransferStatus.progress:
        return []; // Just the progress bar, no actions
    }
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}

/// Progress bar row for an active download.
class _ProgressRow extends StatelessWidget {
  final ActiveTransfer transfer;

  const _ProgressRow({required this.transfer});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: SizedBox(
            height: 3,
            child: LinearProgressIndicator(
              value: transfer.progress,
              backgroundColor: Colors.white.withValues(alpha: 0.08),
              color: AppTheme.accent,
            ),
          ),
        ),
        SizedBox(height: context.rSpacing * 0.25),
        Text(
          '${(transfer.progress * 100).toInt()}%',
          style: TextStyle(fontSize: context.rFontSize(mobile: 11, tablet: 13), color: AppTheme.textMuted),
        ),
      ],
    );
  }
}
