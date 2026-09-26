import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:quicklog/services/preferences.dart';
import 'package:quicklog/services/s3_config.dart';
import 'package:quicklog/services/s3_session_controller.dart';
import 'package:quicklog/services/settings_backup.dart';
import 'package:quicklog/services/storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Every setting with a value that differs from its default.
const QuicklogSettings nonDefaults = QuicklogSettings(
  directory: '/storage/emulated/0/Notes/Vault/Quicklog',
  autoLogSharedText: true,
  storageMode: StorageMode.both,
  s3Endpoint: 'http://minio.example.invalid:9000',
  s3Region: 'eu-central-1',
  s3Bucket: 'my-notes',
  s3AccessKeyId: 'AKIA_EXPORT_TEST',
  s3SecretAccessKey: 's3cr3t/with+special=chars "quoted" ünïcode',
);

/// SharedPreferences keys (as stored, with the plugin's `flutter.` prefix)
/// for [nonDefaults]. Written out by hand so a renamed key fails a test.
const Map<String, Object> nonDefaultStorage = {
  'flutter.Directory': '/storage/emulated/0/Notes/Vault/Quicklog',
  'flutter.AutoLogSharedText': true,
  'flutter.StorageMode': 'both',
  'flutter.S3Endpoint': 'http://minio.example.invalid:9000',
  'flutter.S3Region': 'eu-central-1',
  'flutter.S3Bucket': 'my-notes',
  'flutter.S3AccessKeyId': 'AKIA_EXPORT_TEST',
  'flutter.S3SecretAccessKey': 's3cr3t/with+special=chars "quoted" ünïcode',
};

void expectSameSettings(QuicklogSettings actual, QuicklogSettings expected) {
  expect(actual.directory, expected.directory);
  expect(actual.autoLogSharedText, expected.autoLogSharedText);
  expect(actual.storageMode, expected.storageMode);
  expect(actual.s3Endpoint, expected.s3Endpoint);
  expect(actual.s3Region, expected.s3Region);
  expect(actual.s3Bucket, expected.s3Bucket);
  expect(actual.s3AccessKeyId, expected.s3AccessKeyId);
  expect(actual.s3SecretAccessKey, expected.s3SecretAccessKey);
}

