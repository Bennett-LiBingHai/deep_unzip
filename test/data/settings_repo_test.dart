import 'package:deep_unzip/data/persist.dart';
import 'package:deep_unzip/data/settings_repo.dart';
import 'package:deep_unzip/engine/limits.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// `shared_preferences` 落在 Android 上就是一个**明文 XML**，所以这里除了
/// 往返正确，还要钉住「键怎么摆」以及**两条收敛**：
///
/// 1. `maxDepth` 与 `maxLogs` 都是**自由输入**，收敛方式一样：只夹回区间，
///    **不吸附到档位**。深度可填 `0`–[kMaxMaxDepth]（`0` = 不递归，是语义
///    而不是「填错了」），日志可填 [kMinMaxLogs]–[kMaxMaxLogs]。
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
        'toggle.fakeExtDetect': false, // 只有这一个存过
      });

      final data = await repo.load();

      expect(data.toggles['fakeExtDetect'], isFalse, reason: '存过的要读出来');
      expect(data.toggles['pwdAutoSave'], isTrue, reason: '没存过的回出厂默认');
      expect(data.toggles.keys, kDefaultToggles.keys,
          reason: '键集必须与出厂表完全一致，不能多也不能少');
    });

    test('改过名的开关：老键的值跟着过来，用户的取舍不会因为升级而变', () async {
      // `pwdPrompt` 原叫 `pwdAutoTry`。老用户档里只有旧键 —— 读不到的话这个
      // 开关会当场跳回出厂默认（true），用户升级一次就发现设置自己变了。
      SharedPreferences.setMockInitialValues({
        'toggle.pwdAutoTry': false,
      });

      final data = await repo.load();

      expect(data.toggles['pwdPrompt'], isFalse,
          reason: '旧键 = 用户的取舍，要认');
      expect(data.toggles.keys, kDefaultToggles.keys,
          reason: '认旧键不等于把旧键搬进结果集 —— 读出来仍然只有新键');
    });

    test('新旧键并存 → 新键说话', () async {
      // 只可能是「升级后改过、又用旧版本装回来」这种折腾出来的档。留着旧值
      // 当判据的话，用户在新版本里点的开关会被一个看不见的幽灵盖掉。
      SharedPreferences.setMockInitialValues({
        'toggle.pwdPrompt': true,
        'toggle.pwdAutoTry': false,
      });

      final data = await repo.load();

      expect(data.toggles['pwdPrompt'], isTrue);
    });
  });

  group('往返', () {
    // 名字里**不写开关的条数**：这张表加过一次（`pwdAutoSave`），以后再加
    // 还得改一次名字，而名字跟断言没关系 —— 要钉的是「原样回来」。
    test('开关 + 深度 + 日志封顶 + 自定义阈值原样回来', () async {
      // 这份 map 必须**逐个列出全部开关**：`load` 只认 `kDefaultToggles` 里
      // 那些键，漏写一个就会被补成出厂默认 —— `expect(back.toggles == saved)`
      // 于是失败在「少写了一个」而不是「存坏了」。等于用一次红灯逼着加开关的人
      // 回这里报到（`缺一个开关的键` 那条是它的另一面，测的是老用户的档）。
      const saved = SettingsData(
        toggles: {
          'customOutput': false,
          'fakeExtDetect': true,
          'pwdPrompt': false,
          'pwdAutoSave': false,
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
    test('深度是自由输入：区间内的值原样保留，界外才夹', () async {
      // 与 `maxLogs` 同一条规矩：没有档位表可以让值「最近」到哪儿去 —— 7 就
      // 该是 7，不该被挪成 5 或 10。只有越界才动它。
      for (final (raw, expected) in [
        (0, 0), // 0 = 不递归，是语义而不是「填错了」
        (7, 7),
        (19, 19),
        (kMinMaxDepth, kMinMaxDepth),
        (kMaxMaxDepth, kMaxMaxDepth),
        (-9, kMinMaxDepth),
        (99, kMaxMaxDepth),
      ]) {
        SharedPreferences.setMockInitialValues({'maxDepth': raw});
        final data = await repo.load();
        expect(data.maxDepth, expected, reason: '$raw 应收敛成 $expected');
      }
    });

    test('老档里的 0 照读成「不递归」，不替用户翻译', () async {
      // 旧版本里 0 是「无限制」，而它当时同时是出厂默认值 —— 所以老档里大概率
      // 就是个 0。这里刻意**不**把它改成别的：磁盘上分不出「旧版写的 0」和
      // 「用户照着新语义刚设的 0」，而猜错的方向是把人特意关掉的递归又打开。
      // 真要迁移得换键名（`maxDepthV2`），不是在这一层猜。
      SharedPreferences.setMockInitialValues({'maxDepth': 0});
      expect((await repo.load()).maxDepth, 0);
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
      expect(prefs.getBool('toggle.customOutput'), isFalse,
          reason: '「目录对称输出」改名成「自定义输出目录」，出厂关');
      expect(prefs.getBool('toggle.symmetricOutput'), isNull,
          reason: '旧键不该再写下去 —— 那颗开关从没被读过，它的值不承载任何意图');
      expect(prefs.getBool('toggle.errorPause'), isTrue);
      expect(prefs.getBool('toggle.recursive'), isNull,
          reason: '「递归解压」那颗 2026-10 删了，不该再有键写下去');
      expect(prefs.getBool('toggle.pwdAutoSave'), isTrue,
          reason: '手输密码自动入库那颗，默认开');
      expect(prefs.getInt('maxDepth'), kDefaultMaxDepth);
      expect(prefs.getInt('maxLogs'), kDefaultMaxLogs);
      expect(prefs.getInt('limitPreset'), kDefaultLimitPreset);
      expect(prefs.getInt('limit.entries'), LimitThresholds.standard.maxEntries);
      expect(prefs.getInt('limit.ratio'), LimitThresholds.standard.maxRatio);
    });
  });
}
