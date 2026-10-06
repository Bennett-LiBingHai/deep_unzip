/// 压缩炸弹（zip bomb）防护。
///
/// ## 闸门为什么落在这里，而不是「先 peek 再 extract」
///
/// 计划书写的是「`peekArchive` 的结果当作前置闸门」。那是后端还不存在时的
/// 设想，真做出来会发现那次 peek 是**多余的**：判定要的三样东西（条目数、
/// 每条大小、总量）在 `extractArchive` 里 `_open` 之后、`extractAll` 之前
/// 就全都有了 —— 同一份中央目录，解压本来就要读一遍。
///
/// 另开一次 peek 的代价不小：每个包多开一次文件、协议多一条命令、worker 与
/// `FakeEngine` 各多一个分支，而拿到的数字一模一样。所以闸门开在
/// `native_backend.extractArchive` 内部，一处覆盖全部调用方（顶层的和递归
/// 出来的嵌套包都走它）。
///
/// 顺带一个好处：闸门排在 `createSync` **之前**，被拒的包连一个空目录都不会
/// 留在磁盘上（见 `extractArchive` 里那段的顺序说明）。
///
/// ## 几条阈值各自挡什么
///
/// | 阈值 | 挡的是 |
/// |---|---|
/// | [LimitThresholds.maxEntries] | 中央目录灌水 —— 几百万个空条目 |
/// | [LimitThresholds.maxEntryBytes] | 单条声明成几 GiB 的那种 |
/// | [LimitThresholds.maxTotalBytes] | 声明总量，兜底硬顶 |
/// | [LimitThresholds.maxRatio] | 「小得离谱却撑得极大」的形态 |
/// | [checkArchiveLimits] 的 `availableBytes` | 目标卷真的装不下 |
///
/// 前三条是**精确**的，不会有误伤：声明值就是要写出去的字节数，7-Zip 解压时
/// 还会逐条按声明校验，对不上就报错。
///
/// 第四条是启发式的，所以配了 [LimitThresholds.ratioFloorBytes] 这道地板：
/// **只有总量本身已经很大时才看比值**。理由很实际 —— 200 KB 压成 300 MB 的
/// 包，比值 1500:1 也照样无害（最多写 300 MB），而不到 1 GiB 的东西本来就
/// 不构成「撑爆磁盘」这个威胁。地板把误伤面收窄到「又大又空」这一种形态，
/// 那基本就是炸弹了。
///
/// ## 为什么还要量剩余空间 —— 上面四条全是**估算**
///
/// 四条挡的都是「归档**自己声明**的大小」。声明可以低报，嵌套还能把「一个包
/// 太大」（拦得住）变成「N 个包各自都不大」（全放行）。真正不受估算影响的
/// 上限只有一个：**目标卷此刻还剩多少字节**。这条同时兜住嵌套、兜住批量、
/// 兜住低报，代价只是一次平台调用。
///
/// ## 这里**没有**做的一件事
///
/// 逐条压缩比（计划里的 `maxRatioPerEntry`）算不出来：C ABI 的 `duz_entry`
/// 只有原始大小，没有压缩后大小（见 `duz_engine.h`）。要么给 ABI 加一个字段
/// 并重新生成绑定，要么就退到这里的归档级比值。归档级的抓法对经典炸弹足够
/// —— 炸弹之所以是炸弹，正因为整体套着极高的比值。
///
/// 整个文件是**纯函数**：不碰磁盘、不进 isolate、不 import 插件，能在
/// `flutter_test` 里直接喂数字。分卷在磁盘上占多少字节由调用方量好传进来。
library;

import 'format.dart';

/// 闸门的全部旋钮。默认值即 [standard]。
class LimitThresholds {
  const LimitThresholds({
    this.maxEntries = 200000,
    this.maxEntryBytes = 8 << 30, //  8 GiB
    this.maxTotalBytes = 64 << 30, // 64 GiB
    this.maxRatio = 1000,
    this.ratioFloorBytes = 1 << 30, // 1 GiB
  });

  /// 一个归档最多允许多少条目。
  final int maxEntries;

