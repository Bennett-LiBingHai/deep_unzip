import 'package:flutter/material.dart';

import '../app_info.dart';
import '../engine/format.dart';
import '../theme/app_theme.dart';
import '../providers/app_state.dart';
import '../models/archive_file.dart';
import '../services/file_manager_bridge.dart';
import '../widgets/glass_card.dart';
import '../widgets/custom_button.dart';
import '../widgets/modals/confirm_extract_modal.dart';
import '../widgets/modals/path_fallback_modal.dart';
import 'file_browser_screen.dart';

/// 首页 —— 解压中心
class HomeScreen extends StatelessWidget {
  final AppState state;

  /// 打开输出目录要过原生通道。[bridge] 只给测试注入用。
  final FileManagerBridge _bridge;

  /// 文件浏览器的可用卷根。**只给测试注入用**（与 [bridge] 同一个规矩）：
  /// 真机上由浏览器自己去 `/storage` 发现；测试在宿主机上跑，那里没有
  /// `/storage`，浏览器会退到 `/` 去列宿主机真正的根目录 —— 既不确定也慢。
  /// 注一个临时目录进去，用例就落在可控的目录树上。
  // 这个名字**不带下划线**是有意的：Dart 不允许私有具名参数，而
  // `prefer_initializing_formals` 只比对「去掉下划线后是否同名」—— 叫
  // `_browserRoots` 会换来一条改不掉的假警告（与 `AppState` 里那几处同因）。
  final List<String>? browserRoots;

