/// 第三方组件与它们的许可 —— 「关于」页展示的那份清单。
///
/// ## 这份清单是**义务**，不是装饰
///
/// 本应用使用了 7-Zip（LGPL-2.1 + unRAR 限制，见 `third_party/7zip`），内含三个
/// BSD 文件。LGPL-2.1 §6 要求「显著注明本作品使用了该库**且该库及其使用受本许可
/// 约束**、附上本许可的一份副本」；BSD-3 第 2 条要求「二进制分发时复现版权声明与
/// 免责声明」。这些都是**随每个副本**要给的，而 APK 里没有第二个地方能兑现 ——
/// 全文躺在 `assets/licenses/` 里，用户只能从「关于」页点开。
///
/// 国内应用商店不查这些，软著也**不查**（那是形式审查）。所以这份清单纯粹是
/// 法律义务，不做不会当场出事 —— 但成本只有这一个文件，没理由不做。
///
/// ## 三条容易写错的
///
/// - **unRAR 那条限制是「不能拿它做 RAR 压缩器」**，而解压正是它明确允许的用途。
///   这句话必须原样交代，否则用户/审核会以为我们踩了雷。
/// - **LGPL 不是 GPL**：不要求本应用也开源。清单里别写「本应用遵循 GPL」这种
///   话 —— 那是把自己说成了另一个东西。
/// - **§6 那句「且该库及其使用受本许可约束」不能只用一个 `LGPL-2.1+` 标签打发**
///   —— 那是许可名，不是那半句话。7-Zip 那条的 `summary` 第一句就是照原文写的。
///
/// ## 一条还没触发的条件，将来会咬人
///
/// §6 还有一句：**「如果本作品在运行期显示版权声明，就必须把该库的版权声明也
/// 一并显示」**。现在全应用运行期一个 © 都没显示，所以这条**不触发**。
/// 哪天有人在界面上加了「© 某某」之类的字样，这条就被引信打着了 —— 那时必须
/// 同时摆上 7-Zip 的版权声明（`Copyright (C) 1999-2026 Igor Pavlov`）。
library;

/// 一条第三方组件声明 —— **只读的一小段字，没有可点的地方**。
///
/// 从前它带一个 `asset` 字段、点一下跳到许可全文，于是和下面「许可全文」那几行
/// 指向同一批文档：`7zip.txt` 有三个入口、Flutter 许可页有两个。更糟的是
/// `LZFSE / ZSTD / XXH64` 那张卡点开后标题写着这几个名字、内容却是整份 7-Zip
/// 许可（那三个 BSD 组件的正文本来就嵌在里面，没有独立文件）。
///
/// 现在分工清楚了：**这一区是「声明」**（§6 要的「显著注明」就是这几段直接
/// 显示的字，本来也不靠点），**全文统一走下面那一区**。要指路就在 [summary]
/// 里写出文档的名字。
class ThirdPartyNotice {
  /// 组件名。
  final String name;

  /// 一句话说明它是什么、以及有没有要特别交代的限制。
  ///
  /// **纯文本，不认 Markdown** —— 它被原样塞进 `Text`，写 `**粗体**` 只会让
  /// 两个星号出现在用户眼前。要强调就靠措辞。
  final String summary;

  const ThirdPartyNotice({required this.name, required this.summary});
}

/// 7-Zip 那份 `DOC/License.txt` 的副本：许可概览 + BSD-3 / BSD-2 全文 +
/// unRAR 限制。LGPL 正文不在这份里（7-Zip 只给了那句标准声明），单独一份。
const String kSevenZipLicenseAsset = 'assets/licenses/7zip.txt';

/// GNU LGPL 2.1 全文。LGPL-2.1 §6 明说「必须附上本许可的一份副本」。
const String kLgpl21Asset = 'assets/licenses/LGPL-2.1.txt';

const List<ThirdPartyNotice> kThirdPartyNotices = [
  ThirdPartyNotice(
    name: '7-Zip 解压核心',
    // 第一句照 LGPL-2.1 §6 那句原话写 —— 它要求的是「显著注明本作品使用了该
    // 库**且该库及其使用受本许可约束**」，只给一个 `LGPL-2.1+` 的标签不算把
    // 后半句说出来。这一句是那半句，别删。
    summary:
        '本应用使用了 7-Zip（解压引擎本体），该库及其使用受 GNU LGPL 2.1 '
        '及以后版本约束。它以独立的动态库（libduz7zip.so）随本应用分发，'
        '引擎在运行期链接它。RAR 解压代码来自 unRAR：本应用仅用它解压 RAR，'
        '不用于制作 RAR 压缩包 —— 这正是 unRAR 许可明确允许、而压缩器被禁止的用途。'
        'Copyright (C) 1999-2026 Igor Pavlov。',
  ),
  ThirdPartyNotice(
    name: 'LZFSE / ZSTD / XXH64',
    // 这一条**没有自己的一份文档**：那三个 BSD 组件的正文就嵌在 7-Zip 的
    // License.txt 里。所以这里不指路给别的文件，只说清「正文在下面那份里」，
    // 免得再出现「卡片名字和点开的内容对不上」。
    summary:
        '7-Zip 内部嵌的三个 BSD 组件（Apple 与 Facebook 的 zstd/lzfse '
        '解压代码、Yann Collet 的 XXH64）。条款要求二进制分发时一并复现版权声明，'
        '它们各自的正文在下方「7-Zip 许可与限制」那份里。',
  ),
  ThirdPartyNotice(
    name: 'Dart / Flutter 组件',
    summary:
        'shared_preferences、flutter_secure_storage、crypto、'
        'permission_handler、archive、path、path_provider 等。许可由 Flutter 在'
        '构建期自动收集，全文见下方「Dart / Flutter 组件许可」。',
  ),
];
