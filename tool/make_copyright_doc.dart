// 生成软件著作权登记的「程序鉴别材料」。
//
// 规则：源程序前 30 页 + 后 30 页，每页不少于 50 行。不足 60 页则全部提交。
// 页数按「拼接成一篇连续文档」来算，前后各取 30 页 —— 所以文件顺序决定首尾
// 落在哪一段代码上，顺序是手工定的，不能按路径排（理由见 kOrder 上方）。
//
// 用法：
//     dart run tool/make_copyright_doc.dart
// 产物：
//     build/copyright/source.html   —— 浏览器打开 → 打印 → 另存为 PDF

// ignore_for_file: avoid_print

import 'dart:io';

// ⚠️ 这三行必须和《计算机软件著作权登记申请表》上填的**逐字一致**。
//    名称对不上是常见的补正原因。
const String kSoftwareName = 'DeepUnzip';
const String kVersion = 'V1.0.0';

const int kLinesPerPage = 50; // 规则要求每页不少于 50 行
const int kSidePages = 30; // 前 30 + 后 30
const bool kShowFileMarkers = true; // 每个文件开头插一行文件名，便于审查
const String kOutputPath = 'build/copyright/source.html';

/// 版权页（前 30 页）从这里开始。顺序 = 按功能主次，不是按路径。
///
/// **不能按路径自然排序**：那样 `lib/data/` 会排到很前面，而其中的
/// `third_party_notices.dart` 是第三方许可全文 —— 拿别人的文字占自己的页数。
/// 另外 `third_party/7zip/` 是 LGPL 的 7-Zip 源码（999 个文件、8.3 万行），
/// 一个字符都不能出现在鉴别材料里。
///
/// 结尾刻意落在 C++ 封装层上（duz_engine.cpp 排最后），文档末尾是引擎核心。
const List<String> kOrder = <String>[
  // ── 入口与核心调度 ──
  'lib/main.dart',
  'lib/app_info.dart',
  'lib/app_navigator.dart',
  'lib/providers/app_state.dart',

  // ── 数据模型 ──
  'lib/models/archive_file.dart',
  'lib/models/log_entry.dart',
  'lib/models/password_entry.dart',
  'lib/models/extractor.dart',

  // ── 引擎：协议 / 调度 / 扫描 / 识别 ──
  'lib/engine/protocol.dart',
  'lib/engine/models.dart',
  'lib/engine/controller.dart',
  'lib/engine/worker.dart',
  'lib/engine/scanner.dart',
  'lib/engine/sniff.dart',
  'lib/engine/split.dart',
  'lib/engine/format.dart',
  'lib/engine/zip_dir.dart',

  // ── 引擎：限额 / 路径 / 进度 ──
  'lib/engine/limits.dart',
  'lib/engine/cycles.dart',
  'lib/engine/output_paths.dart',
  'lib/engine/log_builder.dart',
  'lib/engine/progress_meter.dart',
  'lib/engine/tick_merge.dart',
  'lib/engine/tick_throttle.dart',
  'lib/engine/backends/native_backend.dart',

  // ── 服务层 ──
  'lib/services/dialog_bridge.dart',
  'lib/services/password_prompt.dart',
  'lib/services/prompts.dart',
  'lib/services/file_browser.dart',
  'lib/services/storage_roots.dart',
  'lib/services/disk_space.dart',
  'lib/services/file_manager_bridge.dart',
  'lib/services/keep_alive.dart',
  'lib/services/notification_permission.dart',

  // ── 持久化 ──
  // third_party_notices.dart 刻意排除：那是第三方许可全文，不是自有程序。
  'lib/data/json_store.dart',
  'lib/data/settings_repo.dart',
  'lib/data/vault_repo.dart',
  'lib/data/log_repo.dart',
  'lib/data/device_store.dart',
  'lib/data/persist.dart',
  'lib/data/builtin_extractors.dart',

  // ── 主题与界面 ──
  // 组件排在页面前面：这样后 30 页的起点落在页面上（而不是一堆弹窗），
  // 尾部依次是 主要页面 → Dart 引擎封装 → Kotlin 平台层 → C++ 引擎封装。
  'lib/theme/app_theme.dart',
  'lib/widgets/particle_background.dart',
  'lib/widgets/glass_card.dart',
  'lib/widgets/custom_button.dart',
  'lib/widgets/modals/bottom_modal.dart',
  'lib/widgets/modals/modal_button.dart',
  'lib/widgets/modals/error_modal.dart',
  'lib/widgets/modals/confirm_extract_modal.dart',
  'lib/widgets/modals/password_attempt_modal.dart',
  'lib/widgets/modals/format_detect_modal.dart',
  'lib/widgets/modals/path_fallback_modal.dart',
  'lib/widgets/modals/clear_logs_modal.dart',
  'lib/widgets/modals/delete_password_modal.dart',
  'lib/widgets/modals/limit_value_modal.dart',
  'lib/widgets/modals/log_limit_modal.dart',
  'lib/widgets/modals/max_depth_modal.dart',
  'lib/widgets/modals/value_input_modal.dart',
  'lib/screens/home_screen.dart',
  'lib/screens/file_browser_screen.dart',
  'lib/screens/log_screen.dart',
  'lib/screens/vault_screen.dart',
  'lib/screens/settings_screen.dart',
  'lib/screens/about_screen.dart',
  'lib/screens/license_text_screen.dart',

  // ── 原生层（收尾）──
  // 排除 *_bindings_generated.dart：ffigen 自动生成，不是手写程序。
  'packages/deep_unzip_engine/lib/deep_unzip_engine.dart',
  'android/app/src/main/kotlin/com/bennett/deep_unzip/MainActivity.kt',
  'android/app/src/main/kotlin/com/bennett/deep_unzip/'
      'ExtractKeepAliveService.kt',
  'packages/deep_unzip_engine/src/duz_engine.h',
  'packages/deep_unzip_engine/src/duz_engine.cpp',
];

