import 'package:flutter/material.dart';

/// 应用主题 —— 深色科技风 + 玻璃拟态 + 霓虹渐变
class AppTheme {
  // 基础色
  static const Color bgDeep = Color(0xFF050810);
  static const Color bgMid = Color(0xFF0A0F1E);
  static const Color glass = Color(0x8C0F162A);
  static const Color glassBorder = Color(0x2600F0FF);
  static const Color glassHighlight = Color(0x0FFFFFFF);

  // 霓虹色
  static const Color neonCyan = Color(0xFF00F0FF);
  static const Color neonPurple = Color(0xFFA855F7);
  static const Color neonPink = Color(0xFFEC4899);
  static const Color neonGreen = Color(0xFF22D39E);
  static const Color neonOrange = Color(0xFFFB923C);
  static const Color neonRed = Color(0xFFF43F5E);

  // 文字色
  static const Color textPrimary = Color(0xFFE8F0FF);
  static const Color textSecondary = Color(0xFF8B9CC0);
  static const Color textDim = Color(0xFF4A5A7A);

  // 渐变
  static const LinearGradient primaryGradient = LinearGradient(
    colors: [neonCyan, neonPurple],
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
  );
  static const LinearGradient cardGradient = LinearGradient(
    colors: [Color(0x1A00F0FF), Color(0x1AA855F7)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  /// 不可逆操作的确认按钮（清空日志、删密码）。比 [neonRed] 亮一档：纯色实心
  /// 在深底上发闷，看不出是一颗按钮。
  ///
  /// 提到这一层是在出现**第二处**用的时候（清空日志 → 删密码），与当初把它留在
  /// `clear_logs_modal.dart` 里的理由（「只有这一处用」）是同一条规矩的两头。
  static const LinearGradient dangerGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [neonRed, Color(0xFFFF7A8A)],
  );

  static ThemeData get dark {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: bgDeep,
      colorScheme: const ColorScheme.dark(
        primary: neonCyan,
        secondary: neonPurple,
        surface: bgMid,
        error: neonRed,
      ),
      textTheme: const TextTheme(
        headlineLarge: TextStyle(
          color: textPrimary,
          fontWeight: FontWeight.w700,
          fontSize: 22,
        ),
        titleLarge: TextStyle(
          color: textPrimary,
          fontWeight: FontWeight.w700,
          fontSize: 20,
        ),
        titleMedium: TextStyle(
          color: textPrimary,
          fontWeight: FontWeight.w600,
          fontSize: 15,
        ),
        bodyLarge: TextStyle(color: textPrimary, fontSize: 14),
        bodyMedium: TextStyle(color: textSecondary, fontSize: 12),
        bodySmall: TextStyle(color: textDim, fontSize: 10),
        labelSmall: TextStyle(color: textDim, fontSize: 9),
      ),
      fontFamily: 'monospace',
    );
  }

  // 玻璃卡片装饰
  static BoxDecoration glassDecoration({double radius = 18}) {
    return BoxDecoration(
      color: glass,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: glassBorder, width: 1),
    );
  }

  // 霓虹发光
  static List<BoxShadow> neonGlow(Color color, {double blur = 24}) {
    return [BoxShadow(color: color.withValues(alpha: 0.35), blurRadius: blur)];
  }
}
