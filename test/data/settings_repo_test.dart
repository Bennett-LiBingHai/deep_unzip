import 'package:deep_unzip/data/persist.dart';
import 'package:deep_unzip/data/settings_repo.dart';
import 'package:deep_unzip/engine/limits.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// `shared_preferences` 落在 Android 上就是一个**明文 XML**，所以这里除了
/// 往返正确，还要钉住「键怎么摆」以及**两条收敛**：
///
/// 1. `maxDepth` 必须落在 `{0,5,10,20}` 里 —— 表外的值会让设置页的芯片
///    用 `indexOf` 拿到 -1，再拿去索引标签数组就是越界崩溃。（`maxLogs` 是
///    自由输入，收敛方式不同：只夹回区间，不吸附到档位。）
/// 2. 非「自定义」档时，阈值**以预设为准**，不信磁盘上那四个数 ——
///    否则会出现「chip 写着『严格』、闸门跑的是另一套」这种没人查得出来的错。
void main() {
  // `setMockInitialValues` 会同时把单例置空，所以每个用例都能从干净的一档
  // 起步，不必自己清理。
  setUp(() => SharedPreferences.setMockInitialValues({}));

  const repo = SettingsRepo();

  group('空档即出厂默认', () {
    test('第一次启动读出来的是 SettingsData.defaults', () async {
      final data = await repo.load();

      expect(data.toggles, kDefaultToggles);
      expect(data.maxDepth, kDefaultMaxDepth);
      expect(data.maxLogs, kDefaultMaxLogs);
      expect(data.limitPreset, kDefaultLimitPreset);
      expect(data.limits, LimitThresholds.standard);
    });

    test('缺一个开关的键 → 那一个回默认，别的照读', () async {
      // 新增开关时老用户的档就长这样：没有新键。缺键即默认是这里唯一的
      // 兼容策略（见 settings_repo 的库注释），不写「版本号 + 迁移」。
      SharedPreferences.setMockInitialValues({
        'toggle.splitMerge': false, // 只有这一个存过
      });

      final data = await repo.load();

      expect(data.toggles['splitMerge'], isFalse, reason: '存过的要读出来');
      expect(data.toggles['recursive'], isTrue, reason: '没存过的回出厂默认');
      expect(data.toggles.keys, kDefaultToggles.keys,
          reason: '键集必须与出厂表完全一致，不能多也不能少');
    });
  });

  group('往返', () {
    test('六个开关 + 深度 + 日志封顶 + 自定义阈值原样回来', () async {
      const saved = SettingsData(
        toggles: {
          'recursive': false,
          'symmetricOutput': false,
          'fakeExtDetect': true,
          'splitMerge': false,
          'pwdAutoTry': false,
          'errorPause': true,
        },
        maxDepth: 10,
        maxLogs: 1000,
        limitPreset: 3, // 3 == kLimitPresets.length，即「自定义」
        limits: LimitThresholds(
          maxEntries: 12345,
          maxEntryBytes: 2 << 30,
          maxTotalBytes: 32 << 30,
          maxRatio: 500,
        ),
      );

      await repo.save(saved);
      final back = await repo.load();

      expect(back.toggles, saved.toggles);
      expect(back.maxDepth, 10);
      expect(back.maxLogs, 1000);
      expect(back.limitPreset, 3);
      expect(back.limits.maxEntries, 12345);
      expect(back.limits.maxEntryBytes, 2 << 30);
      expect(back.limits.maxTotalBytes, 32 << 30);
      expect(back.limits.maxRatio, 500);
    });

    test('档位与阈值必须一起存 —— 从值反推档位会让编辑器自己合上', () async {
      // 存「严格」，但四个阈值恰好等于「标准」。读回来 chip 必须还是严格，
      // 判据是存下来的 `limitPreset`，不是值本身。
      await repo.save(SettingsData(
        limitPreset: 2,
        limits: LimitThresholds.standard,
      ));

      final back = await repo.load();
      expect(back.limitPreset, 2);
      expect(back.limits, LimitThresholds.strict,
          reason: '非自定义档时以预设为准，磁盘上那四个数不算数');
    });
  });

  group('加载时的收敛', () {
    test('深度落在表外 → 收敛到最近的合法档，不崩溃', () async {
      // `settings_screen` 的芯片用 `kMaxDepthOptions.indexOf(maxDepth)` 定位，
      // 拿到 -1 就直接越界崩。所以这条必须在这里就收住。
      for (final (raw, expected) in [(7, 5), (18, 20), (3, 5), (-9, 0), (99, 20)]) {
        SharedPreferences.setMockInitialValues({'maxDepth': raw});
        final data = await repo.load();
        expect(data.maxDepth, expected, reason: '$raw 应收敛成 $expected');
        expect(kMaxDepthOptions.contains(data.maxDepth), isTrue);
      }
    });

    test('深度取最近的合法档而不是无脑归零', () async {
      // 用户真设过 20 层，值要是落在表外，归零等于把他设的限制悄悄放开。
      SharedPreferences.setMockInitialValues({'maxDepth': 19});
      expect((await repo.load()).maxDepth, 20);
    });

    test('日志封顶越界 → 夹回区间，但**不吸附**', () async {
      // 跟深度那条不一样：条数是自由输入，没有一张表可以让它「最近」到哪儿
      // 去 —— 350 就该是 350，不该被挪成 300 或 500。只有越界才动它。
      for (final (raw, expected) in [
        (350, 350),
        (1, 1),
        (kMaxMaxLogs, kMaxMaxLogs),
        (0, kMinMaxLogs),
        (-5, kMinMaxLogs),
        (999999, kMaxMaxLogs),
      ]) {
        SharedPreferences.setMockInitialValues({'maxLogs': raw});
        final data = await repo.load();
        expect(data.maxLogs, expected, reason: '$raw 应收敛成 $expected');
      }
    });

    test('档位下标越界 → 夹回合法区间', () async {
      SharedPreferences.setMockInitialValues({'limitPreset': 99});
      expect((await repo.load()).limitPreset, kLimitPresets.length);
    });

    test('自定义档里 0 / 负数不是阈值，保持标准值', () async {
      // 落到 0 等于把闸门整个关掉（`unpackedBytes > 0` 永远成立）。
      SharedPreferences.setMockInitialValues({
        'limitPreset': kLimitPresets.length,
        'limit.entries': 0,
        'limit.entryBytes': -5,
        'limit.totalBytes': 4 << 30,
        'limit.ratio': 300,
      });

      final limits = (await repo.load()).limits;
      expect(limits.maxEntries, LimitThresholds.standard.maxEntries);
      expect(limits.maxEntryBytes, LimitThresholds.standard.maxEntryBytes);
      expect(limits.maxTotalBytes, 4 << 30, reason: '合法的那个要读进来');
      expect(limits.maxRatio, 300);
    });

    test('自定义档里缺项 → 缺失的那项保持标准值，仍是一套合法配置', () async {
      SharedPreferences.setMockInitialValues({
        'limitPreset': kLimitPresets.length,
        'limit.ratio': 300,
      });

      final limits = (await repo.load()).limits;
      expect(limits.maxRatio, 300);
      expect(limits.maxEntries, LimitThresholds.standard.maxEntries);
    });
  });

  group('键的名字是对外契约', () {
    test('写下去的键名与 main.dart 之外的任何读方对齐', () async {
      // 名字一改，老用户的档就静默读不出来（回默认），而单测要是只测往返
      // 就发现不了 —— 往返用的是同一份代码。这里把字面量钉死。
      await repo.save(const SettingsData());

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('toggle.recursive'), isTrue);
      expect(prefs.getBool('toggle.errorPause'), isTrue);
      expect(prefs.getInt('maxDepth'), kDefaultMaxDepth);
      expect(prefs.getInt('maxLogs'), kDefaultMaxLogs);
      expect(prefs.getInt('limitPreset'), kDefaultLimitPreset);
      expect(prefs.getInt('limit.entries'), LimitThresholds.standard.maxEntries);
      expect(prefs.getInt('limit.ratio'), LimitThresholds.standard.maxRatio);
    });
  });
}
