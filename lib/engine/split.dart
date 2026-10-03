/// 分卷（多卷）压缩包的识别、排序与连续性校验（需求 4）。
///
/// ## 四类家族，四种喂法
///
/// | 家族 | 形态 | 顺序 | 入口点 |
/// |---|---|---|---|
/// | [SplitKind.rawSplit] | `x.zip.001` / `x.7z.001` / `x.001` | 数字升序 | `.001` |
/// | [SplitKind.infoZipSpanned] | `x.z01`…`x.zNN` + `x.zip` | `.zip` 在**最后** | `x.zip` |
/// | [SplitKind.rarVolumes] | `x.rar` + `x.r00`… | `.rar` 在**首** | `x.rar` |
/// | [SplitKind.rar5Volumes] | `x.part1.rar` / `x.part01.rar` | 数字升序 | `part1` |
///
/// 顺序不是小事：Info-ZIP 跨卷的 `.zip` 卷自带局部中央目录，**不是**简单的
/// 字节拼接；RAR 卷更是必须交给 7-Zip 的原生分卷回调。所以 [SplitFamily.parts]
/// 的顺序就是喂给后端的顺序，排错＝解出错。
///
/// ## 纯函数
///
/// 本文件不碰磁盘，只做名字与尺寸。**首卷魔数校验**（`.zip.001` 的前几个字节
/// 到底是不是 `PK`）由扫描器在拿到 [SniffResult] 之后用
/// [firstVolumeLooksValid] 判定 —— 那样才能覆盖需求 5 的「伪后缀 + 分卷」
/// 组合场景（`备份.rar.001` 其实是 zip）。
///
/// ## 已知缺口
///
/// 旧式 RAR 超过 100 卷时会换扩展名续接（`.r99` → `.s00` → `.t00` …）。
/// 本文件只处理 `.rNN`，遇到这种（极罕见）情况会因连续性校验失败而拒绝分组，
/// 并给出警告 —— 宁可不解，也不要按错的顺序喂给解码器。
library;

import 'models.dart';

// ---------------------------------------------------------------------------
// 输入输出
// ---------------------------------------------------------------------------

/// 分组输入：一个文件的路径与字节数。
///
/// [size] 传 0 表示未知，此时跳过「非末卷等长」检查（单测用）。
typedef SplitInput = ({String path, int size});

/// 一次分卷分组的结果。
class SplitScan {
  const SplitScan({
    required this.families,
    required this.consumed,
    required this.warnings,
  });

  const SplitScan.empty()
      : families = const [],
        consumed = const {},
        warnings = const [];

  /// 识别出的分卷家族。
  final List<SplitFamily> families;

  /// 已被某个家族收编的路径。这些文件不应再作为独立条目出现在列表里。
  final Set<String> consumed;

  /// 目录级问题（缺号、入口点不存在……），进扫描警告。
  final List<String> warnings;

  bool get isEmpty => families.isEmpty;
}

// ---------------------------------------------------------------------------
// 命名模式
// ---------------------------------------------------------------------------

// 裸字节切分：x.zip.001 / x.7z.001 / x.001
// 数字段至少 2 位 —— 单一位的 `x.1` 与「文件名里带数字」太容易撞。
final RegExp _reRawSplit = RegExp(r'^(.*)\.(\d{2,})$');

// RAR5：x.part1.rar / x.part01.rar
// 首卷也可能是 SFX 的 .exe。
final RegExp _reRar5 = RegExp(r'^(.*)\.part(\d+)\.(rar|exe)$', caseSensitive: false);

// RAR3：x.rar 是首卷，x.r00 起续接
final RegExp _reRar3Base = RegExp(r'^(.*)\.rar$', caseSensitive: false);
final RegExp _reRar3Part = RegExp(r'^(.*)\.r(\d{2,})$', caseSensitive: false);

// Info-ZIP 跨卷：x.z01…x.zNN + x.zip（.zip 在最后）
final RegExp _reZipSpanPart = RegExp(r'^(.*)\.z(\d{2,})$', caseSensitive: false);
final RegExp _reZipSpanBase = RegExp(r'^(.*)\.zip$', caseSensitive: false);