  /// 单个条目的原始大小上限。
  final int maxEntryBytes;

  /// 一个归档解压后总量的上限。
  final int maxTotalBytes;

  /// 总量 / 磁盘占用 的比值上限。[ratioFloorBytes] 之下不生效。
  final int maxRatio;

  /// 比值检查的生效地板：总量不到这么多就不看比值。
  final int ratioFloorBytes;

  /// 出厂默认。测试要收紧时自己造一个，不要改这里。
  static const LimitThresholds standard = LimitThresholds();

  /// 宽松：几乎什么都放行。给人的是「我知道自己在干什么」的选项，
  /// 不是「安全」的选项。
  static const LimitThresholds loose = LimitThresholds(
    maxEntries: 1000000,
    maxEntryBytes: 64 << 30,
    maxTotalBytes: 512 << 30,
    maxRatio: 5000,
    ratioFloorBytes: 8 << 30,
  );

  /// 严格：给手机用的尺子。手机存储就几十上百 GB，一个包要写 8 GiB
  /// 已经该问问了。
  static const LimitThresholds strict = LimitThresholds(
    maxEntries: 20000,
    maxEntryBytes: 1 << 30,
    maxTotalBytes: 8 << 30,
    maxRatio: 200,
    ratioFloorBytes: 128 << 20,
  );

  /// 逐项改。设置页的「自定义」编辑态用它。
  LimitThresholds copyWith({
    int? maxEntries,
    int? maxEntryBytes,
    int? maxTotalBytes,
    int? maxRatio,
    int? ratioFloorBytes,
  }) {
    return LimitThresholds(
      maxEntries: maxEntries ?? this.maxEntries,
      maxEntryBytes: maxEntryBytes ?? this.maxEntryBytes,
      maxTotalBytes: maxTotalBytes ?? this.maxTotalBytes,
      maxRatio: maxRatio ?? this.maxRatio,
      ratioFloorBytes: ratioFloorBytes ?? this.ratioFloorBytes,
    );
  }

  // 值语义。设置页的 chip 靠它判断「当前这套是哪个预设」—— 没有 `==` 就只能
  // 比引用，而每次 `copyWith` 出来的都是新对象，chip 会永远显示「自定义」。
  @override
  bool operator ==(Object other) =>
      other is LimitThresholds &&
      other.maxEntries == maxEntries &&
      other.maxEntryBytes == maxEntryBytes &&
      other.maxTotalBytes == maxTotalBytes &&
      other.maxRatio == maxRatio &&
      other.ratioFloorBytes == ratioFloorBytes;

  @override
  int get hashCode => Object.hash(
        maxEntries,
        maxEntryBytes,
        maxTotalBytes,
        maxRatio,
        ratioFloorBytes,
      );

  @override
  String toString() => 'LimitThresholds(${formatCount(maxEntries)} 条, '
      '单条 ${formatBytes(maxEntryBytes)}, 总量 ${formatBytes(maxTotalBytes)}, '
      '比值 ${formatCount(maxRatio)}:1)';
}

/// 一个预设档位。
class LimitPreset {
  const LimitPreset(this.label, this.thresholds);

  final String label;
  final LimitThresholds thresholds;
}

/// 设置页里那个 chip 依次走过的档位。顺序即点击顺序。
const List<LimitPreset> kLimitPresets = [
  LimitPreset('宽松', LimitThresholds.loose),
  LimitPreset('标准', LimitThresholds.standard),
  LimitPreset('严格', LimitThresholds.strict),
];

/// chip 上「不是任何预设」时显示的字。用户手改过任何一项就落到这里。
const String kCustomLimitLabel = '自定义';

/// 设置页「自定义」里那几行。UI 按这张表渲染，加一项只改这里。
///
/// 读写都走这张表，是为了让「加一个阈值」不会变成「在四个地方各补一段
/// switch」。`ratioFloorBytes` 刻意**不在**表里：它是个内部护栏（见
/// [LimitThresholds.ratioFloorBytes]），只有让比值检查更保守的作用，
/// 摆到用户面前只会多一个看不懂的旋钮。
enum LimitField {
  entries('条目数上限', '单个压缩包解出的文件数上限'),
  entryBytes('单文件上限', '单个解压文件的大小上限'),
  totalBytes('解压总量上限', '单个压缩包解压后的总量上限'),
  ratio('压缩比上限', '解压后大小与压缩包大小的比值上限');

