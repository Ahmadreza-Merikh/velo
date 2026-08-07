import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/models.dart';
import 'theme.dart';

class ConnectButton extends StatefulWidget {
  const ConnectButton({
    super.key,
    required this.phase,
    required this.progress,
    required this.caption,
    required this.onTap,
    this.diameter = 232,
  });

  final ConnectPhase phase;
  final double progress;
  final String caption;
  final VoidCallback onTap;
  final double diameter;

  @override
  State<ConnectButton> createState() => _ConnectButtonState();
}

class _ConnectButtonState extends State<ConnectButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 3),
  );

  bool _pressed = false;

  @override
  void initState() {
    super.initState();
    _syncAnimation();
  }

  @override
  void didUpdateWidget(ConnectButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncAnimation();
  }

  void _syncAnimation() {
    final bool shouldSpin = widget.phase == ConnectPhase.fetching ||
        widget.phase == ConnectPhase.testing ||
        widget.phase == ConnectPhase.connecting ||
        widget.phase == ConnectPhase.disconnecting;
    if (shouldSpin && !_spin.isAnimating) {
      _spin.repeat();
    } else if (!shouldSpin && _spin.isAnimating) {
      _spin.stop();
      _spin.value = 0;
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  Color get _ringColor {
    switch (widget.phase) {
      case ConnectPhase.connected:
        return VeloColors.connected;
      case ConnectPhase.error:
        return VeloColors.danger;
      case ConnectPhase.fetching:
      case ConnectPhase.testing:
      case ConnectPhase.connecting:
      case ConnectPhase.disconnecting:
        return VeloColors.accent;
      case ConnectPhase.idle:
        return VeloColors.idle;
    }
  }

  String get _label {
    switch (widget.phase) {
      case ConnectPhase.connected:
        return 'CONNECTED';
      case ConnectPhase.connecting:
        return 'CONNECTING';
      case ConnectPhase.fetching:
        return 'SCANNING';
      case ConnectPhase.testing:
        return 'TESTING';
      case ConnectPhase.disconnecting:
        return 'STOPPING';
      case ConnectPhase.error:
        return 'RETRY';
      case ConnectPhase.idle:
        return 'CONNECT';
    }
  }

  IconData get _icon {
    switch (widget.phase) {
      case ConnectPhase.connected:
        return Icons.shield_outlined;
      case ConnectPhase.error:
        return Icons.refresh;
      default:
        return Icons.power_settings_new;
    }
  }

  @override
  Widget build(BuildContext context) {
    final double size = widget.diameter;

    return Semantics(
      button: true,
      label: '$_label. ${widget.caption}',
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapCancel: () => setState(() => _pressed = false),
        onTapUp: (_) => setState(() => _pressed = false),
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _pressed ? 0.96 : 1,
          duration: const Duration(milliseconds: 120),
          child: SizedBox(
            width: size,
            height: size,
            child: AnimatedBuilder(
              animation: _spin,
              builder: (BuildContext context, Widget? child) {
                return CustomPaint(
                  painter: _RingPainter(
                    color: _ringColor,
                    progress: widget.progress,
                    sweepPhase: _spin.value,
                    spinning: _spin.isAnimating,
                  ),
                  child: child,
                );
              },
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(_icon, size: 46, color: _ringColor),
                    const SizedBox(height: 10),
                    Text(
                      _label,
                      style: const TextStyle(
                        color: VeloColors.textPrimary,
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.6,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 34),
                      child: Text(
                        widget.caption,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: VeloColors.textMuted,
                          fontSize: 12,
                          height: 1.3,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.color,
    required this.progress,
    required this.sweepPhase,
    required this.spinning,
  });

  final Color color;
  final double progress;
  final double sweepPhase;
  final bool spinning;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset center = Offset(size.width / 2, size.height / 2);
    final double radius = math.min(size.width, size.height) / 2;
    const double stroke = 12;
    final Rect ringRect = Rect.fromCircle(
      center: center,
      radius: radius - stroke / 2,
    );

    final Paint glow = Paint()
      ..style = PaintingStyle.fill
      ..shader = RadialGradient(
        colors: <Color>[
          Color.lerp(VeloColors.background, color, 0.28) ?? color,
          VeloColors.background,
        ],
        stops: const <double>[0.55, 1],
      ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawCircle(center, radius, glow);

    final Paint disc = Paint()
      ..style = PaintingStyle.fill
      ..color = VeloColors.surface;
    canvas.drawCircle(center, radius - stroke, disc);

    final Paint track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = const Color(0xFF232C48);
    canvas.drawArc(ringRect, 0, math.pi * 2, false, track);

    final Paint active = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = color;

    if (spinning) {
      final double start = (sweepPhase * math.pi * 2) - math.pi / 2;
      final double sweep = progress > 0
          ? math.max(progress * math.pi * 2, 0.35)
          : math.pi * 0.6;
      canvas.drawArc(ringRect, start, sweep, false, active);
    } else if (progress > 0) {
      final double sweep = progress > 1 ? 1 : progress;
      canvas.drawArc(
        ringRect,
        -math.pi / 2,
        sweep * math.pi * 2,
        false,
        active,
      );
    } else {
      canvas.drawArc(ringRect, 0, math.pi * 2, false, active);
    }
  }

  @override
  bool shouldRepaint(_RingPainter oldDelegate) {
    return oldDelegate.color != color ||
        oldDelegate.progress != progress ||
        oldDelegate.sweepPhase != sweepPhase ||
        oldDelegate.spinning != spinning;
  }
}
