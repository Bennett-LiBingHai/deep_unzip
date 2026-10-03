/// `DuzErrorCode`（`lib/engine/protocol.dart`）与原生 `DUZ_ERR_*` 的一致性。
///
/// ## 为什么会有两份
///
/// `engine/` 里只有 `backends/native_backend.dart` 认识插件包 —— 这是刻意的：
/// 依赖外部世界的口子只留一个，换后端时签名不动。于是错误码在
/// `protocol.dart` 里放了一份**整数镜像**，插件的常量只在那一个文件里出现。
///
/// 镜子就会照歪，所以有了这份测试。链条是：
///
/// ```
/// duz_engine.h  ──ffigen──▶  DUZ_ERR_*（生成的 Dart 常量）
///                                    │
///                                    │ 本文件比对
///                                    ▼
///                            DuzErrorCode.*（手写镜像）
/// ```
///
/// 比对的是**生成物**而不是头文件原文，因为生成物就是编译期真正生效的那份：
/// ffigen 读 `duz_engine.h` 得出的值，和 `.so` 里 `duz_open` 返回的值同源。
/// 改了头文件却没重新生成，会先在别处以类型/符号错误暴露出来。
///
/// 注意本文件 import 了插件包 —— `git grep` 出来的「谁依赖了插件」清单里
/// 多一个**测试**是意料之内的，`lib/` 下面的口子仍然只有一个。
library;

import 'package:deep_unzip/engine/protocol.dart' as mirror;
import 'package:deep_unzip/engine/protocol.dart' show EngineException;
import 'package:deep_unzip_engine/deep_unzip_engine.dart' as engine;
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DuzErrorCode 镜像与原生 DUZ_ERR_* 一致', () {
    // 用表驱动而不是六条独立断言：漏掉一条新错误码时，`_pairs` 里不会有它，
    // 而下面那条「条数对得上」会红 —— 独立断言反而会被无声地忘记补。
    const pairs = <String, (int mirrorValue, int nativeValue)>{
      'ok': (mirror.DuzErrorCode.ok, engine.DUZ_OK),
      'open': (mirror.DuzErrorCode.open, engine.DUZ_ERR_OPEN),
      'password': (mirror.DuzErrorCode.password, engine.DUZ_ERR_PASSWORD),
      'unsupported':
          (mirror.DuzErrorCode.unsupported, engine.DUZ_ERR_UNSUPPORTED),
      'arg': (mirror.DuzErrorCode.arg, engine.DUZ_ERR_ARG),
      'extract': (mirror.DuzErrorCode.extract, engine.DUZ_ERR_EXTRACT),
      'noMem': (mirror.DuzErrorCode.noMem, engine.DUZ_ERR_NOMEM),
    };

    pairs.forEach((name, values) {
      test(name, () {
        expect(
          values.$1,
          values.$2,
          reason: 'DuzErrorCode.$name 与插件常量漂移了 —— 改了 '
              'duz_engine.h 或 protocol.dart 的话，两边一起改',
        );
      });
    });

    test('这张表覆盖了全部镜像常量（加了新的要记得补进来）', () {
      // 这里不列出「应该有几个」这个数字：写死数字的话，加错误码时改两处
      // 而不是一处，改的人多半会顺手把数字也改掉，等于没拦。改成校验
      // 「每个已知常量都在表里」——靠的是下面这份清单本身。
      //
      // 断言形式：把表里的镜像个倒过来，看有没有哪个常量名缺席。
      const known = {
        mirror.DuzErrorCode.ok,
        mirror.DuzErrorCode.open,
        mirror.DuzErrorCode.password,
        mirror.DuzErrorCode.unsupported,
        mirror.DuzErrorCode.arg,
        mirror.DuzErrorCode.extract,
        mirror.DuzErrorCode.noMem,
      };
      expect(pairs.length, known.length, reason: '表里漏了或多了常量');
      expect({for (final v in pairs.values) v.$1}, known);
    });
  });

  group('错误码的语义约定', () {
    test('ok 是 0，其余全是负数（原生侧用 0 表示成功）', () {
      expect(mirror.DuzErrorCode.ok, 0);
      expect(mirror.DuzErrorCode.open, isNegative);
      expect(mirror.DuzErrorCode.password, isNegative);
      expect(mirror.DuzErrorCode.unsupported, isNegative);
      expect(mirror.DuzErrorCode.arg, isNegative);
      expect(mirror.DuzErrorCode.extract, isNegative);
      expect(mirror.DuzErrorCode.noMem, isNegative);
    });

    test('没有两个错误码撞在同一个数值上', () {
      // 撞了的话 switch (e.code) 会静默走进错误的分支 —— 那是运行期才发现
      // 的那类 bug，值得在这里挡住。
      const all = [
        mirror.DuzErrorCode.ok,
        mirror.DuzErrorCode.open,
        mirror.DuzErrorCode.password,
        mirror.DuzErrorCode.unsupported,
        mirror.DuzErrorCode.arg,
        mirror.DuzErrorCode.extract,
        mirror.DuzErrorCode.noMem,
      ];
      expect(all.toSet(), hasLength(all.length));
    });

    test('EngineException.code 是可空的 —— 非原生失败没有错误码', () {
      const e = EngineException('协议出错');
      expect(e.code, isNull);

      const withCode = EngineException(
        '需要密码',
        code: mirror.DuzErrorCode.password,
      );
      expect(withCode.code, mirror.DuzErrorCode.password);
    });
  });
}
