// 引擎的**最小冒烟测试页**。
//
// 它不是演示用的样板，而是「.so 到底加载得起来吗、7-Zip 核心真的编进去了吗」
// 这两个问题的现场答案 —— 这两个问题在真机上排查起来都很贵（加固抽符号、
// ABI 缺失、非 Android 构建拿到骨架，症状都是同一句 Failed to load）。
//
// 用法：装到设备上，把路径填进去（如 /sdcard/Download/test.zip），
// 点「打开并列出」看条目，再点「解压」看进度。
//
// 两件事都在独立 isolate 里跑 —— 引擎调用会阻塞整个 isolate，
// 在主 isolate 调就是 UI 全程冻死。
import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:deep_unzip_engine/deep_unzip_engine.dart';
import 'package:flutter/material.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      appBar: AppBar(title: const Text('deep_unzip_engine 冒烟测试')),
      body: const _Smoke(),
    ),
  );
}

/// 发给解压 isolate 的参数。
///
/// 用一个类而不是 record：`Isolate.spawn` 的入口参数必须是可发送的平凡数据，
/// 而具名类的字段类型是明确的，record 在这里容易写出编译器接受、运行期
/// 却发不过去的东西。
class _ExtractArgs {
  const _ExtractArgs(this.path, this.outDir, this.password, this.port);

  final String path;
  final String outDir;
  final String? password;
  final SendPort port;
}

/// 发给探测 isolate 的参数。
///
/// 这里刻意走 `Isolate.spawn` + 静态入口，**不用** `Isolate.run(() => _probe(path))`。
/// 后者短得多，看上去也干净，但在本文件里必然踩雷：
///
/// `Isolate.run` 要送出去的是那个闭包，而**闭包的 context 是带父链的**。即便
/// `() => _probe(path)` 正文只用到局部变量 `path`，它的 context 父链上仍然挂着
/// 捕获了 `this` 的外层 async 闭包（`_open` 里调了 `_append`/`_path`），于是整个
/// `_SmokeState` 被一并拖进消息。而 `_SmokeState` 持有 `TextEditingController`、
/// 还连着 Flutter 的 element 树，往下走必然撞上不可发送的对象。真机上看到的是：
///
/// ```
/// 失败：Invalid argument(s): Illegal argument in isolate message:
/// object is unsendable - Library:'dart:async' Class: _AsyncCompleter
/// ```
///
/// 那个 `_AsyncCompleter` 不是我们写的任何东西，只是 VM 遍历对象图时**第一个**
/// 撞上的不可发送对象 —— 报错里点名谁纯属运气，别照着它去查。
///
/// 静态入口 + 平凡参数根本不经过闭包 context，这个雷就不存在。产品侧的
/// `lib/engine/controller.dart` 用的是同一套路（`Isolate.spawn(workerMain, ...)`）。
class _ProbeArgs {
  const _ProbeArgs(this.path, this.port);

  final String path;
  final SendPort port;
}

class _Smoke extends StatefulWidget {
  const _Smoke();

  @override
  State<_Smoke> createState() => _SmokeState();
}

class _SmokeState extends State<_Smoke> {
  final _path = TextEditingController(text: '/sdcard/Download/test.zip');
  final _out = TextEditingController(text: '/sdcard/Download/duz_out');
  final _log = StringBuffer();

