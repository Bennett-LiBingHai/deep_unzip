/// 密码库的读写。落在 `flutter_secure_storage` 上。
///
/// ## 为什么必须是 secure storage
///
/// `shared_preferences` 在 Android 上就是一个**明文 XML**（应用私有目录，
/// root 或备份就能读走）。密码库里的每一条都是用户从别处抄来的、很可能还
/// 在别处复用着的口令 —— 那不是一个可以明文落盘的量级。`flutter_secure_storage`
/// 走 Android Keystore（硬件支持的 AES-GCM），密钥不出 TEE。
///
/// 这条线是项目骨架里定死的，**没有任何「以后再说」的余地**。
///
/// ## 单键整存
///
/// 整个数组塞在一个键 `vault_v1` 下，而不是一条一个键：密码库的规模是
/// 「几十条」这个量级，整存整取的代价可以忽略，换来的是**天然的事务性**
/// —— 不会出现「删了三条、写进去两条」这种半截状态。要改结构时改的是这份
/// JSON 的 schema，`v` 字段就是为它准备的。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/password_entry.dart';

class VaultRepo {
  // 参数名与字段名（`_storage`）**不止差一个下划线**：Dart 不允许私有具名
  // 参数，而 `prefer_initializing_formals` 只比对「去掉下划线之后是否同名」——
  // 叫 `storage` 会换来一条改不掉的假警告（与 `AppState` 构造函数同一回事）。
  const VaultRepo({
    FlutterSecureStorage secureStorage = const FlutterSecureStorage(),
  }) : _storage = secureStorage;

  final FlutterSecureStorage _storage;

  static const String _key = 'vault_v1';

  /// 这份 JSON 的结构版本。结构一变就加一，[load] 认出旧版本直接当空库 ——
  /// 密码库不值得为迁移写一套代码，丢一次比留着半懂不懂的数据安全。
  static const int _schemaVersion = 1;

  /// 读回密码库。任何读不出来的情况都返回空列表。
  ///
  /// **不抛异常**，因为其中一种失败是真会发生的：用户换机时用系统的应用备份
  /// 把 app 恢复过来，但 Keystore 里的密钥**不跟着走**，于是每个已存的密文
  /// 都解不开，`read` 直接抛。这时正确反应是给一个空库让用户重新录，
  /// 而不是启动就崩。
  Future<List<PasswordEntry>> load() async {
    final Object? decoded;
    try {
      final raw = await _storage.read(key: _key);
      if (raw == null || raw.isEmpty) return const [];
      decoded = jsonDecode(raw);
    } on Exception catch (e) {
      debugPrint('密码库读取失败，按空库处理：$e');
      return const [];
    }

    if (decoded is! Map) return const [];
    if (decoded['v'] != _schemaVersion) return const [];
    final entries = decoded['entries'];
    if (entries is! List) return const [];

    final out = <PasswordEntry>[];
    for (final raw in entries) {
      if (raw is! Map) continue;
      final entry = _decodeEntry(raw);
      if (entry != null) out.add(entry);
    }
    return out;
  }

  /// 整库覆盖写。失败**会抛** —— 由 `DeviceStore` 决定要不要吞。
  ///
  /// 这里不自己吞是刻意的：读失败可以退化成空库，写失败却是「用户的改动没了」，
  /// 两种失败的严重性不是一个量级，不该在同一个地方被同一句 catch 抹平。
  Future<void> save(List<PasswordEntry> entries) {
    return _storage.write(
      key: _key,
      value: jsonEncode({
        'v': _schemaVersion,
        'entries': [
          for (final e in entries)
            {
              'value': e.value,
              'hitCount': e.hitCount,
              'lastUsed': e.lastUsed,
            },
        ],
      }),
    );
  }

  /// 单个条目。字段类型不对就整条丢掉，而不是补个默认值收下 —— 一条
  /// value 是空的密码没有任何用，收下只会让密码库里多一行点不动的空条目。
  PasswordEntry? _decodeEntry(Map raw) {
    final value = raw['value'];
    if (value is! String || value.isEmpty) return null;

    final hitCount = raw['hitCount'];
    final lastUsed = raw['lastUsed'];
    return PasswordEntry(
      value: value,
      hitCount: hitCount is int && hitCount >= 0 ? hitCount : 0,
      lastUsed: lastUsed is String ? lastUsed : '',
    );
  }
}