  const LimitField(this.label, this.hint);

  final String label;
  final String hint;

  /// 是不是字节量 —— 决定输入框按 `8 GB` 还是 `200,000` 的那套来解析与展示。
  bool get isBytes => this == entryBytes || this == totalBytes;

  int read(LimitThresholds t) => switch (this) {
        LimitField.entries => t.maxEntries,
        LimitField.entryBytes => t.maxEntryBytes,
        LimitField.totalBytes => t.maxTotalBytes,
        LimitField.ratio => t.maxRatio,
      };

  LimitThresholds apply(LimitThresholds t, int value) => switch (this) {
        LimitField.entries => t.copyWith(maxEntries: value),
        LimitField.entryBytes => t.copyWith(maxEntryBytes: value),
        LimitField.totalBytes => t.copyWith(maxTotalBytes: value),
        LimitField.ratio => t.copyWith(maxRatio: value),
      };

  /// 输入框里预填的样子，也是列表行上显示的当前值。
  String display(LimitThresholds t) {
    final v = read(t);
    return isBytes ? formatBytes(v) : formatCount(v);
  }
}

/// 一次判定的输入 —— 全部来自归档已打开、**还没写一个字节**的那一刻。
class ArchiveProfile {
  const ArchiveProfile({
    required this.entryCount,
    required this.unpackedBytes,
    required this.largestEntryBytes,
    this.compressedBytes = 0,
  });

  /// 条目总数（含目录条目）。
  final int entryCount;

  /// 所有非目录条目的原始大小之和。
  final int unpackedBytes;

  /// 最大的那个非目录条目。单条炸弹在这里露馅。
  final int largestEntryBytes;

  /// 这些分卷在磁盘上一共占多少字节。**`<= 0` 表示未知**，此时跳过比值检查
  /// —— 宁可少拦一道，也不要在没量的情况下瞎拦。
  final int compressedBytes;

  /// 从条目表量出一个 profile。
  ///
  /// 条目用 record 而不是某个类型：这样本文件不必认识 `DuzEntry`（那是插件
  /// 的类型），纯函数测试也就不必去构造插件对象。三个量都是一次遍历算完的，
  /// 调用方别自己再数一遍 —— 数错了不会有人发现。
  ///
  /// [compressedBytes] 由调用方量（要碰磁盘），量不到就留默认的 0。
  factory ArchiveProfile.fromEntries({
    required Iterable<({int size, bool isDir})> entries,
    int compressedBytes = 0,
  }) {
    var count = 0;
    var total = 0;
    var largest = 0;
    for (final e in entries) {
      count++;
      if (e.isDir) continue;
      total += e.size;
      if (e.size > largest) largest = e.size;
    }
    return ArchiveProfile(
      entryCount: count,
      unpackedBytes: total,
      largestEntryBytes: largest,
      compressedBytes: compressedBytes,
    );
  }
}

/// 触发了哪一条。
enum LimitKind {
  /// 条目太多。
  entryCount,

  /// 单条太大。
  entrySize,

  /// 总量太大。
  totalSize,

  /// 目标卷装不下。**唯一一条不是拿声明值跟自己比的判定。**
  diskSpace,

  /// 比值离谱。
  ratio,
}

/// 空间检查要留的底。
///
/// 不留的话，判定就成了「写到一格不剩才算超」—— 而把卷写满会把整台机器拖垮
/// （系统自己也要写日志、写缓存），而且解压本身还要临时空间。64 MiB 是随手
/// 定的保守值：它远小于任何一次正常解压的量级，只在「刚好卡在边界」时起作用。
///
/// 和 [LimitThresholds.ratioFloorBytes] 一样**不放进 [LimitField]**：它是个
/// 内部护栏，摆到设置页只会多一个没人看得懂的旋钮。
const int kDiskSpaceReserveBytes = 64 << 20;