// ---------------------------------------------------------------------------
// 入口
// ---------------------------------------------------------------------------

/// 从一批文件里识别分卷家族。
///
/// 只在**同一目录**内分组：不同目录下的 `a.zip.001` 与 `b/a.zip.002` 不可能是
/// 同一个压缩包。返回值同时给出 [SplitScan.consumed]，调用方据此把已被收编的
/// 文件从「独立条目」里剔除。
SplitScan groupSplitVolumes(List<SplitInput> files) {
  if (files.isEmpty) return const SplitScan.empty();

  // 按目录归拢。目录名用 `/` 归一化后的形式做 key，但保留原始路径。
  final byDir = <String, List<SplitInput>>{};
  for (final f in files) {
    byDir.putIfAbsent(_dirKey(f.path), () => []).add(f);
  }

  final families = <SplitFamily>[];
  final consumed = <String>{};
  final warnings = <String>[];

  for (final group in byDir.values) {
    _groupWithinDir(group, families, consumed, warnings);
  }

  return SplitScan(
    families: families,
    consumed: consumed,
    warnings: warnings,
  );
}

void _groupWithinDir(
  List<SplitInput> files,
  List<SplitFamily> families,
  Set<String> consumed,
  List<String> warnings,
) {
  // 目录内的查找表：小写文件名 → 输入。用文件名（不含目录）做键。
  final byName = <String, SplitInput>{};
  for (final f in files) {
    byName.putIfAbsent(_baseName(f.path).toLowerCase(), () => f);
  }

  // 顺序要紧：RAR5 的 `x.part1.rar` 也能被 RAR3 的 `^(.*)\.rar$` 匹配上
  // （stem 会变成 `x.part1`），所以 RAR5 必须先试。
  _tryRar5(byName, families, consumed, warnings);
  _tryInfoZipSpanned(byName, families, consumed, warnings);
  _tryRar3(byName, families, consumed, warnings);
  _tryRawSplit(byName, families, consumed, warnings);
}

// ---------------------------------------------------------------------------
// 各家族
// ---------------------------------------------------------------------------

/// 序号 → 该序号下的**全部**文件。
///
/// 刻意用 `List` 而不是单个值：用 `Map<int, SplitInput>` 直接赋值会让后一个
/// 静默覆盖前一个，于是「序号重复」从「应当报错」退化成「凭空少了一片」，
/// 而且看不出为什么。重复必须在建表阶段就留下来。
typedef _IndexedParts = Map<int, List<SplitInput>>;

/// 往 [_IndexedParts] 里追加一条。
void _index(_IndexedParts map, int i, SplitInput f) =>
    map.putIfAbsent(i, () => []).add(f);

void _tryRar5(
  Map<String, SplitInput> byName,
  List<SplitFamily> families,
  Set<String> consumed,
  List<String> warnings,
) {
  final groups = <String, _IndexedParts>{};

  for (final f in byName.values) {
    if (consumed.contains(f.path)) continue;
    final m = _reRar5.firstMatch(_baseName(f.path));
    if (m == null) continue;
    _index(groups.putIfAbsent(m.group(1)!.toLowerCase(), () => {}),
        int.parse(m.group(2)!), f);
  }

  for (final entry in groups.entries) {
    final raw = entry.value;
    if (_totalParts(raw) < 2) continue; // 单卷不是分卷，按普通 rar 处理

    final r = _resolveParts(raw, expectedFirst: 1);
    if (!r.ok) {
      warnings.add('${_baseName(_firstByIndex(raw).path)}: ${r.reason}');
      continue;
    }

    _emit(
      kind: SplitKind.rar5Volumes,
      ordered: r.ordered,
      families: families,
      consumed: consumed,
    );
  }
}

