import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../../core/theme/ghost_colors.dart';
import '../../data/models/vpn_state.dart';

/// grayscale(0.28) * saturate(0.7) * brightness(0.68) — pre-computed 4×5 matrix
const _kDisconnectedFilter = ColorFilter.matrix(<double>[
  0.4145, 0.2413, 0.0243, 0, 0,
  0.0717, 0.5840, 0.0244, 0, 0,
  0.0717, 0.2413, 0.3671, 0, 0,
  0, 0, 0, 1, 0,
]);

class GhostMascot extends StatefulWidget {
  final VpnStateType state;
  final VoidCallback onTap;

  const GhostMascot({super.key, required this.state, required this.onTap});

  @override
  State<GhostMascot> createState() => _GhostMascotState();
}

class _GhostMascotState extends State<GhostMascot>
    with TickerProviderStateMixin {
  static const _imgW = 130.0;
  static const _imgH = 144.0;
  static const _glowPad = 18.0;
  static const _ringPad = 10.0;

  // ── Connected ──
  late final AnimationController _floatCtrl;
  late final Animation<double> _floatAnim;
  late final AnimationController _glowCtrl;
  late final Animation<double> _glowAnim;

  // ── Connecting ──
  late final AnimationController _ringSpinCtrl;
  late final AnimationController _ringInCtrl;
  late final Animation<double> _ringInAnim;
  late final AnimationController _breatheCtrl;
  late final Animation<double> _breatheAnim;

  @override
  void initState() {
    super.initState();

    _floatCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3800),
    );
    _floatAnim = Tween(begin: 0.0, end: -7.0).animate(
      CurvedAnimation(parent: _floatCtrl, curve: Curves.easeInOut),
    );

    _glowCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2800),
    );
    _glowAnim = CurvedAnimation(parent: _glowCtrl, curve: Curves.easeInOut);

    _ringSpinCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1150),
    );

    _ringInCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _ringInAnim = CurvedAnimation(parent: _ringInCtrl, curve: Curves.easeOut);

    _breatheCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    );
    _breatheAnim =
        CurvedAnimation(parent: _breatheCtrl, curve: Curves.easeInOut);

    _applyState(widget.state);
  }

  @override
  void didUpdateWidget(GhostMascot old) {
    super.didUpdateWidget(old);
    if (old.state != widget.state) _applyState(widget.state);
  }

  void _applyState(VpnStateType s) {
    switch (s) {
      case VpnStateType.connected:
        _floatCtrl.repeat(reverse: true);
        _glowCtrl
          ..duration = const Duration(milliseconds: 2800)
          ..repeat(reverse: true);
        _ringSpinCtrl.stop();
        _ringInCtrl.value = 0;
        _breatheCtrl
          ..stop()
          ..value = 0;

      case VpnStateType.connecting:
      case VpnStateType.disconnecting:
        _floatCtrl
          ..stop()
          ..value = 0;
        _ringInCtrl.forward(from: 0);
        _ringSpinCtrl.repeat();
        _breatheCtrl.repeat(reverse: true);
        _glowCtrl
          ..duration = const Duration(milliseconds: 1100)
          ..repeat(reverse: true);

      default:
        for (final c in [_floatCtrl, _glowCtrl, _ringSpinCtrl, _breatheCtrl]) {
          c.stop();
          c.value = 0;
        }
        _ringInCtrl.value = 0;
    }
  }

  @override
  void dispose() {
    _floatCtrl.dispose();
    _glowCtrl.dispose();
    _ringSpinCtrl.dispose();
    _ringInCtrl.dispose();
    _breatheCtrl.dispose();
    super.dispose();
  }

  // ── Shared builders ──

  Widget _buildGlow(GhostColors colors) {
    return Container(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          colors: [
            colors.accent.withOpacity(0.20),
            colors.accent2.withOpacity(0.08),
            Colors.transparent,
          ],
          stops: const [0.0, 0.5, 0.7],
        ),
      ),
    );
  }

  Widget _buildImage() {
    return Image.asset(
      'assets/images/ghost_mascot.webp',
      width: _imgW,
      height: _imgH,
      fit: BoxFit.contain,
    );
  }

  // ── State builds ──

  Widget _buildConnected(GhostColors colors) {
    return Transform.translate(
      offset: Offset(0, _floatAnim.value),
      child: SizedBox(
        width: _imgW,
        height: _imgH,
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            Positioned(
              left: -_glowPad,
              top: -_glowPad,
              right: -_glowPad,
              bottom: -_glowPad,
              child: Transform.scale(
                scale: 0.96 + 0.12 * _glowAnim.value,
                child: Opacity(
                  opacity: 0.72 + 0.28 * _glowAnim.value,
                  child: _buildGlow(colors),
                ),
              ),
            ),
            _buildImage(),
          ],
        ),
      ),
    );
  }

  Widget _buildConnecting(GhostColors colors) {
    return SizedBox(
      width: _imgW,
      height: _imgH,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          Positioned(
            left: -_glowPad,
            top: -_glowPad,
            right: -_glowPad,
            bottom: -_glowPad,
            child: Transform.scale(
              scale: 0.94 + 0.14 * _breatheAnim.value,
              child: Opacity(
                opacity: 0.45 + 0.55 * _breatheAnim.value,
                child: _buildGlow(colors),
              ),
            ),
          ),
          Positioned(
            left: -_ringPad,
            top: -_ringPad,
            right: -_ringPad,
            bottom: -_ringPad,
            child: Opacity(
              opacity: _ringInAnim.value,
              child: Transform.scale(
                scale: 0.78 + 0.22 * _ringInAnim.value,
                child: Transform.rotate(
                  angle: _ringSpinCtrl.value * 2 * pi,
                  child: const CustomPaint(painter: _RingPainter()),
                ),
              ),
            ),
          ),
          Transform.scale(
            scale: 1.0 + 0.04 * _breatheAnim.value,
            child: _buildImage(),
          ),
        ],
      ),
    );
  }

  Widget _buildDisconnected(GhostColors colors) {
    return Transform.scale(
      scale: 0.96,
      child: SizedBox(
        width: _imgW,
        height: _imgH,
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            Positioned(
              left: -_glowPad,
              top: -_glowPad,
              right: -_glowPad,
              bottom: -_glowPad,
              child: Transform.scale(
                scale: 0.92,
                child: Opacity(
                  opacity: 0.18,
                  child: ImageFiltered(
                    imageFilter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                    child: _buildGlow(colors),
                  ),
                ),
              ),
            ),
            Opacity(
              opacity: 0.78,
              child: ColorFiltered(
                colorFilter: _kDisconnectedFilter,
                child: _buildImage(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.ghostColors;

    return GestureDetector(
      onTap: widget.onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: AnimatedBuilder(
          animation: Listenable.merge([
            _floatCtrl,
            _glowCtrl,
            _ringSpinCtrl,
            _ringInCtrl,
            _breatheCtrl,
          ]),
          builder: (_, __) {
            return switch (widget.state) {
              VpnStateType.connected => _buildConnected(colors),
              VpnStateType.connecting ||
              VpnStateType.disconnecting =>
                _buildConnecting(colors),
              _ => _buildDisconnected(colors),
            };
          },
        ),
      ),
    );
  }
}

// Two concentric spinning arcs matching VPN_UI.html .ghost-ring
class _RingPainter extends CustomPainter {
  const _RingPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(0, 0, size.width, size.height);

    // Base ring border
    canvas.drawOval(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = const Color.fromRGBO(124, 106, 247, 0.12),
    );

    // Outer arc — teal (top-right quarter)
    canvas.drawArc(
      rect,
      -pi / 2,
      pi / 2,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..color = const Color.fromRGBO(34, 211, 160, 0.85),
    );

    // Outer arc — purple (right-bottom quarter)
    canvas.drawArc(
      rect,
      0,
      pi / 2,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..color = const Color.fromRGBO(124, 106, 247, 0.70),
    );

    // Inner ring (8 px inset)
    final inner = rect.deflate(8);

    // Inner arc — white (top-right quarter)
    canvas.drawArc(
      inner,
      -pi / 2,
      pi / 2,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..color = const Color.fromRGBO(255, 255, 255, 0.55),
    );

    // Inner arc — cyan (left-bottom quarter)
    canvas.drawArc(
      inner,
      pi,
      pi / 2,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..color = const Color.fromRGBO(6, 182, 212, 0.55),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
