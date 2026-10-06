import 'package:flutter/material.dart';

import '../../services/password_prompt.dart';
import '../../theme/app_theme.dart';
import 'bottom_modal.dart';
import 'modal_button.dart';

/// 「这个包需要密码，密码库没试出来」—— 停下 / 跳过 / 手动输入。
///
/// ## 为什么不是原来那个「密码自动匹配」
///
/// 原来这个弹窗是**装饰性的**：自己 500ms 一跳、随机挑一行显示「匹配成功」
/// （`DateTime.now().millisecond % passwords.length`，空库还会除零崩），两颗
/// 按钮干的是同一件事（都只是关掉自己）。它演的是「密码库在试」，而真的在试
/// 密码库的是别处。
///
/// 现在它是这条路上**唯一的出口**：密码库真试过、真没通过，才轮到它。所以
/// 它有两件事必须做对：
///
/// 1. **手输密码错了要留在原地**（用户明确要求）。原来那套「演一遍就关掉」的
///    骨架上加不出这个行为 —— 关掉之后外面拿不到任何结果，用户以为自己在
///    输入，其实什么都没发生。
/// 2. **手输密码要真的验**。验证走 [PasswordAsk.verify]，实现在 `AppState`
///    那边（要引擎）。验过的那一刻包已经解完了，所以这里只管关窗。
class PasswordAttemptModal extends StatefulWidget {
  final PasswordAsk ask;

  /// 用户手敲的密码**验过了**。带上密码本身，方便调用方记账／询问是否入库。
  final void Function(String password) onManual;
  final VoidCallback onSkip;
  final VoidCallback onStop;

  const PasswordAttemptModal({
    super.key,
    required this.ask,
    required this.onManual,
    required this.onSkip,
    required this.onStop,
  });

  static Future<void> show({
    required BuildContext context,
    required PasswordAsk ask,
    required void Function(String password) onManual,
    required VoidCallback onSkip,
    required VoidCallback onStop,
  }) {
    return showBottomModal(
      context: context,
      child: PasswordAttemptModal(
        ask: ask,
        onManual: onManual,
        onSkip: onSkip,
        onStop: onStop,
      ),
    );
  }

  @override
  State<PasswordAttemptModal> createState() => _PasswordAttemptModalState();
}

/// 上一次提交为什么没成。**这两种必须分得开**：
///
/// - `emptyInput`：输入框空着就点了确认，一次 [PasswordAsk.verify] 都没跑过。
/// - `rejected`：真拿这个密码解了一遍，没解开。
///
/// 原先是一个 `bool _failed` 把两者混成一种，于是「没通过」这类**断言试过**
/// 的说法会挂到一次并不存在的尝试上。这一屏对「说不清是密码错还是文件坏」的
/// 包要说新文案，而那句话只对 `rejected` 成立。
enum _Failure {
  emptyInput,
  rejected,
}

class _PasswordAttemptModalState extends State<PasswordAttemptModal> {
  /// 手输那一屏。**不是另一个弹窗**：用户要求输错了留在原地，换弹窗会把这句
  /// 话的落点从「同一屏」变成「同一层」，滑回去的路也就多了一条。
  bool _manual = false;

  /// 正在验。验的时候按钮上写「验证中…」，避免连点。
  bool _checking = false;

  /// 上一次提交没成，以及**为什么**。留着不清：用户要看着那句话才知道自己
  /// 不是手滑。开始重输时才收掉（见输入框的 `onChanged`）。
  _Failure? _failed;