void _tryInfoZipSpanned(
  Map<String, SplitInput> byName,
  List<SplitFamily> families,
  Set<String> consumed,
  List<String> warnings,
) {
  final partGroups = <String, _IndexedParts>{};
  final bases = <String, SplitInput>{}; // stem → .zip

  for (final f in byName.values) {
    if (consumed.contains(f.path)) continue;
    final name = _baseName(f.path);

    final mb = _reZipSpanBase.firstMatch(name);
    if (mb != null) {
      bases.putIfAbsent(mb.group(1)!.toLowerCase(), () => f);
      continue;
    }

    final mp = _reZipSpanPart.firstMatch(name);
    if (mp != null) {
      _index(partGroups.putIfAbsent(mp.group(1)!.toLowerCase(), () => {}),
          int.parse(mp.group(2)!), f);
    }
  }

  for (final entry in partGroups.entries) {
    final raw = entry.value;

    // 没有 `.zip` 就凑不成 Info-ZIP 跨卷：中央目录在最末那个卷里。
    final base = bases[entry.key];
    if (base == null) {
      warnings.add('${_baseName(_firstByIndex(raw).path)} 等 ${raw.length} 个分片'
          '缺少对应的 .zip 卷（中央目录在最后一个卷里），无法合并');
      continue;
    }
    if (consumed.contains(base.path)) continue;

    final r = _resolveParts(raw, expectedFirst: 1);
    if (!r.ok) {
      warnings.add('${_baseName(base.path)}: ${r.reason}');
      continue;
    }

    // 关键：`.zip` 排在**所有** `.zNN` 之后。
    _emit(
      kind: SplitKind.infoZipSpanned,
      ordered: [...r.ordered, base],
      entryPath: base.path,
      families: families,
      consumed: consumed,
    );
  }
}

void _tryRar3(
  Map<String, SplitInput> byName,
  List<SplitFamily> families,
  Set<String> consumed,
  List<String> warnings,
) {
  final bases = <String, SplitInput>{}; // stem → .rar
  final partGroups = <String, _IndexedParts>{};

  for (final f in byName.values) {
    if (consumed.contains(f.path)) continue;
    final name = _baseName(f.path);

    // `.rNN` 与 `.rar` 形态不重叠（`.rar` 后面不是数字），先后顺序无关。
    final mp = _reRar3Part.firstMatch(name);
    if (mp != null) {
      _index(partGroups.putIfAbsent(mp.group(1)!.toLowerCase(), () => {}),
          int.parse(mp.group(2)!), f);
      continue;
    }

    final mb = _reRar3Base.firstMatch(name);
    if (mb != null) {
      bases.putIfAbsent(mb.group(1)!.toLowerCase(), () => f);
    }
  }

  for (final entry in partGroups.entries) {
    final raw = entry.value;

    // 没有 `.rar` 首卷就拼不出完整归档。
    final base = bases[entry.key];
    if (base == null) {
      warnings.add('${_baseName(_firstByIndex(raw).path)} 等 ${raw.length} 个分片'
          '缺少起始的 .rar 卷，无法合并');
      continue;
    }
    if (consumed.contains(base.path)) continue;

    // RAR3 的续卷从 .r00 起（序号 0）。
    final r = _resolveParts(raw, expectedFirst: 0);
    if (!r.ok) {
      warnings.add('${_baseName(base.path)}: ${r.reason}');
      continue;
    }

    // `.rar` 排在**最前**。
    _emit(
      kind: SplitKind.rarVolumes,
      ordered: [base, ...r.ordered],
      entryPath: base.path,
      families: families,
      consumed: consumed,
    );
  }
}

void _tryRawSplit(
  Map<String, SplitInput> byName,
  List<SplitFamily> families,
  Set<String> consumed,
  List<String> warnings,
) {
  final groups = <String, _IndexedParts>{};

  for (final f in byName.values) {
    if (consumed.contains(f.path)) continue;
    final m = _reRawSplit.firstMatch(_baseName(f.path));
    if (m == null) continue;
    final stem = m.group(1)!;
    if (stem.isEmpty) continue;
    _index(groups.putIfAbsent(stem.toLowerCase(), () => {}),
        int.parse(m.group(2)!), f);
  }

  for (final entry in groups.entries) {
    final raw = entry.value;
    if (_totalParts(raw) < 2) continue; // 单个 `report.2026` 不是分卷

    final r = _resolveParts(raw, expectedFirst: 1);
    if (!r.ok) {
      warnings.add('${_baseName(_firstByIndex(raw).path)}: ${r.reason}');
      continue;
    }

    _emit(
      kind: SplitKind.rawSplit,
      ordered: r.ordered,
      families: families,
      consumed: consumed,
    );
  }
}

