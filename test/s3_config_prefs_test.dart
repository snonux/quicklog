import 'package:flutter_test/flutter_test.dart';
import 'package:quicklog/services/preferences.dart';
import 'package:quicklog/services/s3_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('s3Config defaults and round-trip', () async {
    final prefs = PreferencesService();
    final initial = await prefs.s3Config();
    expect(initial.endpoint, kDefaultS3Endpoint);
    expect(initial.region, kDefaultS3Region);
    expect(initial.bucket, kDefaultS3Bucket);
    expect(initial.hasCredentials, isFalse);

    await prefs.setS3Config(
      const S3Config(
        endpoint: 'https://example.invalid',
        region: 'garage',
        bucket: 'quicklog',
        accessKeyId: 'AKIA',
        secretAccessKey: 'sekrit',
      ),
    );
    final loaded = await prefs.s3Config();
    expect(loaded.endpoint, 'https://example.invalid');
    expect(loaded.accessKeyId, 'AKIA');
    expect(loaded.secretAccessKey, 'sekrit');
    expect(loaded.hasCredentials, isTrue);
    expect(loaded.host, 'example.invalid');
    expect(loaded.useSSL, isTrue);
  });
}
