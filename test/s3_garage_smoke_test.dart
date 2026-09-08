import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:quicklog/services/s3_config.dart';
import 'package:quicklog/services/s3_note_store.dart';
import 'package:quicklog/services/s3_object_client.dart';

/// Optional live Garage smoke. Skipped unless ~/.config/garage/quicklog.env
/// exists — CI and developer machines without credentials stay green.
void main() {
  final envFile = File(
    '${Platform.environment['HOME']}/.config/garage/quicklog.env',
  );
  final hasEnv = envFile.existsSync();

  test(
    'live Garage path-style create/list/delete smoke',
    () async {
      final env = _loadShEnv(await envFile.readAsString());
      final config = S3Config(
        endpoint: env['GARAGE_ENDPOINT'] ?? kDefaultS3Endpoint,
        region: env['GARAGE_REGION'] ?? kDefaultS3Region,
        bucket: env['GARAGE_BUCKET'] ?? kDefaultS3Bucket,
        accessKeyId: env['GARAGE_ACCESS_KEY_ID'] ?? '',
        secretAccessKey: env['GARAGE_SECRET_ACCESS_KEY'] ?? '',
      );
      expect(config.hasCredentials, isTrue);

      final store = S3NoteStore(MinioS3ObjectClient(config));
      final stamp = DateTime.now();
      final entry = await store.create(
        'quicklog smoke ${stamp.toIso8601String()}',
        now: stamp,
      );
      final listed = await store.list();
      expect(listed.any((e) => e.id == entry.id), isTrue);
      expect(await store.read(entry.id), contains('quicklog smoke'));
      await store.delete(entry.id);
    },
    skip: hasEnv
        ? false
        : '~/.config/garage/quicklog.env not present; skipping live smoke',
  );
}

/// Parse a shell-style env file that uses `: "\${VAR:=value}"` / export lines.
Map<String, String> _loadShEnv(String contents) {
  final out = <String, String>{};
  final assign = RegExp(
    r'''^\s*(?:export\s+)?([A-Z0-9_]+)=(?:"([^"]*)"|'([^']*)'|(\S+))\s*$''',
  );
  final defaultAssign = RegExp(
    r''':\s*"\$\{([A-Z0-9_]+):=([^}]*)\}"''',
  );
  for (final raw in contents.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final d = defaultAssign.firstMatch(line);
    if (d != null) {
      out.putIfAbsent(d.group(1)!, () => d.group(2)!);
      continue;
    }
    final m = assign.firstMatch(line);
    if (m != null) {
      out[m.group(1)!] = m.group(2) ?? m.group(3) ?? m.group(4) ?? '';
    }
  }
  return out;
}
