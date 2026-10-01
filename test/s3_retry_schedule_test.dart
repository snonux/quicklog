import 'package:flutter_test/flutter_test.dart';
import 'package:quicklog/services/preferences.dart';
import 'package:quicklog/services/s3_retry_schedule.dart';
import 'package:quicklog/services/settings_backup.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('daily times normalize and wrap by calendar day', () {
    final schedule = S3RetrySchedule.parse([
      '23:59',
      '09:00',
      '09:00',
      '00:00',
    ]);
    expect(schedule.times, ['00:00', '09:00', '23:59']);
    expect(
      schedule.nextAfter(DateTime.utc(2026, 12, 31, 23, 59)),
      DateTime.utc(2027, 1, 1),
    );
    expect(
      schedule.nextAfter(DateTime.utc(2026, 10, 1, 8)),
      DateTime.utc(2026, 10, 1, 9),
    );
    expect(S3RetrySchedule([]).nextAfter(DateTime.now()), isNull);
  });

  test(
    'invalid daily times are rejected, damaged preferences disable schedule',
    () async {
      for (final time in ['9:00', '24:00', '09:60', 'bad']) {
        expect(() => S3RetrySchedule.parse([time]), throwsFormatException);
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('S3RetryTimes', ['bad']);
      expect((await PreferencesService().s3RetrySchedule()).enabled, isFalse);
    },
  );

  test(
    'schedule persists and settings round trip excludes receipt ledger',
    () async {
      final prefs = PreferencesService();
      await prefs.setS3RetrySchedule(S3RetrySchedule.parse(['20:15', '08:00']));
      await prefs.setS3UploadReceipts({
        'scope': {'id': 'digest'},
      });
      final service = SettingsBackupService(preferences: prefs);
      final json = await service.exportJson();
      expect(json, isNot(contains('digest')));
      final decoded = decodeSettingsBackup(json);
      expect(decoded.settings.s3RetryTimes, ['08:00', '20:15']);
      await prefs.setS3RetrySchedule(S3RetrySchedule([]));
      await service.apply(decoded.settings);
      expect((await prefs.s3RetrySchedule()).times, ['08:00', '20:15']);
    },
  );

  test(
    'older settings leave schedule unchanged, explicit empty clears it',
    () async {
      final prefs = PreferencesService();
      final service = SettingsBackupService(preferences: prefs);
      await prefs.setS3RetrySchedule(S3RetrySchedule.parse(['10:00']));
      await service.apply(const QuicklogSettings(autoLogSharedText: true));
      expect((await prefs.s3RetrySchedule()).times, ['10:00']);
      await service.apply(const QuicklogSettings(s3RetryTimes: []));
      expect((await prefs.s3RetrySchedule()).times, isEmpty);
    },
  );

  test(
    'background is off by default and backup preserves absent vs explicit false',
    () async {
      final prefs = PreferencesService();
      final backup = SettingsBackupService(preferences: prefs);
      expect(await prefs.s3RetryInBackground(), isFalse);
      await prefs.setS3RetryInBackground(true);
      final decoded = decodeSettingsBackup(await backup.exportJson());
      expect(decoded.settings.s3RetryInBackground, isTrue);
      await backup.apply(const QuicklogSettings(autoLogSharedText: true));
      expect(await prefs.s3RetryInBackground(), isTrue);
      await backup.apply(const QuicklogSettings(s3RetryInBackground: false));
      expect(await prefs.s3RetryInBackground(), isFalse);
      expect(
        () => QuicklogSettings.fromJson({'s3RetryInBackground': 'yes'}),
        throwsA(isA<SettingsImportException>()),
      );
    },
  );

  test('bad imported times reject the whole document', () {
    for (final value in [
      '10:00',
      ['24:00'],
      [123],
    ]) {
      expect(
        () => QuicklogSettings.fromJson({'s3RetryTimes': value}),
        throwsA(isA<SettingsImportException>()),
      );
    }
  });
}