/// 一次拒绝。没有触发时 [checkArchiveLimits] 返回 null。
class LimitBreach {
  const LimitBreach({
    required this.kind,
    required this.tag,
    required this.message,
  });

  final LimitKind kind;

  /// 日志里的标记，供 `log_builder` 与后面的弹窗用。
  final String tag;

  /// 给用户看的一句话，说清「超了多少、上限多少」。
  final String message;
}

/// 放行还是拦下。拦下时返回原因，放行返回 null。
///
/// 判定顺序是**从便宜到贵**，也是从确定到启发式：先数条目（O(1)，调用方
/// 早就算好了），再看单条，再看总量，再看目标卷装不装得下，最后才轮到
/// 启发式的比值。
///
/// [availableBytes] 是目标卷此刻的剩余字节数。**`null` 表示量不到**（非
/// Android、通道没注册、路径不可达），此时**跳过这条检查** —— 与
/// [ArchiveProfile.compressedBytes] 为 0 时跳过比值是同一条原则：量不出来的
/// 东西不能拿来当判据。
LimitBreach? checkArchiveLimits(
  ArchiveProfile p, {
  LimitThresholds limits = LimitThresholds.standard,
  int? availableBytes,
}) {
  if (p.entryCount > limits.maxEntries) {
    return LimitBreach(
      kind: LimitKind.entryCount,
      tag: '炸弹防护',
      message: '条目数 ${formatCount(p.entryCount)} 超过上限 '
          '${formatCount(limits.maxEntries)}，已放弃',
    );
  }

  if (p.largestEntryBytes > limits.maxEntryBytes) {
    return LimitBreach(
      kind: LimitKind.entrySize,
      tag: '炸弹防护',
      message: '有一个文件解出来是 ${formatBytes(p.largestEntryBytes)}，'
          '超过单文件上限 ${formatBytes(limits.maxEntryBytes)}，已放弃',
    );
  }

  if (p.unpackedBytes > limits.maxTotalBytes) {
    return LimitBreach(
      kind: LimitKind.totalSize,
      tag: '炸弹防护',
      message: '解压后共 ${formatBytes(p.unpackedBytes)}，'
          '超过上限 ${formatBytes(limits.maxTotalBytes)}，已放弃',
    );
  }

  // 剩余空间。排在这儿的理由与上面三条不同：它比的不是「声明值 vs 阈值」，
  // 而是「声明值 vs 这台机器现在真的有这么多」。所以它**不该**被上面三条
  // 短路 —— 一个既超了单文件上限、又装不下的包，先报「超过单文件上限」
  // 更有指向性（那是包的问题），而「装不下」可能只是这台机器的事。
  //
  // 减掉 [kDiskSpaceReserveBytes] 见那个常量的说明：判据是「留够底之后还
  // 装不装得下」，不是「能不能写到一格不剩」。
  if (availableBytes != null &&
      p.unpackedBytes > availableBytes - kDiskSpaceReserveBytes) {
    return LimitBreach(
      kind: LimitKind.diskSpace,
      tag: '空间不足',
      message: '解压后需要 ${formatBytes(p.unpackedBytes)}，'
          '设备仅剩 ${formatBytes(availableBytes)}，空间不足，已放弃',
    );
  }

  // 比值检查排最后：它要量磁盘（调用方已经量好），而且只有它还带着地板。
  if (p.compressedBytes > 0 && p.unpackedBytes >= limits.ratioFloorBytes) {
    final ratio = p.unpackedBytes ~/ p.compressedBytes;
    if (ratio > limits.maxRatio) {
      return LimitBreach(
        kind: LimitKind.ratio,
        tag: '炸弹防护',
        message: '${formatBytes(p.compressedBytes)} 的包解出来有 '
            '${formatBytes(p.unpackedBytes)}（${formatCount(ratio)}:1），'
            '疑似压缩炸弹，已放弃',
      );
    }
  }

  return null;
}
