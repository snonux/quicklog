import 'package:flutter_test/flutter_test.dart';
import 'package:quicklog/services/s3_config.dart';
import 'package:quicklog/services/s3_object_client.dart';

import '../bin/quicklog_drain.dart' as drain;

void main() {
  group('S3Config.fromRaw', () {
    test('absent fields fall back to the defaults, credentials to empty', () {
      final config = S3Config.fromRaw();
      expect(config.endpoint, kDefaultS3Endpoint);
      expect(config.region, kDefaultS3Region);
      expect(config.bucket, kDefaultS3Bucket);
      expect(config.accessKeyId, '');
      expect(config.secretAccessKey, '');
      expect(config.hasCredentials, isFalse);
    });

    test('blank fields fall back to the defaults', () {
      final config = S3Config.fromRaw(endpoint: '', region: '  ', bucket: '\t');
      expect(config.endpoint, kDefaultS3Endpoint);
      expect(config.region, kDefaultS3Region);
      expect(config.bucket, kDefaultS3Bucket);
    });

    test('endpoint, region and bucket are trimmed', () {
      final config = S3Config.fromRaw(
        endpoint: '  http://s3.example:9000 ',
        region: ' eu-1 ',
        bucket: ' notes ',
      );
      expect(config.endpoint, 'http://s3.example:9000');
      expect(config.region, 'eu-1');
      expect(config.bucket, 'notes');
    });

    test('the endpoint keeps its form; host/port/useSSL add https', () {
      final config = S3Config.fromRaw(endpoint: ' s3.example ');
      expect(config.endpoint, 's3.example');
      expect(config.host, 's3.example');
      expect(config.port, 443);
      expect(config.useSSL, isTrue);
    });

    test('credentials are kept verbatim, never trimmed', () {
      final config = S3Config.fromRaw(
        accessKeyId: ' AKIA ',
        secretAccessKey: ' sekrit ',
      );
      expect(config.accessKeyId, ' AKIA ');
      expect(config.secretAccessKey, ' sekrit ');
      expect(config.hasCredentials, isTrue);
    });
  });

  group('S3Config.normalized', () {
    test('applies the fromRaw defaulting to a raw config', () {
      const raw = S3Config(
        endpoint: ' ',
        region: ' garage2 ',
        bucket: '  ',
        accessKeyId: ' a ',
        secretAccessKey: ' s ',
      );
      final config = raw.normalized();
      expect(config.endpoint, kDefaultS3Endpoint);
      expect(config.region, 'garage2');
      expect(config.bucket, kDefaultS3Bucket);
      expect(config.accessKeyId, ' a ');
      expect(config.secretAccessKey, ' s ');
    });

    test('is idempotent, credentials included', () {
      final once = S3Config.fromRaw(
        endpoint: ' x.example ',
        region: '  ',
        bucket: ' b1 ',
        accessKeyId: ' AKIA ',
        secretAccessKey: '',
      );
      final twice = once.normalized();
      expect(twice.endpoint, once.endpoint);
      expect(twice.region, once.region);
      expect(twice.bucket, once.bucket);
      expect(twice.accessKeyId, ' AKIA ');
      expect(twice.secretAccessKey, '');
      final thrice = twice.normalized();
      expect(thrice.accessKeyId, twice.accessKeyId);
      expect(thrice.secretAccessKey, twice.secretAccessKey);
    });
  });

  group('MinioS3ObjectClient.settingsError', () {
    S3Config raw({
      String endpoint = kDefaultS3Endpoint,
      String bucket = 'notes',
    }) => S3Config(
      endpoint: endpoint,
      region: kDefaultS3Region,
      bucket: bucket,
      accessKeyId: 'a',
      secretAccessKey: 's',
    );

    test('valid settings pass', () {
      expect(MinioS3ObjectClient.settingsError(raw()), isNull);
      expect(MinioS3ObjectClient.settingsError(S3Config.fromRaw()), isNull);
    });

    test('blank or padded fields are judged as they will be read back', () {
      expect(
        MinioS3ObjectClient.settingsError(raw(endpoint: ' ', bucket: '  ')),
        isNull,
      );
      expect(MinioS3ObjectClient.settingsError(raw(bucket: ' notes ')), isNull);
    });

    test('an invalid endpoint is reported without a type prefix', () {
      final error = MinioS3ObjectClient.settingsError(raw(endpoint: 'http://'));
      expect(error, isNotNull);
      expect(error, isNot(startsWith('FormatException')));
    });

    test('an invalid host is reported via Minio', () {
      final error = MinioS3ObjectClient.settingsError(
        raw(endpoint: 'https://_bad.example'),
      );
      expect(error, contains('_bad.example'));
      expect(error, isNot(startsWith('MinioError')));
    });

    test('an invalid bucket name is reported', () {
      expect(
        MinioS3ObjectClient.settingsError(raw(bucket: ' Bad_B ')),
        'Invalid bucket name: Bad_B',
      );
    });

    test('matches configError on the normalized config', () {
      for (final config in [
        raw(),
        raw(endpoint: 'http://'),
        raw(bucket: 'Bad_B'),
        raw(endpoint: 'https://_bad.example'),
      ]) {
        expect(
          MinioS3ObjectClient.settingsError(config),
          MinioS3ObjectClient.configError(config.normalized()),
        );
      }
    });

    test('nothing is checked when S3 is not in use', () {
      expect(
        MinioS3ObjectClient.settingsError(
          raw(endpoint: 'http://', bucket: 'Bad_B'),
          usesS3: false,
        ),
        isNull,
      );
    });
  });

  group('quicklog_drain configFromEnv', () {
    test('unset, empty and whitespace region/bucket use the defaults', () {
      for (final value in <String?>[null, '', '   ']) {
        final config = drain.configFromEnv({
          'GARAGE_REGION': ?value,
          'GARAGE_BUCKET': ?value,
        });
        expect(config.region, kDefaultS3Region, reason: '$value');
        expect(config.bucket, kDefaultS3Bucket, reason: '$value');
        expect(config.endpoint, kDefaultS3Endpoint, reason: '$value');
      }
    });

    test('trims endpoint, region and bucket', () {
      final config = drain.configFromEnv({
        'GARAGE_ENDPOINT': ' http://s3.example:9000 ',
        'GARAGE_REGION': ' eu-1 ',
        'GARAGE_BUCKET': ' notes ',
      });
      expect(config.endpoint, 'http://s3.example:9000');
      expect(config.region, 'eu-1');
      expect(config.bucket, 'notes');
    });

    test('keeps credentials as given; unset means empty', () {
      final config = drain.configFromEnv({
        'GARAGE_ACCESS_KEY_ID': ' AKIA ',
        'GARAGE_SECRET_ACCESS_KEY': ' sekrit ',
      });
      expect(config.accessKeyId, ' AKIA ');
      expect(config.secretAccessKey, ' sekrit ');
      final none = drain.configFromEnv({});
      expect(none.accessKeyId, '');
      expect(none.secretAccessKey, '');
    });
  });
}