Map<String, Object?> validDoc() =>
    jsonDecode(
          encodeSettingsBackup(nonDefaults, exportedAt: DateTime.utc(2026)),
        )
        as Map<String, Object?>;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('encode / decode', () {
    test('round-trips every setting with non-default values', () {
      final text = encodeSettingsBackup(
        nonDefaults,
        exportedAt: DateTime.utc(2026, 9, 26, 12, 30),
      );
      final backup = decodeSettingsBackup(text);
      expectSameSettings(backup.settings, nonDefaults);
      expect(backup.formatVersion, kSettingsFormatVersion);
      expect(backup.exportedAt, DateTime.utc(2026, 9, 26, 12, 30));
    });

    test('round-trips each storage mode and both auto-log values', () {
      for (final mode in StorageMode.values) {
        for (final autoLog in [true, false]) {
          final s = QuicklogSettings(
            storageMode: mode,
            autoLogSharedText: autoLog,
          );
          final back = decodeSettingsBackup(
            encodeSettingsBackup(s, exportedAt: DateTime.utc(2026)),
          ).settings;
          expect(back.storageMode, mode);
          expect(back.autoLogSharedText, autoLog);
        }
      }
    });

    test('writes a versioned header with the app id and a secrets flag', () {
      final doc = validDoc();
      expect(doc['app'], 'org.buetow.quicklog');
      expect(doc['format'], 'quicklog-settings');
      expect(doc['formatVersion'], 1);
      expect(doc['containsSecrets'], isTrue);
      expect(doc['exportedAt'], '2026-01-01T00:00:00.000Z');
      final settings = doc['settings'] as Map<String, Object?>;
      expect(settings['storageMode'], 'both');
      expect((settings['s3'] as Map)['secretAccessKey'], contains('s3cr3t'));
    });

    test('containsSecrets is false without credentials', () {
      const s = QuicklogSettings(s3AccessKeyId: '', s3SecretAccessKey: '');
      expect(s.containsSecrets, isFalse);
      final doc = jsonDecode(
        encodeSettingsBackup(s, exportedAt: DateTime(2026)),
      );
      expect((doc as Map)['containsSecrets'], isFalse);
    });

    test(
      'ignores unknown top-level, settings and s3 keys (forward compat)',
      () {
        final doc = validDoc();
        doc['addedInFuture'] = {'x': 1};
        final settings = doc['settings'] as Map<String, Object?>;
        settings['themeMode'] = 'dark';
        settings['someList'] = [1, 2, 3];
        (settings['s3'] as Map<String, Object?>)['sessionToken'] = 'tok';
        final backup = decodeSettingsBackup(jsonEncode(doc));
        expectSameSettings(backup.settings, nonDefaults);
      },
    );

    test('accepts an older format version', () {
      // Version 1 is the oldest; this guards the >= 1 bound, not a migration.
      final doc = validDoc()..['formatVersion'] = 1;
      expect(decodeSettingsBackup(jsonEncode(doc)).formatVersion, 1);
    });

    test('missing keys come back as null (left unchanged on import)', () {
      final doc = validDoc()..['settings'] = {'autoLogSharedText': true};
      final s = decodeSettingsBackup(jsonEncode(doc)).settings;
      expect(s.autoLogSharedText, isTrue);
      expect(s.directory, isNull);
      expect(s.storageMode, isNull);
      expect(s.s3Endpoint, isNull);
      expect(s.s3SecretAccessKey, isNull);
    });
  });

  group('validation', () {
    void expectRejected(String text, Matcher message) {
      expect(
        () => decodeSettingsBackup(text),
        throwsA(
          isA<SettingsImportException>().having(
            (e) => e.message,
            'message',
            message,
          ),
        ),
      );
    }

    test('rejects text that is not JSON', () {
      expectRejected('not json {', contains('not valid JSON'));
      expectRejected('', contains('not valid JSON'));
    });

    test('rejects JSON that is not an object', () {
      expectRejected('[1, 2]', contains('expected a JSON object'));
      expectRejected('"hello"', contains('expected a JSON object'));
    });

    test('rejects a file from another app', () {
      final doc = validDoc()..['app'] = 'org.buetow.gitsyncer';
      expectRejected(
        jsonEncode(doc),
        allOf(contains('org.buetow.gitsyncer'), contains('not Quicklog')),
      );
    });

    test('rejects a file with no app id', () {
      final doc = validDoc()..remove('app');
      expectRejected(jsonEncode(doc), contains('no app id'));
    });

    test('rejects an unknown format', () {
      final doc = validDoc()..['format'] = 'quicklog-notes';
      expectRejected(jsonEncode(doc), contains('unknown format'));
    });

    test('rejects a newer format version with an update hint', () {
      final doc = validDoc()..['formatVersion'] = kSettingsFormatVersion + 1;
      expectRejected(
        jsonEncode(doc),
        allOf(
          contains('version ${kSettingsFormatVersion + 1}'),
          contains('Update Quicklog'),
        ),
      );
    });

    test('rejects a missing or malformed format version', () {
      for (final bad in [null, '1', 0, -3, 1.5]) {
        final doc = validDoc()..['formatVersion'] = bad;
        expectRejected(jsonEncode(doc), contains('format version'));
      }
    });

    test('rejects a missing settings object', () {
      final doc = validDoc()..remove('settings');
      expectRejected(jsonEncode(doc), contains('no "settings" object'));
      doc['settings'] = 'nope';
      expectRejected(jsonEncode(doc), contains('no "settings" object'));
    });

    test('rejects known keys with the wrong type', () {
      Map<String, Object?> withSetting(String key, Object? value) {
        final doc = validDoc();
        (doc['settings'] as Map<String, Object?>)[key] = value;
        return doc;
      }

      expectRejected(
        jsonEncode(withSetting('autoLogSharedText', 'yes')),
        contains('"autoLogSharedText" must be true or false'),
      );
      expectRejected(
        jsonEncode(withSetting('directory', 42)),
        contains('"directory" must be text'),
      );
      expectRejected(
        jsonEncode(withSetting('storageMode', 'cloud')),
        contains('unknown storage mode "cloud"'),
      );
      expectRejected(
        jsonEncode(withSetting('s3', 'x')),
        contains('"s3" must be an object'),
      );
      expectRejected(
        jsonEncode(withSetting('s3', {'secretAccessKey': 7})),
        contains('"s3.secretAccessKey" must be text'),
      );
    });
  });

  group('SettingsBackupService', () {
    late S3SessionController session;

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      session = S3SessionController();
      await session.load();
    });

    tearDown(() => session.dispose());

    SettingsBackupService service() => SettingsBackupService(
      session: session,
      clock: () => DateTime.utc(2026),
    );

    test('collect reads every stored key', () async {
      SharedPreferences.setMockInitialValues(nonDefaultStorage);
      expectSameSettings(await service().collect(), nonDefaults);
    });

    test('collect on a fresh install reports defaults', () async {
      final s = await service().collect();
      expect(s.directory, '', reason: 'default directory stays "default"');
      expect(s.autoLogSharedText, isFalse);
      expect(s.storageMode, StorageMode.local);
      expect(s.s3Endpoint, kDefaultS3Endpoint);
      expect(s.s3Region, kDefaultS3Region);
      expect(s.s3Bucket, kDefaultS3Bucket);
      expect(s.s3AccessKeyId, '');
      expect(s.s3SecretAccessKey, '');
      expect(s.containsSecrets, isFalse);
    });

    test('export, wipe, import restores every stored key exactly', () async {
      SharedPreferences.setMockInitialValues(nonDefaultStorage);
      final exported = await service().exportJson();

      // Uninstall: storage gone, fresh process state.
      SharedPreferences.setMockInitialValues(<String, Object>{});
      session.dispose();
      session = S3SessionController();
      await session.load();
      expect(session.preferredMode, StorageMode.local);

      await service().importJson(exported);

      final prefs = await SharedPreferences.getInstance();
      for (final entry in nonDefaultStorage.entries) {
        final key = entry.key.substring('flutter.'.length);
        expect(prefs.get(key), entry.value, reason: key);
      }
      // The running session switched immediately, not only on next start.
      expect(session.preferredMode, StorageMode.both);
      final p = PreferencesService();
      expect(await p.directory(), nonDefaults.directory);
      expect((await p.s3Config()).hasCredentials, isTrue);
    });

    test(
      'a stored path equal to the platform default exports as default',
      () async {
        // Save in Preferences stores the resolved default path verbatim.
        SharedPreferences.setMockInitialValues({
          'flutter.Directory': await defaultLogDirectory(),
        });
        expect((await service().collect()).directory, '');
      },
    );

    test('importing a default directory clears a custom one', () async {
      SharedPreferences.setMockInitialValues({'flutter.Directory': '/custom'});
      final doc = validDoc();
      (doc['settings'] as Map<String, Object?>)['directory'] = '';
      await service().importJson(jsonEncode(doc));
      expect(await PreferencesService().storedDirectory(), isNull);
    });

    test('keys absent from the file keep their current values', () async {
      SharedPreferences.setMockInitialValues(nonDefaultStorage);
      final doc = validDoc()
        ..['settings'] = {
          'autoLogSharedText': false,
          's3': {'bucket': 'other-bucket'},
        };
      await service().importJson(jsonEncode(doc));
      final after = await service().collect();
      expect(after.autoLogSharedText, isFalse);
      expect(after.s3Bucket, 'other-bucket');
      expect(after.directory, nonDefaults.directory);
      expect(after.s3SecretAccessKey, nonDefaults.s3SecretAccessKey);
      expect(after.s3Endpoint, nonDefaults.s3Endpoint);
    });

    test('an invalid file changes nothing', () async {
      SharedPreferences.setMockInitialValues(nonDefaultStorage);
      final doc = validDoc();
      final settings = doc['settings'] as Map<String, Object?>;
      settings['directory'] = '/elsewhere';
      settings['storageMode'] = 'bogus';
      await expectLater(
        service().importJson(jsonEncode(doc)),
        throwsA(isA<SettingsImportException>()),
      );
      expectSameSettings(await service().collect(), nonDefaults);
    });
  });
}
