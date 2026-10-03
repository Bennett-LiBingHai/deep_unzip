import '../models/archive_file.dart';
import '../models/password_entry.dart';
import '../models/log_entry.dart';
import '../models/extractor.dart';

/// 模拟数据
class MockData {
  static const List<ArchiveFile> archives = [
    ArchiveFile(
      name: '项目资料包_最终版.zip',
      type: ArchiveType.zip,
      size: '245 MB',
      flags: [ArchiveFlag.nested],
    ),
    ArchiveFile(
      name: 'encrypted_data.rar',
      type: ArchiveType.rar,
      size: '88 MB',
      flags: [ArchiveFlag.encrypted],
    ),
    ArchiveFile(
      name: 'backup_2026.part01.rar',
      type: ArchiveType.rar,
      size: '1.2 GB',
      flags: [ArchiveFlag.split],
    ),
    ArchiveFile(
      name: '伪装成PDF的压缩包.pdf',
      type: ArchiveType.unknown,
      size: '12 MB',
      flags: [ArchiveFlag.fakeExtension],
    ),
    ArchiveFile(
      name: 'old_backup.7z',
      type: ArchiveType.sevenz,
      size: '320 MB',
    ),
    ArchiveFile(
      name: 'multi_layer.tar.gz',
      type: ArchiveType.tar,
      size: '45 MB',
      flags: [ArchiveFlag.nested],
    ),
  ];

  static const List<PasswordEntry> passwords = [
    PasswordEntry(value: '123456', hitCount: 23, lastUsed: '2026-09-28'),
    PasswordEntry(value: 'password', hitCount: 15, lastUsed: '2026-09-25'),
    PasswordEntry(value: 'admin@2024', hitCount: 8, lastUsed: '2026-09-20'),
    PasswordEntry(value: 'deepunzip', hitCount: 3, lastUsed: '2026-09-15'),
  ];

  static const List<LogEntry> logs = [
    LogEntry(
      name: '项目资料包_最终版.zip',
      status: LogStatus.success,
      size: '245 MB',
      time: '今天 14:32',
      duration: '8.2s',
      tags: ['嵌套×3', '密码匹配', 'ZIP'],
    ),
    LogEntry(
      name: 'backup_2026.part01.rar',
      status: LogStatus.success,
      size: '1.2 GB',
      time: '今天 11:05',
      duration: '45.1s',
      tags: ['分片×5', 'RAR5', 'CRC通过'],
    ),
    LogEntry(
      name: 'encrypted_data.rar',
      status: LogStatus.success,
      size: '88 MB',
      time: '昨天 22:18',
      duration: '5.6s',
      tags: ['密码:123456', 'AES-256'],
    ),
    LogEntry(
      name: '伪装成PDF的压缩包.pdf',
      status: LogStatus.success,
      size: '12 MB',
      time: '昨天 19:40',
      duration: '2.1s',
      tags: ['后缀篡改', '实为ZIP', '自动识别'],
    ),
    LogEntry(
      name: 'corrupted_archive.zip',
      status: LogStatus.failed,
      size: '56 MB',
      time: '昨天 16:22',
      duration: '3.4s',
      tags: ['CRC失败', '文件头损坏'],
    ),
    LogEntry(
      name: 'old_backup.7z',
      status: LogStatus.skipped,
      size: '320 MB',
      time: '10-01 09:15',
      duration: '-',
      tags: ['用户跳过', '7Z固实'],
    ),
    LogEntry(
      name: 'multi_layer_nested.tar.gz',
      status: LogStatus.partial,
      size: '45 MB',
      time: '09-30 20:33',
      duration: '12.8s',
      tags: ['嵌套×5', '1个子包失败', 'TAR.GZ'],
    ),
  ];

  static const List<Extractor> extractors = [
    Extractor(
      name: 'ZIP',
      type: ExtractorType.single,
      detectLogic: 'readHeader(4) === 0x504B0304',
      extractLogic: 'unzip -o {file} -d {dir}',
      isBuiltin: true,
    ),
    Extractor(
      name: 'RAR5',
      type: ExtractorType.single,
      detectLogic: 'readHeader(7) === 0x526172211A0701',
      extractLogic: 'unrar x -y {file} {dir}',
      isBuiltin: true,
    ),
    Extractor(
      name: '7Z',
      type: ExtractorType.single,
      detectLogic: 'readHeader(6) === 0x377ABCAF271C',
      extractLogic: '7z x -y {file} -o{dir}',
      isBuiltin: true,
    ),
    Extractor(
      name: 'TAR.GZ',
      type: ExtractorType.single,
      detectLogic: 'readHeader(2) === 0x1F8B',
      extractLogic: 'tar -xzf {file} -C {dir}',
      isBuiltin: true,
    ),
    Extractor(
      name: 'RAR 分卷',
      type: ExtractorType.split,
      detectLogic: '匹配 *.part01.rar / *.r01 序列',
      extractLogic: 'unrar x -y {firstFile} {dir}',
      isBuiltin: true,
    ),
    Extractor(
      name: 'ZIP 分卷',
      type: ExtractorType.split,
      detectLogic: '匹配 *.zip.001 / *.z01 序列',
      extractLogic: 'zip -s- {firstFile} --out temp.zip && unzip temp.zip',
      isBuiltin: true,
    ),
  ];
}
