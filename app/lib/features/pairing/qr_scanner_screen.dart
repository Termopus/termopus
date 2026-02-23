import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../shared/constants.dart';
import '../../shared/responsive.dart';
import '../../shared/theme.dart';
import 'pairing_progress.dart';

/// QR code scanner with animated viewfinder, torch toggle, and haptic feedback.
///
/// Expected QR payload (JSON):
/// ```json
/// {
///   "v": 1,
///   "relay": "https://your-relay.example.com",
///   "session": "abc123",
///   "pubkey": "<base64 public key>",
///   "exp": 1700000000,
///   "name": "MacBook Pro"
/// }
/// ```
class QrScannerScreen extends ConsumerStatefulWidget {
  const QrScannerScreen({super.key});

  @override
  ConsumerState<QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends ConsumerState<QrScannerScreen>
    with SingleTickerProviderStateMixin {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    facing: CameraFacing.back,
  );

  late AnimationController _animController;
  late Animation<double> _scanLineAnim;
  late final StreamSubscription<BarcodeCapture> _barcodeSub;

  bool _processing = false;
  String? _error;

  double _getScanSize(BuildContext context) => context.rValue(
        mobile: 240.0,
        largeMobile: 260.0,
        tablet: 300.0,
      );

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat();
    _scanLineAnim = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeInOut),
    );
    _barcodeSub = _controller.barcodes.listen(_onDetect);
    unawaited(_controller.start());
  }

  @override
  void dispose() {
    _barcodeSub.cancel();
    _animController.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_processing) return;
    final barcode = capture.barcodes.firstOrNull;
    if (barcode == null || barcode.rawValue == null) return;

    HapticFeedback.mediumImpact();
    setState(() {
      _processing = true;
      _error = null;
    });

    _processQrData(barcode.rawValue!);
  }

  Future<void> _processQrData(String raw) async {
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;

      // ---- Validate protocol version ----
      final version = data['v'] as int?;
      if (version == null || version != AppConstants.qrProtocolVersion) {
        throw FormatException(
          'Unsupported QR version: $version '
          '(expected ${AppConstants.qrProtocolVersion})',
        );
      }

      // ---- Extract fields ----
      final relay = data['relay'] as String?;
      final sessionId = data['session'] as String?;
      final pubkey = data['pubkey'] as String?;
      final expSeconds = data['exp'] as int?;
      final name = data['name'] as String? ?? 'Unknown Computer';

      if (relay == null || sessionId == null || pubkey == null) {
        throw const FormatException('Missing required QR fields');
      }

      // ---- Check expiration ----
      if (expSeconds != null) {
        final expiration = DateTime.fromMillisecondsSinceEpoch(
          expSeconds * 1000,
        );
        if (DateTime.now().isAfter(
          expiration.add(AppConstants.qrExpirationTolerance),
        )) {
          throw const FormatException('QR code has expired');
        }
      }

      // ---- Navigate to pairing progress ----
      if (!mounted) return;

      HapticFeedback.heavyImpact();
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => PairingProgress(
            relay: relay,
            sessionId: sessionId,
            peerPublicKey: pubkey,
            computerName: name,
          ),
        ),
      );
    } catch (e) {
      HapticFeedback.vibrate();
      if (mounted) {
        setState(() {
          _processing = false;
          _error = e is FormatException
              ? e.message
              : 'Invalid QR code. Please try again.';
        });
        // Auto-clear error after 3 seconds
        Future.delayed(const Duration(seconds: 3), () {
          if (mounted && _error != null) {
            setState(() => _error = null);
          }
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.of(context).viewPadding.top;
    final bottomPadding = MediaQuery.of(context).viewPadding.bottom;
    final scanSize = _getScanSize(context);

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // ── Camera preview ──
          Positioned.fill(
            child: MobileScanner(
              controller: _controller,
            ),
          ),

          // ── Dark overlay with cutout ──
          Positioned.fill(child: _DarkOverlay(scanSize: scanSize)),

          // ── Animated corner brackets ──
          Center(
            child: SizedBox(
              width: scanSize,
              height: scanSize,
              child: _CornerBrackets(
                isProcessing: _processing,
                hasError: _error != null,
              ),
            ),
          ),

          // ── Scanning line ──
          if (!_processing)
            Center(
              child: SizedBox(
                width: scanSize - context.rValue(mobile: 24.0, tablet: 32.0),
                height: scanSize,
                child: AnimatedBuilder(
                  animation: _scanLineAnim,
                  builder: (context, _) {
                    return CustomPaint(
                      painter: _ScanLinePainter(
                        progress: _scanLineAnim.value,
                      ),
                    );
                  },
                ),
              ),
            ),

          // ── Top bar: back + title + torch ──
          Positioned(
            top: topPadding + context.rSpacing,
            left: context.rSpacing,
            right: context.rSpacing,
            child: Row(
              children: [
                _CircleButton(
                  icon: Icons.arrow_back_ios_rounded,
                  onTap: () => Navigator.of(context).pop(),
                ),
                const Spacer(),
                Text(
                  'Scan QR Code',
                  style: TextStyle(
                    fontSize: context.rFontSize(mobile: 15, tablet: 17),
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
                const Spacer(),
                ValueListenableBuilder<MobileScannerState>(
                  valueListenable: _controller,
                  builder: (_, state, __) {
                    return _CircleButton(
                      icon: state.torchState == TorchState.on
                          ? Icons.flash_on_rounded
                          : Icons.flash_off_rounded,
                      isActive: state.torchState == TorchState.on,
                      onTap: () => _controller.toggleTorch(),
                    );
                  },
                ),
              ],
            ),
          ),

          // ── Bottom panel ──
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: EdgeInsets.fromLTRB(
                context.rSpacing * 4,
                context.rSpacing * 4,
                context.rSpacing * 4,
                bottomPadding + context.rSpacing * 3,
              ),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.85),
                  ],
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Status icon
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 300),
                    child: _processing
                        ? SizedBox(
                            key: const ValueKey('loading'),
                            width: context.rValue(mobile: 26.0, tablet: 32.0),
                            height: context.rValue(mobile: 26.0, tablet: 32.0),
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              color: AppTheme.primary,
                            ),
                          )
                        : _error != null
                            ? Icon(
                                Icons.error_outline_rounded,
                                key: const ValueKey('error'),
                                color: AppTheme.error,
                                size: context.rValue(mobile: 26.0, tablet: 32.0),
                              )
                            : Icon(
                                Icons.qr_code_scanner_rounded,
                                key: const ValueKey('scan'),
                                color: Colors.white.withValues(alpha: 0.7),
                                size: context.rValue(mobile: 26.0, tablet: 32.0),
                              ),
                  ),
                  SizedBox(height: context.rSpacing * 1.75),

                  // Instructions / error text
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child: _error != null
                        ? Text(
                            _error!,
                            key: ValueKey('err:$_error'),
                            style: TextStyle(
                              fontSize: context.bodyFontSize,
                              color: AppTheme.error,
                              fontWeight: FontWeight.w500,
                            ),
                            textAlign: TextAlign.center,
                          )
                        : _processing
                            ? Text(
                                'QR code detected...',
                                key: const ValueKey('detected'),
                                style: TextStyle(
                                  fontSize: context.bodyFontSize,
                                  color: AppTheme.primary,
                                  fontWeight: FontWeight.w500,
                                ),
                                textAlign: TextAlign.center,
                              )
                            : Text(
                                'Point your camera at the QR code\nshown on your computer',
                                key: const ValueKey('instructions'),
                                style: TextStyle(
                                  fontSize: context.bodyFontSize,
                                  color: Colors.white.withValues(alpha: 0.8),
                                  height: 1.5,
                                ),
                                textAlign: TextAlign.center,
                              ),
                  ),
                  SizedBox(height: context.rSpacing),

                  // Security note
                  if (!_processing && _error == null)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.lock_rounded,
                          size: context.rValue<double>(mobile: 13.0, tablet: 15.0),
                          color: Colors.white.withValues(alpha: 0.4),
                        ),
                        SizedBox(width: context.rSpacing * 0.75),
                        Text(
                          'End-to-end encrypted',
                          style: TextStyle(
                            fontSize: context.rFontSize(mobile: 11, tablet: 13),
                            color: Colors.white.withValues(alpha: 0.4),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Semi-transparent button (back, torch)
// =============================================================================

class _CircleButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final bool isActive;

  const _CircleButton({
    required this.icon,
    required this.onTap,
    this.isActive = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: Container(
        width: context.rValue(mobile: 44.0, tablet: 50.0),
        height: context.rValue(mobile: 44.0, tablet: 50.0),
        decoration: BoxDecoration(
          color: isActive
              ? AppTheme.primary.withValues(alpha: 0.3)
              : Colors.black.withValues(alpha: 0.35),
          shape: BoxShape.circle,
        ),
        child: Icon(
          icon,
          color: isActive ? AppTheme.primary : Colors.white,
          size: context.rIconSize,
        ),
      ),
    );
  }
}

// =============================================================================
// Dark overlay with rounded cutout
// =============================================================================

class _DarkOverlay extends StatelessWidget {
  final double scanSize;

  const _DarkOverlay({required this.scanSize});

  @override
  Widget build(BuildContext context) {
    return ColorFiltered(
      colorFilter: ColorFilter.mode(
        Colors.black.withValues(alpha: 0.55),
        BlendMode.srcOut,
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: Container(
              decoration: const BoxDecoration(
                color: Colors.black,
                backgroundBlendMode: BlendMode.dstOut,
              ),
            ),
          ),
          Center(
            child: Container(
              width: scanSize,
              height: scanSize,
              decoration: BoxDecoration(
                color: Colors.red,
                borderRadius: BorderRadius.circular(20),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Animated corner brackets
// =============================================================================

class _CornerBrackets extends StatelessWidget {
  final bool isProcessing;
  final bool hasError;

  const _CornerBrackets({
    required this.isProcessing,
    required this.hasError,
  });

  @override
  Widget build(BuildContext context) {
    final color = hasError
        ? AppTheme.error
        : isProcessing
            ? AppTheme.primary
            : Colors.white;

    return CustomPaint(
      painter: _CornerPainter(color: color),
    );
  }
}

class _CornerPainter extends CustomPainter {
  final Color color;

  _CornerPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 3.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    const cornerLen = 32.0;
    const r = 12.0;
    final w = size.width;
    final h = size.height;

    // Top-left
    canvas.drawPath(
      Path()
        ..moveTo(0, cornerLen)
        ..lineTo(0, r)
        ..arcToPoint(const Offset(r, 0),
            radius: const Radius.circular(r))
        ..lineTo(cornerLen, 0),
      paint,
    );

    // Top-right
    canvas.drawPath(
      Path()
        ..moveTo(w - cornerLen, 0)
        ..lineTo(w - r, 0)
        ..arcToPoint(Offset(w, r), radius: const Radius.circular(r))
        ..lineTo(w, cornerLen),
      paint,
    );

    // Bottom-left
    canvas.drawPath(
      Path()
        ..moveTo(0, h - cornerLen)
        ..lineTo(0, h - r)
        ..arcToPoint(Offset(r, h), radius: const Radius.circular(r))
        ..lineTo(cornerLen, h),
      paint,
    );

    // Bottom-right
    canvas.drawPath(
      Path()
        ..moveTo(w - cornerLen, h)
        ..lineTo(w - r, h)
        ..arcToPoint(Offset(w, h - r), radius: const Radius.circular(r))
        ..lineTo(w, h - cornerLen),
      paint,
    );
  }

  @override
  bool shouldRepaint(_CornerPainter old) => old.color != color;
}

// =============================================================================
// Animated scanning line
// =============================================================================

class _ScanLinePainter extends CustomPainter {
  final double progress;

  _ScanLinePainter({required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height * progress;
    final opacity = math.sin(progress * math.pi) * 0.6;

    final paint = Paint()
      ..shader = LinearGradient(
        colors: [
          AppTheme.primary.withValues(alpha: 0),
          AppTheme.primary.withValues(alpha: opacity),
          AppTheme.primary.withValues(alpha: 0),
        ],
        stops: const [0.0, 0.5, 1.0],
      ).createShader(Rect.fromLTWH(0, y - 1, size.width, 2));

    canvas.drawRect(Rect.fromLTWH(0, y - 1, size.width, 2), paint);
  }

  @override
  bool shouldRepaint(_ScanLinePainter old) => old.progress != progress;
}
