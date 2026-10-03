/// 自引用检测与递归深度顶。
///
/// 需求 1 说「嵌套压缩包继续解压」，而这条规则在没有护栏时**不终止**：
///
/// - **自引用**：`a.zip` 里装着 `a.zip`（内容一模一样）。解出来又扫到它，
///   再解再扫……每一层都在磁盘上留下**一份真实的拷贝**，不是无害的空转。
/// - **深度炸弹**：`a.zip` 装 `b.zip` 装 `c.zip`……每层都合法，但层数没有
///   自然上限。用户设置里的 `maxDepth = 0`（无限制）在 UI 上是个合理的
///   默认值，在实现层却不能真的当「无限制」用。
///
/// 两者都要在**入队前**拦住，不能等跑起来再发现 —— 那时磁盘已经写满了。
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';

/// 读取身份指纹时最多读多少字节。
///
/// 64 KiB 是刻意的折中：够长，足以把「同一个包」和「只是开头碰巧一样」分开；
/// 又够短，解压一个上千层的大包扫描期读头部不会成为瓶颈。
/// 而且**只读这么点**意味着这个函数对 33 MB 的包和 143 字节的包一样快。
const int kIdentityHeadBytes = 64 * 1024;

/// 递归深度的**硬顶**，用户设置再大也不能越过。
///
/// 用户设置里的 `maxDepth` 有「0 = 无限制」这一档，但实现层必须有一个
/// 绝对上限：它同时也是 `scanner.dart` 里 [kMaxScanDepth] 的量级，
/// 两处对不上会出现「扫描器拒进的深度，解压器还在往里塞任务」。
const int kHardDepthCeiling = 64;

/// 计算一个压缩包的**身份指纹**，用于自引用检测。
///
/// 身份 = `sha1(前 64 KiB) + 文件大小 + 文件名`。三个成分各挡一类误判：
///
/// - **内容前缀**挡的是「同一份数据被改名/换目录」—— 那才是自引用的真身。
/// - **大小**让「前缀相同但被截断」的两份文件不会撞成同一个身份。
/// - **文件名**是刻意的保守项：`a.zip` 和 `b.zip` 内容完全相同（比如两个
///   副本被打包进同一个目录），它们是**两个**包，不该因为内容一样就被判成
///   自引用而漏解。加了文件名，只有「名字也一样」才认为是同一个包。
///
/// 读不到文件时返回一个**独一无二**的身份（带路径与一个不可能重复的前缀），
/// 让它和任何祖先都不相等。这是刻意的失败方向：读不到文件应该表现为
/// 「照常尝试解压、由解压器去报错」，而不是「被静默当成自引用跳过」——
/// 后者会让用户看到一个包无声无息地消失，最难查。
Future<String> archiveIdentity(String path) async {
  try {
    final file = File(path);
    final size = await file.length();
    final head = await file.openRead(0, kIdentityHeadBytes).fold<List<int>>(
      <int>[],
      (acc, chunk) => acc..addAll(chunk),
    );
    final digest = sha1.convert(head);
    return '${digest.toString()}:$size:${_baseName(path)}';
  } catch (_) {
    // 路径参与其中，所以两个读不到的文件也不会互相撞。
    return 'unreadable:$path';
  }
}

/// 双向的「这个包是不是它自己某个祖先」判定。
///
/// 用 [Set] 而不是逐个 [String] 比较：递归深度上去了以后，每层都要跟
/// 一整条祖先链比一次，线性扫会变成 O(深度²)。
bool isSelfReferential(String identity, Set<String> ancestors) =>
    ancestors.contains(identity);

/// 深度 [depth] 的任务允不允许入队。
///
/// [maxDepth] 的语义与设置页保持一致：`<= 0` 表示「不限」，但**不限也要
/// 服从 [kHardDepthCeiling]**。用户设了 5，就是 5，不会被硬顶抬上去。
bool withinDepthLimit(int depth, int maxDepth) {
  final limit = maxDepth <= 0
      ? kHardDepthCeiling
      : math.min(maxDepth, kHardDepthCeiling);
  return depth <= limit;
}

/// 路径末段。不引 `package:path` —— 这里只需要一个「最后一段」，
/// 而 `output_paths.dart` 已经证明了归一化写法在不同宿主机上更稳。
String _baseName(String path) {
  final normalized = path.replaceAll('\\', '/');
  final slash = normalized.lastIndexOf('/');
  return slash < 0 ? normalized : normalized.substring(slash + 1);
}

/// 从一段路径列表里取身份，**顺序与去重都不重要**，只求集合。
///
/// 分卷包的身份取自它的**入口点**而不是全部卷：卷是同一个逻辑包的切片，
/// 用入口点做身份才和「包」这个概念一致。
Future<Set<String>> identitiesOf(Iterable<String> entryPaths) async {
  final out = <String>{};
  for (final path in entryPaths) {
    out.add(await archiveIdentity(path));
  }
  return out;
}

/// 供调试用：把身份串的可读部分截出来。
///
/// 完整身份是 `sha1:size:name`，日志里只打头 8 位十六进制就够了 ——
/// 它只是给人眼看「这两个是同一个吗」，不是给人看的哈希值。
String shortIdentity(String identity) {
  if (identity.startsWith('unreadable:')) return 'unreadable';
  final colon = identity.indexOf(':');
  final digest = colon < 0 ? identity : identity.substring(0, colon);
  return digest.length <= 8 ? digest : digest.substring(0, 8);
}
