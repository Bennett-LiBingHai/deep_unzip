/// 设置的读写。落在 `shared_preferences` 上。
///
/// ## 为什么这里可以放 shared_preferences
///
/// 它在本机就是个私有目录里的 XML，**明文**。所以：普通开关、深度、炸弹
/// 阈值放这儿没问题；**密码库绝不放这儿**，那走 `flutter_secure_storage`
/// （见 `vault_repo.dart`）。这条线写在下项目骨架时定死了，别改。
///
/// ## 键的布局
///
/// | 键 | 类型 | 内容 |
/// |---|---|---|
/// | `toggle.<名>` | bool | 六个开关，逐个独立存 |
/// | `maxDepth` | int | 递归深度，`{0,5,10,20}` |
/// | `limitPreset` | int | 炸弹档位下标，或「自定义」 |
/// | `limit.<字段>` | int | 自定义时那四个阈值 |
///
/// 开关**逐个独立存**而不是塞一个 JSON 串：新增一个开关时，老用户的档里
/// 没有这个键，`getBool` 回 null，代码里回退到默认值就完事 —— 不需要写
/// 「版本号 + 迁移」那套。缺键即默认，是这里唯一的兼容策略。
library;

import 'package:shared_preferences/shared_preferences.dart';

import '../engine/limits.dart';
import 'persist.dart';

class SettingsRepo {
  const SettingsRepo();

  static const String _togglePrefix = 'toggle.';
  static const String _limitPrefix = 'limit.';
  static const String _keyMaxDepth = 'maxDepth';
  static const String _keyLimitPreset = 'limitPreset';

  Future<SettingsData> load() async {
    final prefs = await SharedPreferences.getInstance();

    // 只认 [kDefaultToggles] 里那张表：档里多出来的键（老版本删掉的开关）
    // 不读，免得它们又活过来。
    final toggles = <String, bool>{};
    for (final entry in kDefaultToggles.entries) {
      toggles[entry.key] =
          prefs.getBool('$_togglePrefix${entry.key}') ?? entry.value;
    }

    final maxDepth = coerceMaxDepth(prefs.getInt(_keyMaxDepth));
    final preset = _coercePreset(prefs.getInt(_keyLimitPreset));

    // 预设档位时**以预设为准**，不信磁盘上那四个数：它们可能来自一个更早的
    // 版本，或者上一次「自定义」留下的残值。只有停在「自定义」时才读它们。
    LimitThresholds limits;
    if (preset < kLimitPresets.length) {
      limits = kLimitPresets[preset].thresholds;
    } else {
      limits = LimitThresholds.standard;
      for (final field in LimitField.values) {
        final v = prefs.getInt('$_limitPrefix${field.name}');
        // `> 0`：0 或负数不是一个有意义的阈值，落到它上面等于把闸门关掉。
        // 缺的、坏的项保持 [LimitThresholds.standard] 的值，仍是一套合法配置。
        if (v != null && v > 0) limits = field.apply(limits, v);
      }
    }

    return SettingsData(
      toggles: toggles,
      maxDepth: maxDepth,
      limitPreset: preset,
      limits: limits,
    );
  }

  Future<void> save(SettingsData data) async {
    final prefs = await SharedPreferences.getInstance();
    for (final entry in data.toggles.entries) {
      await prefs.setBool('$_togglePrefix${entry.key}', entry.value);
    }
    await prefs.setInt(_keyMaxDepth, data.maxDepth);
    await prefs.setInt(_keyLimitPreset, data.limitPreset);
    for (final field in LimitField.values) {
      await prefs.setInt('$_limitPrefix${field.name}', field.read(data.limits));
    }
  }

  /// 档位下标收敛到 `0..kLimitPresets.length`（含「自定义」那档）。
  int _coercePreset(int? raw) {
    if (raw == null) return kDefaultLimitPreset;
    return raw.clamp(0, kLimitPresets.length);
  }
}