  /// 明文显示。默认遮住 —— 但用户得有机会看一眼自己敲了什么，尤其是手机上
  /// 打错一个字符时那种「明明是对的」。
  bool _reveal = false;

  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_checking) return;
    final pwd = _controller.text;
    if (pwd.isEmpty) {
      // 空密码不可能对上任何加密包，但也不该悄悄当「没输」丢掉 —— 用户按了
      // 「确认」，得有一句回应。
      setState(() => _failed = _Failure.emptyInput);
      return;
    }

    setState(() {
      _checking = true;
      _failed = null;
    });
    final ok = await widget.ask.verify(pwd);
    // verify 是一趟真解压，回来时这一屏可能已经被滑掉/被 `stop` 关掉了。
    if (!mounted) return;

    if (ok) {
      // 先 pop 再回调，与 `ErrorModal` 的写法一致；桥接层那边 `finish` 有
      // 「只完成一次」的守卫，所以谁先谁后都不会丢结果。
      Navigator.pop(context);
      widget.onManual(pwd);
      return;
    }
    // **留在原地**。这一句是这个弹窗存在的理由之一。
    setState(() {
      _checking = false;
      _failed = _Failure.rejected;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ..._buildHeader(),
          const SizedBox(height: 18),
          if (_manual) ..._buildManual() else ..._buildChoice(),
        ],
      ),
    );
  }

  List<Widget> _buildHeader() {
    return [
      Row(
        children: [
          const Icon(Icons.lock_outline, color: AppTheme.neonCyan, size: 20),
          const SizedBox(width: 10),
          const Text(
            '需要密码',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: AppTheme.textPrimary,
            ),
          ),
        ],
      ),
      const SizedBox(height: 6),
      // 说不清的那一档（7z 的内容加密、RAR3）不能只说「密码库没能解开」——
      // 那读起来就是在说「密码的事」，而我们并不知道坏的是不是文件本身。
      // 同一句话里把两种可能并列摆出来，并且明说我们分不出来。
      Text(
        widget.ask.uncertain
            ? '密码库未能解开该压缩包，也可能是文件已损坏，两者无法区分'
            : '密码库未能解开该压缩包',
        style: const TextStyle(
          fontSize: 12,
          color: AppTheme.textDim,
          fontFamily: 'monospace',
        ),
      ),
      const SizedBox(height: 14),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppTheme.neonCyan.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.neonCyan.withValues(alpha: 0.15)),
        ),
        child: Text(
          widget.ask.fileName,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 12,
            fontFamily: 'monospace',
            color: AppTheme.neonCyan,
          ),
        ),
      ),
    ];
  }

  // ---------------------------------------------------------------------------
  // 选择那一屏
  // ---------------------------------------------------------------------------

  List<Widget> _buildChoice() {
    return [
      Text(
        widget.ask.triedCount == 0
            ? '密码库为空，无可用密码'
            : '密码库中的 ${widget.ask.triedCount} 个密码均未通过',
        style: const TextStyle(
          fontSize: 12,
          color: AppTheme.textSecondary,
          height: 1.5,
        ),
      ),
      // 试过的那几条**一条都不摆**。
      //
      // 原先这里是「•」×长度 + 右边一句「不匹配」，一排最多四条、超了折成
      // 「…还有 N 个」。那排东西读不出任何信息：**这一屏上的每一条都必然是
      // 不匹配的**（有一条对得上，包早就解开了，压根走不到这里），所以「不匹
      // 配」这四个字是恒真的废话，而那几个点连长短都被 `clamp(4, 12)` 压平了
      // ——长度不同的密码看起来一样。用户看到的是一屏长得差不多的点，然后才
      // 轮到真正要他做的事。原话：「每条都是加密的点号，没参考意义」。
      //
      // 留下来的是上面那句**个数**：它区分「空库」与「试过 N 条」，那才是用户
      // 要知道的。要翻看库里到底有什么，出门右转是密码库页面。
      const SizedBox(height: 18),
      ModalButton(
        label: '手动输入密码',
        color: AppTheme.neonCyan,
        onTap: () => setState(() {
          _manual = true;
          _failed = null;
        }),
      ),
      const SizedBox(height: 10),
      Row(
        children: [
          // 「停止」在左、暖色，与 `ErrorModal` 同一条：点了哪颗决定整批活儿
          // 还在不在，所以名字要吓人一点、颜色要退后一点。
          Expanded(
            child: ModalButton(
              label: '停止解压',
              color: AppTheme.neonOrange,
              onTap: () {
                Navigator.pop(context);
                widget.onStop();
              },
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: ModalButton(
              label: '跳过',
              gradient: AppTheme.primaryGradient,
              onTap: () {
                Navigator.pop(context);
                widget.onSkip();
              },
            ),
          ),
        ],
      ),
    ];
  }

  // ---------------------------------------------------------------------------
  // 手输那一屏
  // ---------------------------------------------------------------------------

  List<Widget> _buildManual() {
    return [
      const Text(
        '手动输入密码',
        style: TextStyle(
          fontSize: 12,
          color: AppTheme.textSecondary,
          height: 1.5,
        ),
      ),
      const SizedBox(height: 10),
      TextField(
        controller: _controller,
        autofocus: true,
        obscureText: !_reveal,
        enabled: !_checking,
        style: const TextStyle(
          fontSize: 14,
          fontFamily: 'monospace',
          color: AppTheme.textPrimary,
        ),
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _submit(),
        // 上一次输错了，再次输入就先把那句错话收掉 —— 让它在用户开始重输时
        // 消失，比一直挂到下一次提交更自然。
        onChanged: (_) {
          if (_failed != null) setState(() => _failed = null);
        },
        decoration: InputDecoration(
          isDense: true,
          hintText: '输入这个压缩包的密码',
          hintStyle: const TextStyle(
            fontSize: 13,
            fontFamily: 'monospace',
            color: AppTheme.textDim,
          ),
          filled: true,
          fillColor: Colors.white.withValues(alpha: 0.04),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: AppTheme.neonCyan.withValues(alpha: 0.5)),
          ),
          // 眼睛反映的是**当前状态**，不是「按下去会怎样」：密码遮着就画带斜杠
          // 的眼，亮出来了才画睁眼。这两套约定都有人用，但**反着画**最糟 ——
          // 用户看到睁眼去点，期望看到明文，结果什么也没变（真机上就是这么被
          // 报上来的）。`obscureText` 与这颗图标必须同源于 `_reveal`，改一个
          // 就得改另一个，所以两者贴在一起写。
          suffixIcon: IconButton(
            tooltip: _reveal ? '隐藏密码' : '显示密码',
            icon: Icon(
              _reveal ? Icons.visibility_outlined : Icons.visibility_off_outlined,
              size: 18,
              color: AppTheme.textDim,
            ),
            onPressed: () => setState(() => _reveal = !_reveal),
          ),
        ),
      ),
      if (_failed != null) ...[
        const SizedBox(height: 10),
        Row(
          children: [
            const Icon(Icons.error_outline, size: 14, color: AppTheme.neonRed),
            const SizedBox(width: 6),
            // 说「再试一次」而不是「密码错误，请重新输入」：手输密码本来就
            // 允许试，用户不需要被教育一次。
            //
            // 两句话的分界不是「严不严重」而是**我们到底知不知道**：
            // - `rejected` 且这个包说不清 → 只陈述「试了没通过」，并把另一种
            //   可能一起摆出来，不替用户在「密码不对」上拍板。
            // - 其余（含 `emptyInput`）→ 原话不动。「空着点确认」压根没试过，
            //   对它说「没通过」是句假话。
            Text(
              _failed == _Failure.rejected && widget.ask.uncertain
                  ? '验证未通过：可能密码错误，也可能文件已损坏'
                  : '密码错误，请重试',
              style: const TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                color: AppTheme.neonRed,
              ),
            ),
          ],
        ),
      ],
      const SizedBox(height: 18),
      Row(
        children: [
          Expanded(
            child: ModalButton(
              label: '返回',
              color: AppTheme.textSecondary,
              onTap: _checking
                  ? () {}
                  : () => setState(() => _manual = false),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: ModalButton(
              label: _checking ? '验证中…' : '确认',
              gradient: AppTheme.primaryGradient,
              onTap: _submit,
            ),
          ),
        ],
      ),
    ];
  }
}
