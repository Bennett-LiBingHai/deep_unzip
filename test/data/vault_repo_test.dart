import 'dart:convert';

import 'package:deep_unzip/data/vault_repo.dart';
import 'package:deep_unzip/models/password_entry.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

/// 密码库有三件事要钉死：
///
/// 1. **落在哪**：键必须是 `vault_v1`，而且只此一个。这是骨架里定死的产品
///    约束（明文 XML 里绝不能出现口令），改键名要有意识地改，不能顺手。
/// 2. **读不回来时给空库而不是崩**：换机恢复备份会让 Keystore 里的密钥对不上，
///    每个已存密文都解不开 —— 这是真会发生的路径，不是理论。
/// 3. **坏数据要被丢掉而不是猜**：一条 value 是空的密码没有任何用，收下只会
///    让密码库多一行点不动的空条目。
void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  const repo = VaultRepo();

  group('往返', () {
    test('空库起步', () async {
      expect(await repo.load(), isEmpty);
    });

    test('三条密码原样回来，含命中次数与最近使用', () async {
      const saved = [
        PasswordEntry(value: 'hunter2', hitCount: 7, lastUsed: '2026-10-01'),
        PasswordEntry(value: '压缩包密码', hitCount: 0, lastUsed: ''),
        PasswordEntry(value: 'p@ss word', hitCount: 2, lastUsed: '2026-09-28'),
      ];

      await repo.save(saved);
      final back = await repo.load();

      expect(back.length, 3);
      // 顺序也是内容的一部分：视图按库里的顺序渲染，而候选排序（条目 5）
      // 是在视图层另做的。这里翻了顺序，条目 5 就白做了。
      expect(back.map((e) => e.value).toList(),
          ['hunter2', '压缩包密码', 'p@ss word']);
      expect(back[0].hitCount, 7);
      expect(back[0].lastUsed, '2026-10-01');
      expect(back[1].hitCount, 0);
      expect(back[1].lastUsed, '');
    });

    test('空库存一次再读还是空库，不是 null', () async {
      await repo.save(const []);
      expect(await repo.load(), isEmpty);
    });
  });

  group('键与结构是对外契约', () {
    test('存在单个键 vault_v1 下，值是一份带版本号的 JSON', () async {
      const storage = FlutterSecureStorage();
      await repo.save(const [PasswordEntry(value: 'abc')]);

      final raw = await storage.read(key: 'vault_v1');
      expect(raw, isNotNull, reason: '键名一改，老用户的密码库就静默读不出来');

      final decoded = jsonDecode(raw!) as Map;
      expect(decoded['v'], 1);
      expect((decoded['entries'] as List).single, {
        'value': 'abc',
        'hitCount': 0,
        'lastUsed': '',
      });

      // 明文口令**只能**出现在这个键里。多存一份到别处（比如给 UI 缓存用的
      // 另一个键）就是把上面那条约束绕过去了。
      expect(await storage.readAll(), hasLength(1));
    });
  });

  group('读不出来一律空库，不抛', () {
    test('不是 JSON', () async {
      FlutterSecureStorage.setMockInitialValues({'vault_v1': '这不是 JSON'});
      expect(await repo.load(), isEmpty);
    });

    test('JSON 但不是对象', () async {
      FlutterSecureStorage.setMockInitialValues({'vault_v1': '[1,2,3]'});
      expect(await repo.load(), isEmpty);
    });

    test('版本号对不上 —— 结构变了就整份当空库，不猜', () async {
      FlutterSecureStorage.setMockInitialValues({
        'vault_v1': jsonEncode({
          'v': 99,
          'entries': [
            {'value': '旧结构的密码'},
          ],
        }),
      });
      expect(await repo.load(), isEmpty);
    });

    test('缺 entries', () async {
      FlutterSecureStorage.setMockInitialValues({
        'vault_v1': jsonEncode({'v': 1}),
      });
      expect(await repo.load(), isEmpty);
    });
  });

  group('单条坏数据丢掉，不牵连别的', () {
    test('value 为空 / 缺失 / 不是字符串 → 丢那一条', () async {
      FlutterSecureStorage.setMockInitialValues({
        'vault_v1': jsonEncode({
          'v': 1,
          'entries': [
            {'value': '好的', 'hitCount': 1, 'lastUsed': '2026-10-01'},
            {'value': ''},
            {'hitCount': 3},
            {'value': 42},
            'not a map',
            {'value': '也好', 'hitCount': -1, 'lastUsed': 5},
          ],
        }),
      });

      final back = await repo.load();
      expect(back.map((e) => e.value).toList(), ['好的', '也好']);
      expect(back[1].hitCount, 0, reason: '负数命中次数没有意义，归 0');
      expect(back[1].lastUsed, '', reason: '不是字符串的最近使用归空');
    });
  });
}
