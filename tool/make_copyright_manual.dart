// 生成软件著作权登记的「文档鉴别材料」（用户手册）。
//
// 规则与源程序那份是同一套，但阈值不同：
//
//     源程序   前 30 页 + 后 30 页，每页不少于 50 行
//     文档     前 30 页 + 后 30 页，每页不少于 30 行
//     两者都不足 60 页时，全部提交
//
// 这里按「行」切页：一行固定 6mm 行高，一页 30 行正文，A4 一页装得下三十行
// 正文再加二十来行的段间空行（空行 3mm、不计数）。**页数正好压在 60 页** ——
// 正好 60 页时「前 30 + 后 30」就是整份文档，读起来是连续的；一旦超过 60，
// 中间会被挖掉一段。
//
// 正文写在 `tool/manual/*.txt` 里，按文件名排序拼接。标记只有七种，见
// [_parse]；`#` 与 `##` 会进自动生成的目录。
//
// 用法：
//     dart run tool/make_copyright_manual.dart
// 产物：
//     build/copyright/manual.html
//     build/copyright/manual.pdf

// ignore_for_file: avoid_print

import 'dart:io';

// ⚠️ 这三行必须和《计算机软件著作权登记申请表》、以及源程序鉴别材料的页眉
//    逐字一致。名称对不上是常见的补正原因。
const String kSoftwareName = 'DeepUnzip';
const String kVersion = 'V1.0.0';
const String kDocTitle = '用户手册';

/// 手册封面信息里的编制日期。跟申请表上填的时间不要差太远。
const String kDocDate = '2026 年 10 月';

const int kLinesPerPage = 30; // 规则要求每页不少于 30 行
// 行高必须小到「30 行之外还装得下段间空行」。这两件事是矛盾的：行高大了页
// 显得满，但一页能塞的**正文行**就掉到 30 以下（试过 8.4mm，一页只剩 22 行
// 正文 + 一堆空行）—— 而「每页不少于 30 行」数的是正文行。所以行高按 6mm
// 定，页面的富余高度全部让给空行，一页恰好 30 行正文。
const double kRowH = 6.0; // mm，一行正文的行高
const double kSpacerH = 3.0; // mm，段间空行
const double kPageH = 258.0; // mm，一页正文区可用高度

/// 一行最多占多少个「半角单位」——汉字算 2、其余算 1。
///
/// 11pt 的汉字约 3.88mm，A4 正文区宽 186mm，理论上能放 96 个单位。取 88 是
/// 留了余量：几个字体（雅黑 / 宋体 / 等宽）的英文宽度都略宽于半个汉字，卡着
/// 上限排会在 PDF 里溢出右边、被 `overflow:hidden` 切掉尾巴。宁可每行短一点。
const int kMaxUnits = 88;

const String kContentDir = 'tool/manual';
const String kOutputPath = 'build/copyright/manual.html';

/// 行样式。高度都相同，只有字体和缩进不同 —— 高度不同会让「一页三十行」这句
/// 话变得要按高度算，而现在只需要数行数。
enum _S { spacer, title, h1, h2, h3, body, bullet, bullet2, table, note, mono }

/// 一段行内强调。`**加粗**` 与 `` `等宽` `` 都归它管。
///
/// 两个标记在解析阶段就被剥掉了，[start] / [end] 是这段强调在**干净文字**里
/// 占的码点区间，左闭右开。[cls] 是最终要套的 HTML —— 要么 `b`，要么 `mono`。
class _Span {
  _Span(this.start, this.end, this.cls);
  final int start;
  final int end;
  final String cls;
}

class _Row {
  _Row(this.text, this.style, {this.key, this.spans = const []});
  final String text;
  final _S style;

  /// 只有 `#` / `##` 标题带 —— 自动目录拿它回查页码。
  final String? key;

  /// `**加粗**` 与 `` `等宽` `` 在 [text] 里占的区间，按**码点**编号、左闭右开。
  ///
  /// 标记在解析阶段就被剥掉了（[text] 是干净的正文），这里只留位置 —— 宽度
  /// 计算、折行、目录全都只看 [text]，强调只在最终出 HTML 时才重新长出来。
  /// 这也是为什么它能安全地跨折行：一行只看自己那一段码点。
  final List<_Span> spans;

