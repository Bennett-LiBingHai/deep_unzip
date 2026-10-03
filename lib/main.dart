import 'package:flutter/material.dart';

import 'app_navigator.dart';
import 'theme/app_theme.dart';
import 'providers/app_state.dart';
import 'screens/home_screen.dart';
import 'screens/vault_screen.dart';
import 'screens/log_screen.dart';
import 'screens/settings_screen.dart';
import 'widgets/particle_background.dart';

void main() {
  runApp(const DeepUnzipApp());
}

class DeepUnzipApp extends StatelessWidget {
  const DeepUnzipApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DeepUnzip',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      // 引擎 isolate 侧没有 BuildContext，只能靠这个 key 拿 context 弹窗。
      navigatorKey: AppNavigator.key,
      home: const MainShell(),
    );
  }
}

/// 主框架 —— 底部导航 + 动态背景
class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  final AppState _state = AppState();
  int _currentIndex = 0;

  late final List<Widget> _screens;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _screens = [
      HomeScreen(state: _state),
      VaultScreen(state: _state),
      LogScreen(state: _state),
      SettingsScreen(state: _state),
    ];
    // 切到后台时让引擎只标脏、不发进度事件。四个页面都在 IndexedStack 里，
    // 每次 notifyListeners 会重建全部四棵树 —— 界面已经不可见了，白重建。
    _lifecycle = AppLifecycleListener(
      onStateChange: (s) =>
          _state.setForeground(s == AppLifecycleState.resumed),
    );
  }

  @override
  void dispose() {
    // AppState 现在持有 worker isolate，不释放就是一个常驻线程 + 两个端口。
    _lifecycle.dispose();
    _state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgDeep,
      body: Stack(
        children: [
          // 动态背景
          const Positioned.fill(child: ParticleBackground()),
          // 光晕球
          const GlowOrb(
            color: AppTheme.neonCyan,
            size: 280,
            alignment: Alignment.topRight,
          ),
          const GlowOrb(
            color: AppTheme.neonPurple,
            size: 240,
            alignment: Alignment.bottomLeft,
            opacity: 0.25,
          ),
          // 主内容 —— SafeArea 留出手机安全空间
          SafeArea(
            child: IndexedStack(index: _currentIndex, children: _screens),
          ),
          // Toast
          ListenableBuilder(
            listenable: _state,
            builder: (context, _) {
              if (_state.toastMsg == null) return const SizedBox.shrink();
              final colors = {
                'success': AppTheme.neonGreen,
                'info': AppTheme.neonCyan,
                'warn': AppTheme.neonOrange,
              };
              final color = colors[_state.toastType] ?? AppTheme.neonCyan;
              return Positioned(
                top: MediaQuery.of(context).padding.top + 16,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: AppTheme.bgMid.withValues(alpha: 0.95),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppTheme.glassBorder),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: color,
                            boxShadow: [BoxShadow(color: color, blurRadius: 8)],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _state.toastMsg!,
                          style: const TextStyle(
                            fontSize: 13,
                            color: AppTheme.textPrimary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
      bottomNavigationBar: _buildBottomNav(),
    );
  }

  Widget _buildBottomNav() {
    final items = [
      (Icons.home_outlined, Icons.home, '解压'),
      (Icons.lock_outline, Icons.lock, '密码库'),
      (Icons.receipt_long_outlined, Icons.receipt_long, '日志'),
      (Icons.settings_outlined, Icons.settings, '设置'),
    ];

    return Container(
      decoration: BoxDecoration(
        color: AppTheme.bgDeep.withValues(alpha: 0.85),
        border: Border(
          top: BorderSide(color: AppTheme.neonCyan.withValues(alpha: 0.1)),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: List.generate(items.length, (i) {
              final active = _currentIndex == i;
              final color = active ? AppTheme.neonCyan : AppTheme.textDim;
              return GestureDetector(
                onTap: () => setState(() => _currentIndex = i),
                behavior: HitTestBehavior.opaque,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 6,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Stack(
                        clipBehavior: Clip.none,
                        children: [
                          if (active)
                            Positioned(
                              top: -10,
                              left: 0,
                              right: 0,
                              child: Center(
                                child: Container(
                                  width: 24,
                                  height: 3,
                                  decoration: BoxDecoration(
                                    gradient: AppTheme.primaryGradient,
                                    borderRadius: BorderRadius.circular(2),
                                    boxShadow: [
                                      BoxShadow(
                                        color: AppTheme.neonCyan.withValues(
                                          alpha: 0.5,
                                        ),
                                        blurRadius: 8,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          Icon(
                            active ? items[i].$2 : items[i].$1,
                            size: 22,
                            color: color,
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        items[i].$3,
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w600,
                          fontFamily: 'monospace',
                          color: color,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}