  String _version = '(未取)';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // 最先要回答的问题：dll 加载得了吗、是不是真的 7-Zip 核心。
    try {
      _version = engineVersion();
    } on DuzEngineException catch (e) {
      _version = '加载失败：$e';
    }
  }

  @override
  void dispose() {
    _path.dispose();
    _out.dispose();
    super.dispose();
  }

  void _append(String line) {
    if (!mounted) return;
    setState(() {
      _log.writeln(line);
      if (_log.length > 20000) {
        _log.clear();
        _log.writeln('(日志已截断)');
      }
    });
  }

  // -------------------------------------------------------------------------
  // 在别的 isolate 里跑的正文
  // -------------------------------------------------------------------------

  /// 打开 + 列条目，返回可打印的行。
  static List<String> _probe(String path) {
    final a = DuzArchive.open([path]);
    try {
      final lines = <String>[
        '版本 ${a.version}',
        '条目 ${a.entries.length} 个，未压缩合计 ${a.unpackedSize} 字节，'
            '含加密条目：${a.hasEncryptedEntries}',
      ];
      for (final e in a.entries.take(40)) {
        lines.add(
          '  #${e.index} ${e.isDir ? 'D' : 'F'} ${e.size} B '
          '${e.encrypted ? 'enc' : '   '} ${e.name}',
        );
      }
      if (a.entries.length > 40) {
        lines.add('  …还有 ${a.entries.length - 40} 条');
      }
      return lines;
    } finally {
      a.close();
    }
  }

  /// 探测 isolate 的正文。**必须是静态方法**，理由见 [_ProbeArgs]。
  ///
  /// 失败时把异常格式化成一行发回去 —— 子 isolate 里抛的异常对象本身能不能
  /// 发送是另一码事（`DuzEngineException` 可以，但不必赌），发字符串最省心。
  static void _probeEntry(_ProbeArgs args) {
    try {
      for (final line in _probe(args.path)) {
        args.port.send(line);
      }
    } catch (e) {
      args.port.send('失败：$e');
    } finally {
      args.port.send(null); // 哨兵：无论成败都要发，否则主侧一直等
    }
  }

  /// 解压，进度通过 SendPort 回传，最后发一个 `null` 当结束哨兵。
  static void _extract(_ExtractArgs args) {
    try {
      // 输出目录必须先存在 —— 原生侧只往里写，不建它。
      final dir = Directory(args.outDir);
      if (!dir.existsSync()) dir.createSync(recursive: true);

      final a = DuzArchive.open([args.path], password: args.password);
      try {
        // 按「条目名变了」节流，而不是每条都发：7-Zip 报进度的频率远高于
        // 条目切换频率，原样转发会把端口和 UI 一起淹掉。
        String? last;
        a.extractAll(
          args.outDir,
          onProgress: (done, total, name) {
            if (name != null && name != last) {
              last = name;
              args.port.send('  … $done/$total  $name');
            }
            return true;
          },
        );
        // 数一下真落了几个节点 —— 这才是「解压成功」的硬证据，
        // 返回值只说明 7-Zip 没报错。
        final n = dir.listSync(recursive: true).length;
        args.port.send('完成：${args.outDir} 下现在有 $n 个节点');
      } finally {
        a.close();
      }
    } catch (e) {
      args.port.send('失败：$e');
    } finally {
      args.port.send(null); // 哨兵：无论成败都要发，否则主侧一直等
    }
  }

  // -------------------------------------------------------------------------
  // 界面
  // -------------------------------------------------------------------------

  Future<void> _run(Future<void> Function() body) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await body();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open() => _run(() async {
    final path = _path.text.trim();
    _append('>>> 打开 $path');

    final port = ReceivePort();
    final finished = Completer<void>();
    final sub = port.listen((Object? message) {
      if (message == null) {
        if (!finished.isCompleted) finished.complete();
      } else {
        _append('$message');
      }
    });

    try {
      await Isolate.spawn(_probeEntry, _ProbeArgs(path, port.sendPort));
      // 超时是兜底：isolate 若在发哨兵之前被系统杀掉，没有它这里会永远等下去。
      await finished.future.timeout(
        const Duration(minutes: 5),
        onTimeout: () => _append('(等待超时，探测 isolate 可能已被系统终止)'),
      );
      _append('--- 打开结束 ---');
    } catch (e) {
      _append('失败：$e');
    } finally {
      await sub.cancel();
      port.close();
    }
  });

  Future<void> _doExtract() => _run(() async {
    final path = _path.text.trim();
    final out = _out.text.trim();
    _append('>>> 解压 $path → $out');

    final port = ReceivePort();
    final finished = Completer<void>();
    final sub = port.listen((message) {
      if (message == null) {
        if (!finished.isCompleted) finished.complete();
      } else {
        _append('$message');
      }
    });

    try {
      await Isolate.spawn(
        _extract,
        _ExtractArgs(path, out, null, port.sendPort),
      );
      // 超时是兜底：isolate 若在发哨兵之前被系统杀掉，没有它这里会永远等下去。
      await finished.future.timeout(
        const Duration(minutes: 30),
        onTimeout: () => _append('(等待超时，解压 isolate 可能已被系统终止)'),
      );
      _append('--- 解压结束 ---');
    } catch (e) {
      _append('失败：$e');
    } finally {
      await sub.cancel();
      port.close();
    }
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('引擎：$_version'),
        const SizedBox(height: 8),
        TextField(
          controller: _path,
          decoration: const InputDecoration(labelText: '归档路径'),
        ),
        TextField(
          controller: _out,
          decoration: const InputDecoration(labelText: '输出目录'),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            FilledButton(
              onPressed: _busy ? null : _open,
              child: const Text('打开并列出'),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _busy ? null : _doExtract,
              child: const Text('解压'),
            ),
          ],
        ),
        const Divider(),
        Expanded(
          child: SingleChildScrollView(
            child: SelectableText(
              _log.toString(),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ),
      ],
    ),
  );
}