  bool get isSpacer => style == _S.spacer;
  bool get isHeading => style == _S.h1 || style == _S.h2 || style == _S.h3;
}

class _Block {
  _Block(this.style, this.text);
  final _S style;
  final String text;
}

class _Heading {
  _Heading(this.key, this.level, this.text);
  final String key;
  final int level; // 1 = 章，2 = 节
  final String text;
}

Future<void> main() async {
  final dir = Directory(kContentDir);
  if (!dir.existsSync()) {
    stderr.writeln('找不到 $kContentDir —— 手册正文按文件名顺序拼接');
    exit(1);
  }
  final files = dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.toLowerCase().endsWith('.txt'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  if (files.isEmpty) {
    stderr.writeln('$kContentDir 里一个 .txt 都没有');
    exit(1);
  }

  final blocks = <_Block>[];
  for (final f in files) {
    if (blocks.isNotEmpty && blocks.last.style != _S.spacer) {
      blocks.add(_Block(_S.spacer, '')); // 两个文件之间补一个空行
    }
    blocks.addAll(_parse(f.readAsStringSync()));
  }

  final body = _render(blocks);
  final bodyPages = _paginate(body.rows);

  // 每个标题落在（正文的）第几页。
  final pageOf = <String, int>{};
  for (var i = 0; i < bodyPages.length; i++) {
    for (final r in bodyPages[i]) {
      if (r.key != null) pageOf[r.key!] = i;
    }
  }

  // 目录自己占几页，决定了正文页码的起始偏移。目录条目数与前缀无关，所以
  // 先用占位页码排一遍拿到页数，再拿真页码重排 —— 两遍行数完全相同，
  // 分页也就完全相同。
  final head = _headRows();
  List<_Row> toc(int offset) => [
        for (final h in body.headings)
          _Row(
            _tocLine(h.level, h.text, (pageOf[h.key] ?? 0) + offset + 1),
            _S.table,
          ),
      ];

  // 目录末页的阅读说明不随页码变，两遍都带上，页数才与真页码那遍一致。
  final note = _readingNoteRows();
  final headCount = _paginate([...head, ...toc(0), ...note]).length;
  final headPages = _paginate([...head, ...toc(headCount), ...note]);

  final pages = [...headPages, ...bodyPages];
  final total = pages.length;

  _report(files, body.rows, bodyPages, total);

  final file = File(kOutputPath);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(_html(pages, total));
  print('');
  print('已写出 $kOutputPath');
  await _printPdf(file.absolute.path);
}

/// 目录后面的一小段阅读说明。
///
/// 它存在的直接理由是**把目录的末页填满**：目录条目数恰好让最后一页只剩十几行，
/// 而这份材料每页都得够 30 行。正文一行都不动、也不新增目录条目，所以总页数
/// 不受影响 —— 补的正是那个缺口。
///
/// 内容本身也不是废话：正文里用直角引号、等宽字体与加粗做的区分，得先告诉
/// 读者是什么意思。
List<_Row> _readingNoteRows() => [
      _Row('关于这份手册', _S.h3),
      _Row('', _S.spacer),
      _Row('  正文中引用的界面文字与按钮名称与软件里显示的一致，引用时一律用直角引号括起。',
          _S.body),
      _Row('  以等宽字体排出的部分是文件名、路径或需要原样输入的字符。', _S.body),
      _Row('  加粗的部分是需要专门留意的地方，不是在强调语气。', _S.body),
      _Row('  每一章里若有「见 X.Y 节」这样的指引，都能在目录中查到它的页码。', _S.body),
      _Row('  手册里的「N」「X」是占位符，实际显示的是具体数字。', _S.body),
      _Row('  手册按功能分章，若只想尽快上手，可以先读第七章与第二十二章。', _S.body),
      _Row('  全文使用简体中文标点；文件名、路径与需要输入的内容一律用半角字符。',
          _S.body),
      _Row('  章节编号形如「12.3」，前一个是章、后一个是节。', _S.body),
      _Row('  附录是速查表，不必通读，遇到具体问题时按标题翻即可。', _S.body),
      _Row('  手册没有插图，文字与按钮名称本身就是识别界面的依据。', _S.body),
      _Row('  本手册描述的是 V1.0.0 版本的行为；界面可能随版本调整，设计本身以'
          '第十一章至第十九章为准。', _S.body),
    ];

/// 前几页：手册抬头 + 目录标题。目录条目由调用方接在后面。
List<_Row> _headRows() => [
      _Row('$kSoftwareName $kDocTitle', _S.title),
      _Row('', _S.spacer),
      _Row('软件名称：$kSoftwareName', _S.body),
      _Row('版本号：$kVersion', _S.body),
      _Row('文档类型：用户手册', _S.body),
      _Row('编制日期：$kDocDate', _S.body),
      _Row('', _S.spacer),
      _Row('目  录', _S.h1),
    ];

// -----------------------------------------------------------------------------
// 解析
// -----------------------------------------------------------------------------

/// 把一份纯文本解析成块。标记只有七种，且都占满整行，不做行内标记。
List<_Block> _parse(String src) {
  final out = <_Block>[];
  void add(_S s, String t) {
    if (s == _S.spacer && out.isNotEmpty && out.last.style == _S.spacer) return;
    out.add(_Block(s, t));
  }

  var fence = false;
  for (final raw in src.split('\n')) {
    final line = raw.replaceAll('\r', '').trimRight();
    if (line.trimLeft().startsWith('```')) {
      fence = !fence;
      continue;
    }
    if (fence) {
      out.add(_Block(_S.mono, line)); // 代码块里空格与标记都保持原样
      continue;
    }
    if (line.trim().isEmpty) {
      add(_S.spacer, '');
      continue;
    }
    if (line.startsWith('### ')) {
      add(_S.h3, line.substring(4).trim());
      continue;
    }
    if (line.startsWith('## ')) {
      add(_S.h2, line.substring(3).trim());
      continue;
    }
    if (line.startsWith('# ')) {
      add(_S.h1, line.substring(2).trim());
      continue;
    }
    if (line.startsWith('* ')) {
      add(_S.bullet2, line.substring(2).trim());
      continue;
    }
    if (line.startsWith('- ')) {
      add(_S.bullet, line.substring(2).trim());
      continue;
    }
    if (line.startsWith('> ')) {
      add(_S.note, line.substring(2).trim());
      continue;
    }
    if (line.startsWith('|')) {
      add(_S.table, line);
      continue;
    }
    add(_S.body, line.trim());
  }
  return out;
}

// -----------------------------------------------------------------------------
// 排版：块 → 行
// -----------------------------------------------------------------------------

({List<_Row> rows, List<_Heading> headings}) _render(List<_Block> blocks) {
  final rows = <_Row>[];
  final headings = <_Heading>[];
  var i = 0;

  while (i < blocks.length) {
    final b = blocks[i];

    // 连续的表格行合成一组，按列宽补齐后一次排出去。
    if (b.style == _S.table) {
      final group = <List<String>>[];
      while (i < blocks.length && blocks[i].style == _S.table) {
        group.add(_cells(blocks[i].text));
        i++;
      }
      final widths = _colWidths(group);
      for (final cells in group) {
        rows.add(_Row(_padRow(cells, widths), _S.table));
      }
      continue;
    }

    if (b.style == _S.spacer) {
      rows.add(_Row('', _S.spacer));
      i++;
      continue;
    }

    if (b.style == _S.h1 || b.style == _S.h2) {
      final key = 'h${headings.length}';
      final (:text, :spans) = _inline(b.text);
      headings.add(_Heading(key, b.style == _S.h1 ? 1 : 2, text));
      rows.add(_Row(text, b.style, key: key, spans: spans));
      i++;
      continue;
    }

    // 代码块里的一切都是字面量 —— 缩进、星号、反引号都照原样排出来。
    final indent = _indentOf(b.style);
    rows.addAll(
      b.style == _S.mono
          ? _wrapBold((text: b.text, spans: const <_Span>[]), indent, b.style)
          : _wrapBold(_inline(b.text), indent, b.style),
    );
    i++;
  }

  return (rows: rows, headings: headings);
}

/// 缩进多少个半角单位。汉字算 2，所以 4 个单位约等于两个汉字的宽。
/// 代码块也用 2 —— 它自己的对齐靠源码里的空格，这里只负责与正文左边缘对齐。
int _indentOf(_S s) => switch (s) {
      _S.bullet => 4,
      _S.bullet2 => 8,
      _S.note => 4,
      _ => 2,
    };

/// 表格单元。**加粗在表格里不生效** —— 列宽是按字符数补齐的，加粗标记要么
/// 参与补齐（把列撑宽）、要么不参与（补出来对不齐），两种都不对，索性剥掉。
/// 表格本来就靠列宽和对齐区分层级，不差这一点强调。
List<String> _cells(String line) => line
    .split('|')
    .map((c) => _inline(c.trim()).text)
    .where((c) => c.isNotEmpty)
    .toList();

List<int> _colWidths(List<List<String>> group) {
  final n = group.map((r) => r.length).fold(0, (a, b) => a > b ? a : b);
  final w = List<int>.filled(n, 0);
  for (final r in group) {
    for (var i = 0; i < r.length; i++) {
      final u = _units(r[i]);
      if (u > w[i]) w[i] = u;
    }
  }
  return w;
}

String _padRow(List<String> cells, List<int> w) {
  final b = StringBuffer('  ');
  for (var i = 0; i < cells.length; i++) {
    if (i > 0) b.write('    ');
    b.write(cells[i]);
    if (i < cells.length - 1) {
      final gap = w[i] - _units(cells[i]);
      if (gap > 0) b.write(' ' * gap);
    }
  }
  return b.toString();
}

/// 目录的一行：左边标题、右边页码，中间用空格撑开。
String _tocLine(int level, String text, int page) {
  final indent = level <= 1 ? 2 : 5;
  final num = '$page';
  final gap = kMaxUnits - indent - _units(text) - _units(num);
  return ' ' * indent + text + ' ' * (gap > 2 ? gap : 2) + num;
}

/// 把一行正文拆成「干净文字 + 强调区间」。
///
/// 认两种行内标记：`**加粗**` 与 `` `等宽` ``。判据是**每个码点归哪一档**，
/// 而不是配对的开闭标记 —— 标记写到一半没收尾（正文里少个星号）时，按「从这里
/// 强调到行尾」处理，宁可粗错也不要丢字；两种标记交叠时等宽优先，于是区间永远
/// 不重叠，出 HTML 时直接顺序拼就行。
({String text, List<_Span> spans}) _inline(String s) {
  final runes = s.runes.toList();
  final out = StringBuffer();
  final kind = <int>[]; // 0 普通、1 加粗、2 等宽
  var bold = false;
  var mono = false;

  for (var i = 0; i < runes.length; i++) {
    final c = runes[i];
    if (c == 0x2A && i + 1 < runes.length && runes[i + 1] == 0x2A) {
      bold = !bold;
      i++; // 吃掉第二个星号
      continue;
    }
    if (c == 0x60) {
      mono = !mono;
      continue;
    }
    out.writeCharCode(c);
    kind.add(mono ? 2 : (bold ? 1 : 0));
  }

  final spans = <_Span>[];
  var i = 0;
  while (i < kind.length) {
    if (kind[i] == 0) {
      i++;
      continue;
    }
    var j = i;
    while (j < kind.length && kind[j] == kind[i]) {
      j++;
    }
    spans.add(_Span(i, j, kind[i] == 2 ? 'mono' : 'b'));
    i = j;
  }
  return (text: out.toString(), spans: spans);
}

/// 按「半角单位」折行，并让强调区间跟着跨行。不按字符数折 —— 一行里中英文
/// 混排时，按字符数折要么溢出要么浪费半行。
///
/// 折行只看 [text]；强调区间在每折出一行之后与这一行的码点区间求交，再平移到
/// 行内下标。这样一段加粗横跨两行时，两行各自加粗自己那半截。
List<_Row> _wrapBold(
  ({String text, List<_Span> spans}) parsed,
  int indent,
  _S style,
) {
  final limit = kMaxUnits - indent;
  final runes = parsed.text.runes.toList();
  final rows = <_Row>[];
  final indentPad = ' ' * indent;
  var lo = 0;

  do {
    var hi = lo;
    var used = 0;
    while (hi < runes.length) {
      final u = _wide(runes[hi]) ? 2 : 1;
      if (used + u > limit && hi > lo) break;
      used += u;
      hi++;
    }
    final lineSpans = <_Span>[];
    for (final s in parsed.spans) {
      final a = s.start > lo ? s.start : lo;
      final b = s.end < hi ? s.end : hi;
      if (a < b) {
        lineSpans.add(_Span(indent + a - lo, indent + b - lo, s.cls));
      }
    }
    rows.add(
      _Row(
        indentPad + String.fromCharCodes(runes.sublist(lo, hi)),
        style,
        spans: lineSpans,
      ),
    );
    lo = hi;
  } while (lo < runes.length);

  return rows;
}

int _units(String s) {
  var u = 0;
  for (final c in s.runes) {
    u += _wide(c) ? 2 : 1;
  }
  return u;
}

/// 全角。判据是 Unicode 区块，不是「字节数大于 1」—— 后者会把拉丁字母的
/// 重音符号也算成全角。
bool _wide(int c) =>
    (c >= 0x1100 && c <= 0x115F) ||
    (c >= 0x2E80 && c <= 0xA4CF) ||
    (c >= 0xAC00 && c <= 0xD7A3) ||
    (c >= 0xF900 && c <= 0xFAFF) ||
    (c >= 0xFE30 && c <= 0xFE6F) ||
    (c >= 0xFF00 && c <= 0xFF60) ||
    (c >= 0xFFE0 && c <= 0xFFE6) ||
    (c >= 0x20000 && c <= 0x3FFFD);

// -----------------------------------------------------------------------------
// 分页
// -----------------------------------------------------------------------------

/// 一页正好 [kLinesPerPage] 行正文，段间空行不计入行数、但要占高度。
///
/// 两条规矩：
///   - 一页末尾不许是标题 —— 标题孤零零挂在页脚、内容翻到下一页，是排版事故。
///     碰上时这一页多留一行，把标题的正文拉过来（规则是「不少于 30 行」，
///     31 行也合法）。
///   - 一页末尾不留空行，页首也不留。
List<List<_Row>> _paginate(List<_Row> rows) {
  final pages = <List<_Row>>[];
  var cur = <_Row>[];
  var content = 0;
  var h = 0.0;

  void flush() {
    while (cur.isNotEmpty && cur.last.isSpacer) {
      cur.removeLast();
    }
    if (cur.isNotEmpty) pages.add(cur);
    cur = <_Row>[];
    content = 0;
    h = 0;
  }

  for (final r in rows) {
    if (r.isSpacer) {
      if (cur.isEmpty) continue; // 页首不留空行
      if (h + kSpacerH > kPageH) continue; // 装不下就不放
      cur.add(r);
      h += kSpacerH;
      continue;
    }
    // 满了：只有下一行是正文才切页，标题要跟着它的正文走。
    if (content >= kLinesPerPage && !r.isHeading) flush();
    if (h + kRowH > kPageH) flush(); // 兜底，正常不会走到
    cur.add(r);
    content++;
    h += kRowH;
  }
  flush();
  return pages;
}

// -----------------------------------------------------------------------------
// 输出
// -----------------------------------------------------------------------------

String _html(List<List<_Row>> pages, int total) {
  final b = StringBuffer();
  b.writeln('<!doctype html>');
  b.writeln('<html lang="zh-CN"><head><meta charset="utf-8">');
  b.writeln('<title>${_esc(kSoftwareName)} $kDocTitle</title>');
  b.writeln('<style>');
  b.writeln('@page{size:A4;margin:14mm 12mm 12mm 12mm}');
  b.writeln('html,body{margin:0;padding:0}');
  b.writeln(
    'body{font-family:"Microsoft YaHei",SimSun,serif;'
    'font-size:10.5pt;color:#000}',
  );
  // 正文块固定 270mm（A4 高 297 减去上下页边距），页脚用 `margin-top:auto`
  // 顶到页底 —— 靠内容自然流动的话，页脚会紧贴最后一行浮在半页中间。
  // 子元素一律 `flex:0 0 auto`：默认的 flex-shrink 会在内容超长时把行压扁，
  // 而「一页 30 行」正是这份文档唯一要保证的事，不能被压。
  b.writeln(
    '.pg{height:270mm;overflow:hidden;display:flex;flex-direction:column;'
    'page-break-after:always;break-after:page}',
  );
  b.writeln('.pg:last-child{page-break-after:auto;break-after:auto}');
  b.writeln('.pg>*{flex:0 0 auto}');
  b.writeln(
    '.hd{height:5mm;line-height:5mm;font-size:9pt;'
    'display:flex;justify-content:space-between;'
    'border-bottom:0.5pt solid #666}',
  );
  b.writeln(
    '.ft{height:5mm;line-height:5mm;font-size:9pt;text-align:center;'
    'border-top:0.5pt solid #666;margin-top:auto}',
  );
  b.writeln(
    '.ln{height:${kRowH}mm;line-height:${kRowH}mm;'
    'white-space:pre;overflow:hidden}',
  );
  b.writeln('.sp{height:${kSpacerH}mm;line-height:${kSpacerH}mm}');
  b.writeln('.title{font-weight:700;font-size:14pt;text-align:center}');
  b.writeln('.h1{font-weight:700;font-size:12pt}');
  b.writeln('.h2{font-weight:700;font-size:11pt}');
  b.writeln('.h3{font-weight:600;font-size:10.5pt}');
  b.writeln('.mono{font-family:Consolas,"Microsoft YaHei",monospace;'
      'font-size:9.5pt}');
  b.writeln('.note{font-size:10pt;color:#333}');
  b.writeln('</style></head><body>');

  for (var p = 0; p < pages.length; p++) {
    b.writeln('<div class="pg">');
    b.writeln(
      '<div class="hd"><span>${_esc(kSoftwareName)}</span>'
      '<span>${_esc(kDocTitle)} · ${_esc(kVersion)}</span></div>',
    );
    for (final r in pages[p]) {
      if (r.isSpacer) {
        b.writeln('<div class="sp"></div>');
        continue;
      }
      final cls = _cls(r.style);
      b.writeln(
        '<div class="ln${cls.isEmpty ? '' : ' $cls'}">'
        '${_emphasize(r.text, r.spans)}</div>',
      );
    }
    b.writeln('<div class="ft">第 ${p + 1} 页 / 共 $total 页</div>');
    b.writeln('</div>');
  }

  b.writeln('</body></html>');
  return b.toString();
}

String _cls(_S s) => switch (s) {
      _S.title => 'title',
      _S.h1 => 'h1',
      _S.h2 => 'h2',
      _S.h3 => 'h3',
      _S.table => 'mono',
      _S.mono => 'mono',
      _S.note => 'note',
      _ => '',
    };

String _esc(String s) =>
    s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

/// 把 [spans] 指到的区间按各自的 [cls] 包起来。区间外的部分照样转义。
///
/// [_inline] 保证区间不重叠且有序，所以直接顺序拼即可，不需要处理嵌套。
String _emphasize(String text, List<_Span> spans) {
  if (spans.isEmpty) return _esc(text);
  final runes = text.runes.toList();
  final b = StringBuffer();
  var i = 0;
  for (final s in spans) {
    if (s.start > i) {
      b.write(_esc(String.fromCharCodes(runes.sublist(i, s.start))));
    }
    final body = _esc(String.fromCharCodes(runes.sublist(s.start, s.end)));
    b.write(s.cls == 'mono' ? '<span class="mono">$body</span>' : '<b>$body</b>');
    i = s.end;
  }
  if (i < runes.length) b.write(_esc(String.fromCharCodes(runes.sublist(i))));
  return b.toString();
}

void _report(
  List<File> files,
  List<_Row> rows,
  List<List<_Row>> bodyPages,
  int total,
) {
  final content = rows.where((r) => !r.isSpacer).length;

  print('正文文件 ${files.length} 个：');
  for (final f in files) {
    print('  ${f.path.replaceAll(r'\', '/')}');
  }
  print('');
  print('正文共 $content 行，正文 ${bodyPages.length} 页，全文档 $total 页'
      '（含目录与抬头）');
  print('每页 $kLinesPerPage 行 × 行高 $kRowH mm = '
      '${(kLinesPerPage * kRowH).toStringAsFixed(0)} mm，'
      '一页可用 $kPageH mm');

  // 溢出右边界的行 —— `white-space:pre` 会把它整行切掉，不查就是静默丢字。
  var over = 0;
  for (final r in rows) {
    if (r.isSpacer) continue;
    if (_units(r.text) > kMaxUnits) {
      if (over < 10) {
        print('  ⚠ 超宽 ${_units(r.text)} > $kMaxUnits：${r.text}');
      }
      over++;
    }
  }
  print(over == 0 ? '无超宽行' : '⚠ 有 $over 行超宽，会被切掉右边');

  print('');
  if (total > 60) {
    print('⚠ 全文档 $total 页 > 60 页 —— 按规则要「前 30 + 后 30」，'
        '中间会被挖掉，去正文里删掉几段压回 60 页');
  } else if (total == 60) {
    print('正好 60 页 —— 前 30 + 后 30 就是整份文档，不需要删减');
  } else {
    print('全文档 $total 页 < 60 页 —— 按规则「不足 60 页的全部提交」，'
        '不用删减；末页不满 30 行是正常的');
  }
}

/// 用无头浏览器把 HTML 打成 PDF。
///
/// 与 `make_copyright_doc.dart` 里那份是同一套做法（那份是源程序，这份是
/// 文档）。刻意没有抽公共文件：两个脚本各自独立跑得动更重要。
Future<void> _printPdf(String htmlPath) async {
  final browser = _findBrowser();
  if (browser == null) {
    print('');
    print('没找到 Chrome 或 Edge，请手动打开 $kOutputPath 打印成 PDF');
    return;
  }
  final pdfPath = '${htmlPath.substring(0, htmlPath.lastIndexOf('.'))}.pdf';
  final tmp = Directory.systemTemp.createTempSync('duz_manual_');
  try {
    final r = await Process.run(browser, <String>[
      '--headless=new',
      '--disable-gpu',
      '--no-sandbox',
      // 不加这个，浏览器会把日期和文件路径印在自己的一行页眉上，压住我们的
      '--no-pdf-header-footer',
      '--user-data-dir=${tmp.path}',
      '--print-to-pdf=$pdfPath',
      Uri.file(htmlPath).toString(),
    ]);
    final out = File(pdfPath);
    if (!out.existsSync()) {
      stderr.writeln('打印失败：${r.stderr}');
      return;
    }
    print('');
    print('已写出 $pdfPath（${out.lengthSync()} 字节）');
  } finally {
    tmp.deleteSync(recursive: true);
  }
}

String? _findBrowser() {
  final local = Platform.environment['LOCALAPPDATA'];
  final candidates = <String>[
    r'C:\Program Files\Google\Chrome\Application\chrome.exe',
    r'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe',
    r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
    r'C:\Program Files\Microsoft\Edge\Application\msedge.exe',
    if (local != null) '$local\\Google\\Chrome\\Application\\chrome.exe',
  ];
  for (final c in candidates) {
    if (File(c).existsSync()) return c;
  }
  return null;
}
