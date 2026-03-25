import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../../core/theme/ghost_colors.dart';

class QrScannerScreen extends StatefulWidget {
  final ValueChanged<String> onResult;
  final VoidCallback onBack;

  const QrScannerScreen({
    super.key,
    required this.onResult,
    required this.onBack,
  });

  @override
  State<QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends State<QrScannerScreen> {
  final _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.normal,
    facing: CameraFacing.back,
  );
  bool _handled = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value != null && value.isNotEmpty) {
        _handled = true;
        widget.onResult(value);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final gc = context.ghostColors;

    return Scaffold(
      backgroundColor: gc.pageBase,
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
          ),
          Positioned.fill(
            child: CustomPaint(
              painter: _ScanOverlayPainter(
                borderColor: gc.accentPurple,
                overlayColor: Colors.black54,
              ),
            ),
          ),
          Positioned(
            top: MediaQuery.of(context).padding.top + 12,
            left: 16,
            child: GestureDetector(
              onTap: widget.onBack,
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: gc.card,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: gc.border),
                ),
                child: Icon(Icons.arrow_back, color: gc.textPrimary, size: 20),
              ),
            ),
          ),
          Positioned(
            bottom: MediaQuery.of(context).padding.bottom + 40,
            left: 0,
            right: 0,
            child: Text(
              'Наведи камеру на QR-код',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: gc.textSecondary,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ScanOverlayPainter extends CustomPainter {
  final Color borderColor;
  final Color overlayColor;

  _ScanOverlayPainter({required this.borderColor, required this.overlayColor});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final scanSize = size.width * 0.65;
    final scanRect = Rect.fromCenter(center: center, width: scanSize, height: scanSize);

    final overlayPath = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addRRect(RRect.fromRectAndRadius(scanRect, const Radius.circular(20)))
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(overlayPath, Paint()..color = overlayColor);

    final borderPaint = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    canvas.drawRRect(
      RRect.fromRectAndRadius(scanRect, const Radius.circular(20)),
      borderPaint,
    );

    final cornerLength = 30.0;
    final cornerPaint = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;

    final corners = [
      [scanRect.topLeft, Offset(1, 0), Offset(0, 1)],
      [scanRect.topRight, Offset(-1, 0), Offset(0, 1)],
      [scanRect.bottomLeft, Offset(1, 0), Offset(0, -1)],
      [scanRect.bottomRight, Offset(-1, 0), Offset(0, -1)],
    ];

    for (final corner in corners) {
      final point = corner[0];
      final hDir = corner[1];
      final vDir = corner[2];
      canvas.drawLine(point, point + hDir * cornerLength, cornerPaint);
      canvas.drawLine(point, point + vDir * cornerLength, cornerPaint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