  HomeScreen({
    super.key,
    required this.state,
    FileManagerBridge? bridge,
    this.browserRoots,
  }) : _bridge = bridge ?? FileManagerBridge();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        return ListView(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 100),
          children: [
            _buildHeader(),
            const SizedBox(height: 16),
            if (!state.folderSelected) _buildFolderPicker(context),
            if (state.folderSelected) _buildFolderSelected(context),
            if (state.scanning) ...[
              const SizedBox(height: 16),
              _buildScanningPanel(),
            ],
            if (state.hasScanned &&
                !state.extracting &&
                !state.batchRun &&
                !state.scanning) ...[
              const SizedBox(height: 16),
              _buildScanResult(),
            ],
            if (state.extracting) ...[
              const SizedBox(height: 16),
              _buildProgressPanel(),
            ],
            // 跑过就出卡片，**没有例外**。从前这里挂的是 `completed`
            // （= 全部成功），整批都失败时卡片就不出现了 —— 关掉「错误时暂停」
            // 之后失败不再弹窗、直接记一条失败接着跑，全败变得很容易撞上，
            // 真机验收时用户点了出来。判据统一收进 `BatchOutcome`。
            if (state.batchRun) ...[
              const SizedBox(height: 16),
              _buildCompleteBanner(context),
            ],
            const SizedBox(height: 16),
            PrimaryButton(
              label: _primaryLabel,
              icon: _primaryIcon,
              disabled: _primaryDisabled,
              onPressed: () => _onStart(context),
            ),
          ],
        );
      },
    );
  }

  /// 主按钮的文案。四态：扫描中 / 停止解压 / 这批已跑过 / 待启动。
  ///
  /// **没有「继续」这一态。** 界面上唯一会「停下来」的地方是错误弹窗，而那
  /// 个弹窗自己带着「跳过 / 停止」两颗按钮 —— 用户在那儿点「跳过」就等于
  /// 接着解下一个了，主按钮没有任何机会需要承担这个语义（见 `app_state.dart`
  /// 的 `stopExtract`）。所以解压中这颗唯一有意义的动作是**停下**。
  ///
  /// 「这批已跑过」必须单独一态：那批扫描结果一旦解过，再点不会「重新解一遍」
  /// —— 输出目录重名会追加 `_1`/`_2`（见 `output_paths.dart`），等于往磁盘里
  /// 撒重复目录。所以按钮改成「更换目标」，让它去干真正有用的事。
  ///
  /// **写「目标」不写「文件夹」**：目标是文件还是文件夹由用户在浏览器里点的是
  /// 什么决定（见 [_pickTarget]），写成「更换文件夹」对选了文件的人就是句假话。
  String get _primaryLabel {
    if (state.scanning) return '正在扫描…';
    if (state.extracting) return '停止解压';
    if (state.batchRun) return '更换目标';
    return '开始解压';
  }

  IconData get _primaryIcon {
    // `stop` 而不是 `pause`：这一颗按下去队列就丢了，画成两根竖条会让人以为
    // 还能接回来（见 [_primaryLabel]）。
    if (state.extracting) return Icons.stop;
    if (state.batchRun) return Icons.folder_open;
    return Icons.play_arrow;
  }

  /// 扫描中不能重复触发（解压中那颗是「停止」，恰恰必须可点）。
  ///
  /// 「更换目标」永远可点 —— 它是脱困路径，禁用它等于把用户困在一批
  /// 已经跑过的结果里。
  bool get _primaryDisabled {
    if (state.scanning) return true;
    if (state.extracting) return false;
    if (state.batchRun) return false;
    return !state.hasScanned;
  }

  Widget _buildHeader() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            // 应用标记。**不放渐变底、也不加辉光**：图形自己就带着三张叠起来的
            // 卡片、底色和阴影，再垫一层 cyan→purple 的圆角块会让两套颜色打架。
            //
            // 资源是 `assets/logo.png`，从桌面图标那份原稿导出的 —— Android 侧
            // `res/` 下的图标 Flutter 读不到，所以另有这一份（见 pubspec 里的
            // 说明：改了一边要记得重导另一边）。
            //
            // `excludeFromSemantics`：它是装饰，右边紧跟着就是应用名，留着会被
            // 读屏软件多念一遍。
            Image.asset(
              'assets/logo.png',
              width: 44,
              height: 44,
              filterQuality: FilterQuality.medium,
              excludeFromSemantics: true,
            ),
            const SizedBox(width: 12),
            ShaderMask(
              shaderCallback: (bounds) =>
                  AppTheme.primaryGradient.createShader(bounds),
              child: const Text(
                kAppName,
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // 选路径：三个动作共用一条流程
  // ---------------------------------------------------------------------------

  /// **先拿权限，再开浏览器，最后把路径交给 state。**
  ///
  /// 顺序不能反：自建的文件浏览器是个普通页面，自己申请不了权限 —— 没权限时
  /// 它列出来的每个目录都会是「读不了」，用户会以为浏览器坏了。取消（返回
  /// `null`）则什么都不做。
  Future<Picked?> _browse(BuildContext context, FileBrowserMode mode) async {
    if (!await state.ensureStoragePermission()) {
      state.showToast('需要「所有文件访问权限」才能浏览文件', type: 'warn');
      return null;
    }
    // 权限是个 await，中间用户可能已经离开这个页面（分析器的
    // `use_build_context_synchronously` 也会拦这道）。
    if (!context.mounted) return null;
    return FileBrowserScreen.show(
      context,
      mode: mode,
      roots: browserRoots,
      startPath: _startDirFor(mode),
    );
  }

  /// 从哪儿开始浏览：接着用户当前待的地方，而不是每次都回到卷根。
  String? _startDirFor(FileBrowserMode mode) {
    if (mode == FileBrowserMode.pickOutputRoot && state.outputRoot.isNotEmpty) {
      return state.outputRoot;
    }
    return state.folderPath.isEmpty ? null : state.folderPath;
  }

  /// 选解压目标 —— 一个入口，两种结果，**由用户点的是什么决定**。
  ///
  /// 点文件行 → 只解那一个（同目录里没被选的不算，见 `AppState.selectFilePath`）；
  /// 按「选择此文件夹」 → 递归扫这个目录（`AppState.selectFolderPath`）。
  /// 浏览器已经把「点的是文件还是文件夹」判断好了（见 `Picked`），这一层不用再
  /// 拿路径去反推。
  Future<void> _pickTarget(BuildContext context) async {
    final picked = await _browse(context, FileBrowserMode.pickTarget);
    if (picked == null) return;
    if (picked.isDirectory) {
      await state.selectFolderPath(picked.path);
    } else {
      await state.selectFilePath(picked.path);
    }
  }

  Widget _buildFolderPicker(BuildContext context) {
    return GlassCard(
      onTap: () => _pickTarget(context),
      padding: const EdgeInsets.symmetric(vertical: 20),
      radius: 18,
      child: Column(
        children: [
          Container(
            width: 56,
            height: 56,
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              gradient: AppTheme.cardGradient,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: AppTheme.neonCyan.withValues(alpha: 0.2),
              ),
            ),
            child: const Icon(
              Icons.folder_open,
              color: AppTheme.neonCyan,
              size: 28,
            ),
          ),
          const Text(
            '选择目标文件 / 文件夹',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            '选文件夹递归扫描 · 选单个文件只解它\n自动识别加密 · 分卷 · 伪后缀',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              height: 1.6,
              color: AppTheme.textDim,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }

  /// 已选卡片上那颗「更换」。
  Widget _replaceButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: AppTheme.neonCyan.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppTheme.neonCyan.withValues(alpha: 0.25)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: AppTheme.neonCyan),
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                fontFamily: 'monospace',
                color: AppTheme.neonCyan,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFolderSelected(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              gradient: AppTheme.cardGradient,
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.folder, color: AppTheme.neonCyan, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  state.folderName,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  state.folderPath,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppTheme.textDim,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          // 解压中不许换目录。**这是一个真洞**，真机验收时发现的：解压是
          // `unawaited(_runExtractBatch())` 起的后台流程，跑起来之后谁也拦不住
          // 它；这时候换目录会把 `_folderPath` 和两条扫描列表全清掉重建，而批次
          // 还在按**旧**的队列往磁盘上写 —— 进度条、日志、总结卡片说的都是新目录
          // 的事，实际解的是旧目录的包。想换就等这一批停下来（主按钮左上那颗）。
          //
          // 禁用而不是隐藏：按钮忽然消失会让布局跳动，而且用户会以为界面坏了。
          // 灰掉 + 不响应，配着旁边那颗「停止解压」，路径是清楚的。
          if (state.extracting)
            const Text(
              '更换',
              style: TextStyle(fontSize: 12, color: AppTheme.textDim),
            )
          else
            _replaceButton(
              icon: Icons.sync_alt,
              label: '更换',
              onTap: () => _pickTarget(context),
            ),
        ],
      ),
    );
  }

  Widget _buildScanResult() {
    final archives = state.archives;
    final pwdCount = archives
        .where((a) => a.flags.contains(ArchiveFlag.encrypted))
        .length;
    final specialCount = archives
        .where(
          (a) =>
              a.flags.contains(ArchiveFlag.split) ||
              a.flags.contains(ArchiveFlag.fakeExtension) ||
              a.flags.contains(ArchiveFlag.nested),
        )
        .length;

    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                '扫描结果',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textPrimary,
                ),
              ),
              Text(
                '${archives.length} 个压缩包',
                style: const TextStyle(
                  fontSize: 11,
                  fontFamily: 'monospace',
                  color: AppTheme.neonCyan,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              _statItem('${archives.length}', '总文件', AppTheme.neonCyan),
              _statItem('$pwdCount', '需密码', AppTheme.neonPurple),
              _statItem('$specialCount', '特殊格式', AppTheme.neonOrange),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 200,
            child: ListView.builder(
              itemCount: archives.length,
              itemBuilder: (context, i) => _fileItem(archives[i]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statItem(String num, String label, Color color) {
    return Expanded(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 4),
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.02),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withValues(alpha: 0.04)),
        ),
        child: Column(
          children: [
            Text(
              num,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                fontFamily: 'monospace',
                color: color,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: const TextStyle(fontSize: 10, color: AppTheme.textDim),
            ),
          ],
        ),
      ),
    );
  }

  Widget _fileItem(ArchiveFile f) {
    // 用 switch 而不是 Map：这张表原先取 `typeColors[f.type]!`，给枚举加值时
    // 编译期一声不吭、运行期直接 null 崩。switch 表达式会把漏掉的分支变成
    // 编译错误 —— 下面四种压缩流就是加值的时候被它逼着补上的。
    final color = switch (f.type) {
      ArchiveType.zip => AppTheme.neonCyan,
      ArchiveType.rar => AppTheme.neonPurple,
      ArchiveType.sevenz => AppTheme.neonOrange,
      ArchiveType.tar => AppTheme.neonGreen,
      // 四种单文件压缩流与 tar 同色：颜色在这一行表达的是「非 zip/rar/7z」
      // 这一组，不是格式本身。
      ArchiveType.gzip ||
      ArchiveType.bzip2 ||
      ArchiveType.xz ||
      ArchiveType.zstd => AppTheme.neonGreen,
      // 软件包 / 光盘与磁盘映像这一大批（角标上的字由 `ArchiveFile.badge` 决定）。
      // 同样归「非 zip/rar/7z」这一组。
      ArchiveType.other => AppTheme.neonGreen,
      // 只剩真正认不出的 —— 它进不了扫描结果，红色留给不该出现的情况。
      ArchiveType.unknown => AppTheme.neonRed,
    };
    final flagMap = {
      ArchiveFlag.encrypted: ('加密', AppTheme.neonOrange),
      ArchiveFlag.split: ('分片', AppTheme.neonPurple),
      ArchiveFlag.fakeExtension: ('伪后缀', AppTheme.neonRed),
      ArchiveFlag.nested: ('嵌套', AppTheme.neonGreen),
    };

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Colors.white.withValues(alpha: 0.03)),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: color.withValues(alpha: 0.2)),
            ),
            alignment: Alignment.center,
            child: Text(
              f.typeLabel,
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w700,
                fontFamily: 'monospace',
                color: color,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  f.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: AppTheme.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${f.size} · 深度 ${f.depth}',
                  style: const TextStyle(
                    fontSize: 10,
                    color: AppTheme.textDim,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // 6 与日志页那排 tag 的间距取同一个值：两处的标签是同一种东西（9pt
          // 等宽、圆角深底），挨在一起看时不该一个松一个紧。一个包可以同时带
          // 三个角标（加密 + 分片 + 伪后缀），挤成一条就分不清是三个还是一个
          // 长词了 —— 真机上就是这么被看出来「标签粘在一起」的。
          Row(
            spacing: 6,
            children: f.flags
                .map(
                  (fl) =>
                      FlagBadge(text: flagMap[fl]!.$1, color: flagMap[fl]!.$2),
                )
                .toList(),
          ),
        ],
      ),
    );
  }

  /// 扫描中的反馈。
  ///
  /// 刻意**不用百分比**：扫描是没有分母的 —— 目录里到底有几个压缩包，
  /// 只有扫完才知道。任何「37%」都只能是编的，所以这里用不确定指示器 +
  /// 已发现数。
  Widget _buildScanningPanel() {
    return GlassCard(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Row(
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation(AppTheme.neonCyan),
                    ),
                  ),
                  SizedBox(width: 10),
                  Text(
                    '正在递归扫描',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                ],
              ),
              Text(
                '已发现 ${state.scanFound} 个',
                style: const TextStyle(
                  fontSize: 12,
                  fontFamily: 'monospace',
                  color: AppTheme.neonCyan,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: AppTheme.neonCyan.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: AppTheme.neonCyan.withValues(alpha: 0.1),
              ),
            ),
            child: Row(
              children: [
                const Icon(Icons.search, size: 15, color: AppTheme.neonCyan),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    state.scanCurrent.isEmpty ? '准备中…' : state.scanCurrent,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      color: AppTheme.neonCyan,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              GestureDetector(
                onTap: state.cancelScan,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.neonOrange.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: AppTheme.neonOrange.withValues(alpha: 0.3),
                    ),
                  ),
                  child: const Text(
                    '取消扫描',
                    style: TextStyle(fontSize: 12, color: AppTheme.neonOrange),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildProgressPanel() {
    return GlassCard(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: AppTheme.neonGreen.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.circle, size: 4, color: AppTheme.neonGreen),
                        SizedBox(width: 4),
                        Text(
                          'LIVE',
                          style: TextStyle(
                            fontSize: 9,
                            fontFamily: 'monospace',
                            color: AppTheme.neonGreen,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    '正在解压',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                ],
              ),
              Text(
                formatPercent(state.progress),
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  fontFamily: 'monospace',
                  color: AppTheme.neonCyan,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: state.progress,
              minHeight: 8,
              backgroundColor: Colors.white.withValues(alpha: 0.05),
              valueColor: const AlwaysStoppedAnimation(AppTheme.neonCyan),
            ),
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: AppTheme.neonCyan.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: AppTheme.neonCyan.withValues(alpha: 0.1),
              ),
            ),
            child: Row(
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation(AppTheme.neonCyan),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    state.currentFile,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      fontFamily: 'monospace',
                      color: AppTheme.neonCyan,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              _psItem('${state.doneCount}', '已完成'),
              _psItem(state.speed.toStringAsFixed(1), 'MB/s'),
              _psItem('${state.depth}', '递归层'),
              _psItem(state.eta, '剩余'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _psItem(String v, String l) {
    return Expanded(
      child: Column(
        children: [
          Text(
            v,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              fontFamily: 'monospace',
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 2),
          Text(l, style: const TextStyle(fontSize: 9, color: AppTheme.textDim)),
        ],
      ),
    );
  }

  /// 这一批收尾后的总结卡片。
  ///
  /// 标题**只**由 [AppState.outcome] 决定 —— 界面不再自己推「算不算完成」。
  /// 只有 `clean` 那一档配得上「全部解压完成」那张绿卡片；被停掉的、有失败
  /// 的、全砸了的，绿卡片上写「完成」都是直接骗人。
  ///
  /// 真机验收时用户要求停止后也落在这张卡片上（并且主按钮是「更换目标」），
  /// 说法是「像格式弹窗一样，不管点哪个都能跳到总结页」。
  String get _bannerTitle {
    switch (state.outcome) {
      // 卡片只在跑过之后出现（`batchRun`），所以 null 到不了这里。
      // 真到了就给个中性的说法，别写「完成」。
      case null:
        return '本批已结束';
      case BatchOutcome.clean:
        return '全部解压完成';
      case BatchOutcome.partial:
        return '部分失败';
      case BatchOutcome.allFailed:
        return '全部失败';
      case BatchOutcome.stopped:
        return '已停止';
      case BatchOutcome.errored:
        return '解压出错，已停止';
    }
  }

  Widget _buildCompleteBanner(BuildContext context) {
    // 只有「全解开」配绿色 + 勾。其余一律暖色：绿勾配「全部失败」是个
    // 自相矛盾的画面。
    final clean = state.outcome == BatchOutcome.clean;
    final accent = clean ? AppTheme.neonGreen : AppTheme.neonOrange;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            accent.withValues(alpha: 0.1),
            AppTheme.neonCyan.withValues(alpha: 0.05),
          ],
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: accent.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  // 没停止也有可能是「失败」（部分 / 全部），那两颗用圆圈惊叹号
                  // 而不是叉 —— 叉读起来像「你操作错了」，而这批包是自己坏的。
                  switch (state.outcome) {
                    BatchOutcome.clean => Icons.check_circle,
                    BatchOutcome.stopped => Icons.stop_circle,
                    _ => Icons.error_outline,
                  },
                  color: accent,
                  size: 24,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _bannerTitle,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: accent,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      state.completeDetail,
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppTheme.textDim,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          // 解压默认是「后台作业」：跑完只给你一行字，文件在哪还得自己去翻。
          // 给个直达入口 —— 打开根目录就能看到那棵与源目录对称的树。
          if (state.folderPath.isNotEmpty) ...[
            const SizedBox(height: 14),
            GestureDetector(
              onTap: () => _openOutputDir(context),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: accent.withValues(alpha: 0.3)),
                ),
                // 停下来那两档这条也要留着：已经解好的那部分是真的解好了，
                // 半路停下的人最想干的事就是去看看到底解出来了什么。
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.folder_open, size: 16, color: accent),
                    const SizedBox(width: 8),
                    Text(
                      '打开输出目录',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: accent,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 主按钮：同一个按钮在四个状态间切换语义。
  ///
  /// 原来这里是「2/5/8 秒后分别弹出密码、格式、错误三个弹窗」的假触发。
  /// 已删除：真弹窗必须由引擎在**真实事件**上驱动（P3 的 `dialog_bridge`
  /// 通过 `AppNavigator` 弹），而不是由定时器按秒表演一遍。
  Future<void> _onStart(BuildContext context) async {
    if (state.extracting) {
      state.stopExtract();
      return;
    }
    // 这批已经跑过一轮。按钮的语义是「换一个」，不是「再来一遍」—— 重跑不覆盖
    // 而是追加 `_1`/`_2`，见 [_primaryLabel]。走选择流程而不是在这里直接清状态：
    // **先选、选到了再清**，用户取消选择时原来那批结果还在
    // （`selectFolderPath`/`selectFilePath` 内部才 `_resetExtractState`）。
    if (state.batchRun) {
      await _pickTarget(context);
      return;
    }
    if (state.archives.isEmpty) {
      state.showToast('请先选择文件夹或文件并完成扫描', type: 'warn');
      return;
    }
    // 「自定义输出目录」：**在点开始解压这一刻**才选根目录（不提前、不在设置页）。
    //
    // 排在确认弹窗**之前** —— 确认弹窗上那行「输出到」得是真的，否则用户是在
    // 一个还不知道往哪写的界面上点「确认解压」。先问完位置，再让他确认。
    //
    // 从前这里还先出一页说明弹窗（「接下来选的是输出目录」）——那页存在的唯一
    // 理由是系统选择器上写不了标题。自建浏览器自己有标题、自己在页头写着
    // 「不想每次都选？可以到设置里关掉」，那一页就多余了，顺手少一次点击。
    if (state.setting('customOutput')) {
      final picked = await _browse(context, FileBrowserMode.pickOutputRoot);
      if (picked == null) {
        // 取消 = 这批不解。**要出声**：这与「用户主动去选、取消就取消」不是
        // 一回事 —— 这里是用户按了开始解压、被弹了选择、然后退出来，一声不吭
        // 的话看着就像按钮坏了。
        state.showToast('未选择输出目录，本批未执行', type: 'info');
        return;
      }
      state.setOutputRoot(picked.path);
      if (!context.mounted) return;
    }
    final archives = state.archives;
    final confirmed = await ConfirmExtractModal.show(
      context: context,
      archiveCount: archives.length,
      encryptedCount: archives
          .where((a) => a.flags.contains(ArchiveFlag.encrypted))
          .length,
      splitCount: archives
          .where((a) => a.flags.contains(ArchiveFlag.split))
          .length,
      // 「输出到」说的是**输出落在哪**：对称输出时是源**所在的目录**。选了单个
      // 文件时 `folderName` 是文件名，直接传它会让那一行写着「输出到 a.zip」。
      folderName: state.outputDirName,
      outputRoot: state.outputRoot,
    );
    // 滑掉 = false（见 ConfirmExtractModal.show）：写盘前手滑关掉不该等于同意。
    if (!confirmed) return;
    state.startExtract();
  }

  /// 请系统文件管理器打开解压出来的那棵树。
  ///
  /// 打开哪个目录取决于输出模式：
  ///
  /// - 默认（解到包旁边）：输出是**每个压缩包各自同级**的，没有单一「输出根」，
  ///   但整棵树都在所选源目录底下，所以打开 `folderPath` 就能看到。
  /// - 「自定义输出目录」：树在**用户选的根**底下，源目录那边什么都没有 ——
  ///   还打开 `folderPath` 的话，用户会对着一个空目录找半天。
  ///
  /// 只有 [OpenFolderResult.opened] 是真成功。其余几档都**必须如实告诉用户**，
  /// 尤其是 `openedGeneric` —— 它表示「文件管理器开了，但没跳到那个目录」，
  /// 国产 ROM 上是常态；假装成功的话用户会对着一个不相干的目录找半天。
  Future<void> _openOutputDir(BuildContext context) async {
    final path = state.outputRoot.isNotEmpty
        ? state.outputRoot
        : state.folderPath;
    if (path.isEmpty) return;
    final result = await _bridge.openFolder(path);
    if (!context.mounted) return;
    switch (result) {
      case OpenFolderResult.opened:
        state.showToast('已打开输出目录', type: 'ok');
      case OpenFolderResult.openedGeneric:
        await PathFallbackModal.show(
          context: context,
          headline: '无法定位到目录',
          detail:
              '文件管理器已打开，但该系统不支持直接跳转到指定目录。'
              '可复制下方路径后粘贴访问。',
          path: path,
        );
      case OpenFolderResult.unsupportedPath:
        await PathFallbackModal.show(
          context: context,
          headline: '该位置无法打开',
          detail: '该路径不在外部存储上，系统文件管理器无法定位。请使用下方路径访问。',
          path: path,
        );
      case OpenFolderResult.noHandler:
        await PathFallbackModal.show(
          context: context,
          headline: '没有可用的文件管理器',
          detail: '本设备上未找到可打开文件夹的应用。请使用下方路径访问。',
          path: path,
        );
      case OpenFolderResult.unavailable:
        await PathFallbackModal.show(
          context: context,
          headline: '当前环境不支持',
          detail:
              '打开目录依赖 Android 系统能力，当前环境不支持。'
              '请使用下方路径访问。',
          path: path,
        );
    }
  }
}