/// 把一组有序分片登记成一个家族，并把这些文件标为已收编。
void _emit({
  required SplitKind kind,
  required List<SplitInput> ordered,
  required List<SplitFamily> families,
  required Set<String> consumed,
  String? entryPath,
}) {
  families.add(SplitFamily(
    kind: kind,
    entryPath: entryPath ?? ordered.first.path,
    parts: [for (final e in ordered) e.path],
    warnings: _sizeWarnings(ordered),
  ));
  for (final e in ordered) {
    consumed.add(e.path);
  }
}

/// 取序号最小的那个输入，用于给警告文案挑一个可读的名字。
SplitInput _firstByIndex(_IndexedParts raw) {
  final min = raw.keys.reduce((a, b) => a < b ? a : b);
  return raw[min]!.first;
}

/// 分片**文件**总数。
///
/// 不能用 `raw.length` —— 那数的是不同序号数。`x.01` 与 `x.001` 同属序号 1，
/// 用 `raw.length` 会得到 1，于是被当成「只有一个分片」提前放走，
/// 重复序号的问题就永远报不出来了。
int _totalParts(_IndexedParts raw) {
  var n = 0;
  for (final list in raw.values) {
    n += list.length;
  }
  return n;
}

/// 整理结果：要么给出有序分片，要么给出失败原因。
class _PartsResult {
  const _PartsResult.ok(this.ordered) : ok = true, reason = '';
  const _PartsResult.fail(this.reason) : ok = false, ordered = const [];

  final bool ok;
  final List<SplitInput> ordered;
  final String reason;
}

/// 把「序号 → 文件列表」整理成有序分片。
_PartsResult _resolveParts(_IndexedParts raw, {required int expectedFirst}) {
  // 重复序号：`x.01` 与 `x.001` 都是序号 1。
  for (final e in raw.entries) {
    if (e.value.length > 1) {
      final names = e.value.map((f) => _baseName(f.path)).join('、');
      return _PartsResult.fail('分片序号重复（序号 ${e.key} 对应多个文件：$names）');
    }
  }

  final check = _checkContiguous(raw.keys.toList(), expectedFirst: expectedFirst);
  if (!check.ok) return _PartsResult.fail(check.reason);

  return _PartsResult.ok([for (final i in check.sorted) raw[i]!.single]);
}

// ---------------------------------------------------------------------------
// 连续性校验
// ---------------------------------------------------------------------------

/// 排序 + 连续性检查的结果。
class _ContiguityCheck {
  const _ContiguityCheck.ok(this.sorted) : ok = true, reason = '';
  const _ContiguityCheck.fail(this.reason)
      : ok = false,
        sorted = const [];

  final bool ok;
  final List<int> sorted;
  final String reason;
}

/// 检查序号集合是否是 `expectedFirst..expectedFirst+N-1`：无缺号、无重复。
///
/// 返回按序排好的序号列表。这是分卷识别里唯一真正不能放松的一步 ——
/// 缺了一卷还硬解，7-Zip 会在中途报 CRC 错，用户看到的是「文件损坏」
/// 而不是「缺了第 3 卷」，排查成本高得多。
_ContiguityCheck _checkContiguous(
  List<int> indices, {
  required int expectedFirst,
}) {
  if (indices.isEmpty) return const _ContiguityCheck.fail('没有分片');

  final sorted = [...indices]..sort();

  // 重复：同一序号出现两次（例如 `x.01` 与 `x.001`）。
  for (var i = 1; i < sorted.length; i++) {
    if (sorted[i] == sorted[i - 1]) {
      return _ContiguityCheck.fail('分片序号重复（序号 ${sorted[i]} 出现了两次）');
    }
  }

  if (sorted.first != expectedFirst) {
    return _ContiguityCheck.fail(
      '分片不连续：起始序号是 ${sorted.first}，但该格式必须从 $expectedFirst 开始',
    );
  }

  for (var i = 1; i < sorted.length; i++) {
    if (sorted[i] != sorted[i - 1] + 1) {
      return _ContiguityCheck.fail(
        '分片不连续：${sorted[i - 1]} 与 ${sorted[i]} 之间缺少第 ${sorted[i - 1] + 1} 卷',
      );
    }
  }

  return _ContiguityCheck.ok(sorted);
}

