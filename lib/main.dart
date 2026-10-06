import 'dart:async';

import 'package:flutter/material.dart';

import 'app_navigator.dart';
import 'data/device_store.dart';
import 'data/persist.dart';
import 'theme/app_theme.dart';
import 'providers/app_state.dart';
import 'services/dialog_bridge.dart';
import 'screens/home_screen.dart';
import 'screens/vault_screen.dart';
import 'screens/log_screen.dart';
import 'screens/settings_screen.dart';
import 'widgets/particle_background.dart';

Future<void> main() async {
  // `DeviceStore.open()` 与后续的读都要过平台通道（path_provider、
  // shared_preferences、flutter_secure_storage），必须先起绑定。
  WidgetsFlutterBinding.ensureInitialized();

  // **先读完再 `runApp`**，而不是界面起来之后再异步补：设置、密码库、日志
  // 都是同步 getter，页面在 `build` 里直接读。异步补的话第一帧会拿默认值
  // 渲染一遍 —— 用户看到的是「开关自己跳了一下、密码库闪了一下才出来」。
  //
  // 这一步的耗时是三次本地读（不到几十毫秒），而 `DeviceStore` 内部对每一份
  // 都做了容错，读不出来就是出厂默认，不会把启动流程卡住或抛出去。
  final store = await DeviceStore.open();
  final snapshot = await store.load().timeout(
        // `DeviceStore` 内部对每一份读都做了容错（**异常**统一降级成出厂默认），
        // 但「读不回来」和「永远不回来」是两回事：平台通道要是卡住，这里就会
        // 一直等在一个不会完成的 Future 上 —— 表现是**开屏白屏、没有任何提示**，
        // 而且没有任何日志能指到这里。
        //
        // 三秒是随手定的：正常路径是三次本地读，几十毫秒。真超了，那就拿
        // 默认档先把界面开出来，用户的设置还在磁盘上，下次启动再读。
        const Duration(seconds: 3),
        onTimeout: () => AppSnapshot.empty,
      );

  runApp(DeepUnzipApp(store: store, snapshot: snapshot));
}

class DeepUnzipApp extends StatelessWidget {
  const DeepUnzipApp({
    super.key,
    required this.store,
    required this.snapshot,
  });

  final PersistStore store;
  final AppSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DeepUnzip',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      // 引擎 isolate 侧没有 BuildContext，只能靠这个 key 拿 context 弹窗。
      navigatorKey: AppNavigator.key,
      home: MainShell(store: store, snapshot: snapshot),
    );
  }
}

/// 主框架 —— 底部导航 + 动态背景
class MainShell extends StatefulWidget {
  const MainShell({super.key, required this.store, required this.snapshot});

  final PersistStore store;
  final AppSnapshot snapshot;

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  // 三个弹窗回调全在这一处注入。每一个不接的后果都是**静默降级**而不是报错
  // （见 `prompts.dart` 里各自的说明），所以这里漏掉一个不会有任何提示，
  // 只会表现成「那个弹窗从来不出现」—— 三行必须整整齐齐地在一起。
  //
  // AppState 本身不 import material，实现放在 dialog_bridge 里，
  // 这条注入就是那道边界的接缝。
  //
  // `late` 而非直接初始化：它要读 `widget`，而字段初始化器跑在 `widget` 就位
  // 之前。`late` 把它推迟到 `initState` 里第一次访问时，那里两者都在了。
  late final AppState _state = AppState(
    // 一个回调管两档：闸门拦下和解压出错共用同一个「继续 / 停止」弹窗
    // （见 services/prompts.dart 的表）。原先这里是两个，后者那条能「暂停」
    // 的路已按用户要求去掉。
    prompt: const DialogBridge().askCantExtract,
    formatPrompt: const DialogBridge().askFormatDetect,
    passwordPrompt: const DialogBridge().askPassword,
    persistStore: widget.store,
    restore: widget.snapshot,
  );
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
