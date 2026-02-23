import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../models/message.dart';
import '../../../shared/responsive.dart';
import '../../../shared/theme.dart';

/// Card displaying file transfer state: offer, progress, or complete.
class FileTransferCard extends StatelessWidget {
  final Message message;
  final VoidCallback? onAccept;
  final VoidCallback? onDecline;
  final VoidCallback? onOpen;
  final VoidCallback? onShare;

  const FileTransferCard({
    super.key,
    required this.message,
    this.onAccept,
    this.onDecline,
    this.onOpen,
    this.onShare,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: EdgeInsets.symmetric(vertical: context.rSpacing * 0.75, horizontal: context.rSpacing * 2),
      padding: EdgeInsets.all(context.rSpacing * 2),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: AppTheme.textMuted.withValues(alpha: 0.15),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildHeader(context),
          if (message.type == MessageType.fileProgress)
            _buildProgress(context),
          if (message.type == MessageType.fileOffer)
            _buildOfferActions(context),
          if (message.type == MessageType.fileComplete)
            _buildCompleteActions(context),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final icon = _iconForMime(message.mimeType ?? '');
    final sizeText = _formatSize(message.fileSize ?? 0);
    final containerSize = context.rValue(mobile: 40.0, tablet: 48.0);

    return Row(
      children: [
        Container(
          width: containerSize,
          height: containerSize,
          decoration: BoxDecoration(
            color: AppTheme.brandCyan.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, size: context.rValue(mobile: 22.0, tablet: 26.0), color: AppTheme.brandCyan),
        ),
        SizedBox(width: context.rSpacing * 1.5),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                message.fileName ?? 'Unknown file',
                style: TextStyle(
                  fontSize: context.bodyFontSize,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textPrimary,
                ),
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                sizeText,
                style: TextStyle(
                  fontSize: context.captionFontSize,
                  color: AppTheme.textMuted,
                ),
              ),
            ],
          ),
        ),
        if (message.type == MessageType.fileProgress)
          Text(
            '${((message.transferProgress ?? 0) * 100).round()}%',
            style: TextStyle(
              fontSize: context.rFontSize(mobile: 13, tablet: 15),
              fontWeight: FontWeight.w600,
              color: AppTheme.brandCyan,
            ),
          ),
        if (message.type == MessageType.fileComplete)
          Icon(
            message.transferSuccess == true
                ? Icons.check_circle_rounded
                : Icons.error_rounded,
            color: message.transferSuccess == true
                ? Colors.green
                : Colors.red,
            size: context.rValue(mobile: 22.0, tablet: 26.0),
          ),
      ],
    );
  }

  Widget _buildProgress(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(top: context.rSpacing * 1.5),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: LinearProgressIndicator(
          value: message.transferProgress ?? 0,
          backgroundColor: AppTheme.textMuted.withValues(alpha: 0.15),
          color: AppTheme.brandCyan,
          minHeight: 6,
        ),
      ),
    );
  }

  Widget _buildOfferActions(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(top: context.rSpacing * 1.5),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton(
            onPressed: () {
              HapticFeedback.selectionClick();
              onDecline?.call();
            },
            child: Text(
              'Decline',
              style: TextStyle(color: AppTheme.textMuted),
            ),
          ),
          SizedBox(width: context.rSpacing),
          FilledButton(
            onPressed: () {
              HapticFeedback.mediumImpact();
              onAccept?.call();
            },
            style: FilledButton.styleFrom(
              backgroundColor: AppTheme.brandCyan,
            ),
            child: const Text('Accept'),
          ),
        ],
      ),
    );
  }

  Widget _buildCompleteActions(BuildContext context) {
    if (message.transferSuccess != true) return const SizedBox.shrink();

    return Padding(
      padding: EdgeInsets.only(top: context.rSpacing * 1.5),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton.icon(
            onPressed: () {
              HapticFeedback.selectionClick();
              onShare?.call();
            },
            icon: Icon(Icons.share_rounded, size: context.rValue(mobile: 16.0, tablet: 18.0), color: AppTheme.textSecondary),
            label: Text('Share', style: TextStyle(color: AppTheme.textSecondary)),
          ),
          SizedBox(width: context.rSpacing),
          FilledButton.icon(
            onPressed: () {
              HapticFeedback.mediumImpact();
              onOpen?.call();
            },
            icon: Icon(Icons.open_in_new_rounded, size: context.rValue(mobile: 16.0, tablet: 18.0)),
            label: const Text('Open'),
            style: FilledButton.styleFrom(
              backgroundColor: AppTheme.brandCyan,
            ),
          ),
        ],
      ),
    );
  }

  IconData _iconForMime(String mime) {
    if (mime.startsWith('image/')) return Icons.image_rounded;
    if (mime.startsWith('video/')) return Icons.videocam_rounded;
    if (mime.startsWith('audio/')) return Icons.audiotrack_rounded;
    if (mime.contains('pdf')) return Icons.picture_as_pdf_rounded;
    if (mime.startsWith('text/')) return Icons.description_rounded;
    if (mime.contains('zip') || mime.contains('tar') || mime.contains('gz')) {
      return Icons.folder_zip_rounded;
    }
    return Icons.insert_drive_file_rounded;
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
