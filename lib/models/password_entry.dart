/// 密码库条目
class PasswordEntry {
  final String value;
  final int hitCount;
  final String lastUsed;

  const PasswordEntry({
    required this.value,
    this.hitCount = 0,
    this.lastUsed = '',
  });

  PasswordEntry copyWith({String? value, int? hitCount, String? lastUsed}) {
    return PasswordEntry(
      value: value ?? this.value,
      hitCount: hitCount ?? this.hitCount,
      lastUsed: lastUsed ?? this.lastUsed,
    );
  }
}