/// 裸字节切分的额外断言：除末卷外应当等长。
///
/// 只警告不拒绝 —— 有些工具（以及可续传下载的残留）会产生不等长的分片，
/// 只要序号齐、字节序对，拼接结果仍然正确。
List<String> _sizeWarnings(List<SplitInput> ordered) {
  if (ordered.length < 2) return const [];
  if (ordered.any((e) => e.size <= 0)) return const []; // 尺寸未知，不瞎猜

  final first = ordered.first.size;
  for (var i = 0; i < ordered.length - 1; i++) {
    if (ordered[i].size != first) {
      return const ['分片尺寸异常：非末卷不等长'];
    }
  }
  return const [];
}

// ---------------------------------------------------------------------------
// 首卷校验（供扫描器调用）
// ---------------------------------------------------------------------------

/// 首卷必须看起来真的像压缩包，否则整组不算分卷。
///
/// 这一步是为了需求 5 的组合场景：`备份.rar.001` 的内容其实可能是 zip，
/// 甚至是普通的被切开的文件。只要嗅探认得出是压缩包就放行 ——
/// **格式与名字不符没关系**（那正是伪后缀，由 P5 的弹窗处理），
/// 认不出才说明这压根不是压缩包，应当按独立文件走。
bool firstVolumeLooksValid(SniffResult entrySniff) =>
    entrySniff.format != SniffFormat.unknown &&
    entrySniff.container == ContainerKind.none;

// ---------------------------------------------------------------------------
// 自然排序
// ---------------------------------------------------------------------------

/// 零填充感知的自然排序：`part2 < part10`，而不是字典序的 `part10 < part2`。
///
/// 数字段按数值比较；数值相同时（`001` vs `1`）位宽短的排前面，保证顺序
/// 确定。非数字段按码元比较。
int compareNatural(String a, String b) {
  var i = 0;
  var j = 0;

  while (i < a.length && j < b.length) {
    final ca = a.codeUnitAt(i);
    final cb = b.codeUnitAt(j);

    if (_isDigit(ca) && _isDigit(cb)) {
      var i2 = i;
      var j2 = j;
      while (i2 < a.length && _isDigit(a.codeUnitAt(i2))) {
        i2++;
      }
      while (j2 < b.length && _isDigit(b.codeUnitAt(j2))) {
        j2++;
      }

      final c = _digitsToInt(a.substring(i, i2)).compareTo(
            _digitsToInt(b.substring(j, j2)),
          );
      if (c != 0) return c;

      // 数值相同：位宽短者在前（`1` 在 `01` 之前）。
      final c2 = (i2 - i).compareTo(j2 - j);
      if (c2 != 0) return c2;

      i = i2;
      j = j2;
      continue;
    }

    if (ca != cb) return ca < cb ? -1 : 1;
    i++;
    j++;
  }

  return (a.length - i).compareTo(b.length - j);
}

bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

/// 去前导零后转整数。超长数字串（不可能是分卷号）饱和到最大值，
/// 避免 `int.parse` 溢出抛异常，同时保持排序确定性。
int _digitsToInt(String s) {
  var start = 0;
  while (start < s.length - 1 && s.codeUnitAt(start) == 0x30) {
    start++;
  }
  final t = s.substring(start);
  if (t.length > 18) return 0x7FFFFFFFFFFFFFFF;
  return int.parse(t);
}

// ---------------------------------------------------------------------------
// 路径小工具
// ---------------------------------------------------------------------------

String _baseName(String path) {
  final i = path.lastIndexOf(RegExp(r'[/\\]'));
  return i >= 0 ? path.substring(i + 1) : path;
}

/// 目录 key。反斜杠统一成 `/`，这样 `a\b` 与 `a/b` 视为同一目录；
/// Windows 盘符大小写也统一。
String _dirKey(String path) {
  final i = path.lastIndexOf(RegExp(r'[/\\]'));
  if (i < 0) return '';
  return path.substring(0, i).replaceAll(r'\', '/').toLowerCase();
}