Future<void> main() async {
  final parts = <_Part>[];
  for (final path in kOrder) {
    final f = File(path);
    if (!f.existsSync()) {
      stderr.writeln('找不到 $path —— 顺序表里有不存在的文件');
      exit(1);
    }
    final lines = stripSource(f.readAsStringSync());
    if (lines.isEmpty) {
      stderr.writeln('$path 剥完注释一行不剩，跳过');
      continue;
    }
    parts.add(_Part(path, lines));
  }

  final all = <String>[];
  final owners = <String>[]; // 每行属于哪个文件，只是为了让报告能说清首尾落点
  for (final p in parts) {
    if (kShowFileMarkers) {
      all.add('// ===== ${p.path} =====');
      owners.add(p.path);
    }
    for (final line in p.lines) {
      all.add(line);
      owners.add(p.path);
    }
  }

  final need = kLinesPerPage * kSidePages; // 一侧 1500 行
  if (all.length < need * 2) {
    stderr.writeln(
      '可用源码只有 ${all.length} 行，不足 ${need * 2} 行，'
      '按规则应提交全部源程序',
    );
    exit(1);
  }

  final front = all.sublist(0, need);
  final back = all.sublist(all.length - need);
  final out = <String>[...front, ...back];

  _report(owners, all.length, need);

  final html = _render(out);
  final file = File(kOutputPath);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(html);

  final pages = (out.length / kLinesPerPage).ceil();
  print('');
  print('已写出 $kOutputPath');
  print(
    '  共 ${out.length} 行 / $pages 页'
    '（前 $kSidePages 页 + 后 $kSidePages 页，每页 $kLinesPerPage 行）',
  );

  await _printPdf(file.absolute.path);
}

