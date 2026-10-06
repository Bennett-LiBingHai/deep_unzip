import 'dart:math';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// 粒子连线动态背景
class ParticleBackground extends StatefulWidget {
  const ParticleBackground({super.key});

  @override
  State<ParticleBackground> createState() => _ParticleBackgroundState();
}

class _ParticleBackgroundState extends State<ParticleBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  final List<_Particle> _particles = [];
  final Random _rng = Random();

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 10),
    )..repeat();
    for (var i = 0; i < 40; i++) {
      _particles.add(_Particle(
        x: _rng.nextDouble(),
        y: _rng.nextDouble(),
        vx: (_rng.nextDouble() - 0.5) * 0.003,
        vy: (_rng.nextDouble() - 0.5) * 0.003,
        r: _rng.nextDouble() * 1.5 + 0.5,
        cyan: _rng.nextBool(),
      ));
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        return CustomPaint(
          size: Size.infinite,
          painter: _ParticlePainter(_particles, _rng),
        );
      },
    );
  }
}

class _Particle {
  double x, y, vx, vy, r;
  bool cyan;
  _Particle({
    required this.x,
    required this.y,
    required this.vx,
    required this.vy,
    required this.r,
    required this.cyan,
  });
}

class _ParticlePainter extends CustomPainter {
  final List<_Particle> particles;
  final Random rng;
  _ParticlePainter(this.particles, this.rng);

  @override
  void paint(Canvas canvas, Size size) {
    // 更新位置
    for (final p in particles) {
      p.x += p.vx;
      p.y += p.vy;
      if (p.x < 0 || p.x > 1) p.vx *= -1;
      if (p.y < 0 || p.y > 1) p.vy *= -1;
    }

    // 画连线
    final linePaint = Paint()..strokeWidth = 0.5;
    for (var i = 0; i < particles.length; i++) {
      for (var j = i + 1; j < particles.length; j++) {
        final dx = particles[i].x - particles[j].x;
        final dy = particles[i].y - particles[j].y;
        final dist = sqrt(dx * dx + dy * dy);
        if (dist < 0.15) {
          linePaint.color = AppTheme.neonCyan.withValues(alpha: 0.08 * (1 - dist / 0.15));
          canvas.drawLine(
            Offset(particles[i].x * size.width, particles[i].y * size.height),
            Offset(particles[j].x * size.width, particles[j].y * size.height),
            linePaint,
          );
        }
      }
    }

    // 画粒子
    for (final p in particles) {
      final paint = Paint()
        ..color = (p.cyan ? AppTheme.neonCyan : AppTheme.neonPurple).withValues(alpha: 0.5);
      canvas.drawCircle(
        Offset(p.x * size.width, p.y * size.height),
        p.r,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

/// 背景光晕球
class GlowOrb extends StatelessWidget {
  final Color color;
  final double size;
  final Alignment alignment;
  final double opacity;

  const GlowOrb({
    super.key,
    required this.color,
    required this.size,
    required this.alignment,
    this.opacity = 0.35,
  });

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: alignment,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color.withValues(alpha: opacity),
          boxShadow: [
            BoxShadow(color: color.withValues(alpha: opacity), blurRadius: 80),
          ],
        ),
      ),
    );
  }
}