/// 用无头浏览器把 HTML 打成 PDF。
///
/// 不用「HTML 转 PDF」的库：那类库要自己重排一遍版式，而 Chrome / Edge 自带的
/// 打印就是最终排版 —— 页边距、分页、字体全按 CSS 走，出来的 PDF 和手动
/// 「打印 → 另存为 PDF」是同一份东西。
Future<void> _printPdf(String htmlPath) async {
  final browser = _findBrowser();
  if (browser == null) {
    print('');
    print('没找到 Chrome 或 Edge，请手动打开 $kOutputPath 打印成 PDF');
    return;
  }
  final pdfPath = '${htmlPath.substring(0, htmlPath.lastIndexOf('.'))}.pdf';
  final tmp = Directory.systemTemp.createTempSync('duz_copyright_');
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

class _Part {
  _Part(this.path, this.lines);
  final String path;
  final List<String> lines;
}

/// 打印首尾各落在哪个文件上 —— 顺序有没有排对，看这个。
void _report(List<String> owners, int total, int need) {
  print('剥注释后共 $total 行');
  print('');
  print('前 $kSidePages 页：${owners.first}');
  print('            └→ ${owners[need - 1]}');
  print('后 $kSidePages 页：${owners[total - need]}');
  print('            └→ ${owners.last}');
}

/// 逐字符剥掉注释与空行。
///
/// 不用正则：源码里有 `'https://…'`、`'application/zip'` 这类字符串字面量，
/// 正则会把里面的 `//` 当成注释切开，切完的程序看起来就是坏的。
List<String> stripSource(String src) {
  final lines = <String>[];
  final cur = StringBuffer();
  var i = 0;

  String? peek(int k) => i + k < src.length ? src[i + k] : null;

  void endLine() {
    final t = cur.toString().trimRight();
    cur.clear();
    if (t.trim().isNotEmpty) lines.add(t);
  }

  while (i < src.length) {
    final c = src[i];

    if (c == '\n') {
      endLine();
      i++;
      continue;
    }

    if (c == '/' && peek(1) == '/') {
      while (i < src.length && src[i] != '\n') {
        i++;
      }
      continue;
    }

    if (c == '/' && peek(1) == '*') {
      i += 2;
      while (i < src.length && !(src[i] == '*' && peek(1) == '/')) {
        if (src[i] == '\n') endLine();
        i++;
      }
      i = i + 2 > src.length ? src.length : i + 2;
      continue;
    }

    // r'...' / r"..." 原始字符串：里面没有转义
    if ((c == 'r' || c == 'R') && (peek(1) == "'" || peek(1) == '"')) {
      cur.write(c);
      i++;
      i = _readString(src, i, raw: true, out: cur, endLine: endLine);
      continue;
    }

    if (c == "'" || c == '"') {
      i = _readString(src, i, raw: false, out: cur, endLine: endLine);
      continue;
    }

    cur.write(c);
    i++;
  }
  endLine();
  return lines;
}

int _readString(
  String s,
  int start, {
  required bool raw,
  required StringBuffer out,
  required void Function() endLine,
}) {
  final q = s[start];
  final triple = start + 2 < s.length && s[start + 1] == q && s[start + 2] == q;
  final delim = triple ? q * 3 : q;

  out.write(delim);
  var i = start + delim.length;

  while (i < s.length) {
    if (!raw && s[i] == r'\') {
      out.write(s[i]);
      i++;
      if (i < s.length) {
        out.write(s[i]);
        i++;
      }
      continue;
    }
    if (s.startsWith(delim, i)) {
      out.write(delim);
      return i + delim.length;
    }
    if (s[i] == '\n') {
      // 三引号字符串跨行：换行处收线，字符串接着往下写
      endLine();
      i++;
      continue;
    }
    out.write(s[i]);
    i++;
  }
  return i;
}

String _render(List<String> lines) {
  final b = StringBuffer();
  b.writeln('<!doctype html>');
  b.writeln('<html lang="zh-CN"><head><meta charset="utf-8">');
  b.writeln('<title>${_esc(kSoftwareName)} 源程序</title>');
  b.writeln('<style>');
  b.writeln('@page{size:A4;margin:12mm 12mm 10mm 12mm}');
  b.writeln('html,body{margin:0;padding:0}');
  b.writeln(
    'body{font-family:Consolas,"Cascadia Mono","Courier New",'
    'monospace;font-size:9.5pt;line-height:1.30;color:#000}',
  );
  b.writeln('.pg{page-break-after:always;break-after:page}');
  b.writeln('.pg:last-child{page-break-after:auto;break-after:auto}');
  b.writeln(
    '.hd{font-family:SimSun,serif;font-size:9pt;'
    'display:flex;justify-content:space-between;'
    'border-bottom:0.5pt solid #666;padding-bottom:2px;margin-bottom:4px}',
  );
  b.writeln(
    '.ft{font-family:SimSun,serif;font-size:9pt;text-align:center;'
    'border-top:0.5pt solid #666;padding-top:2px;margin-top:4px}',
  );
  b.writeln('.ln{white-space:pre}');
  b.writeln('</style></head><body>');

  final pages = <List<String>>[];
  for (var i = 0; i < lines.length; i += kLinesPerPage) {
    final end = (i + kLinesPerPage) > lines.length
        ? lines.length
        : i + kLinesPerPage;
    pages.add(lines.sublist(i, end));
  }

  for (var p = 0; p < pages.length; p++) {
    b.writeln('<div class="pg">');
    b.writeln(
      '<div class="hd"><span>${_esc(kSoftwareName)}</span>'
      '<span>${_esc(kVersion)}</span></div>',
    );
    for (final line in pages[p]) {
      b.writeln('<div class="ln">${_esc(line)}</div>');
    }
    b.writeln('<div class="ft">第 ${p + 1} 页 / 共 ${pages.length} 页</div>');
    b.writeln('</div>');
  }

  b.writeln('</body></html>');
  return b.toString();
}

String _esc(String s) =>
    s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
