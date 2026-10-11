import 'package:flutter_test/flutter_test.dart';
import 'package:quicklog/services/preferences.dart';
import 'package:quicklog/services/s3_config.dart';
import 'package:quicklog/services/s3_note_store.dart';
import 'package:quicklog/services/s3_upload_receipts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/memory_s3_object_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PreferencesService prefs;
  late S3UploadReceipts receipts;
  late MemoryS3ObjectClient device;
  late S3NoteStore local;
  final config = S3Config.fromRaw(
    accessKeyId: 'access',
    secretAccessKey: 'secret',
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    prefs = PreferencesService();
    receipts = S3UploadReceipts(preferences: prefs);
    device = MemoryS3ObjectClient();
    local = S3NoteStore(device);
  });

  test(
    'confirmed unchanged local snapshot stays acknowledged after remote drain',
    () async {
      final entry = await local.create('note', now: DateTime(2026, 10, 1));
      final scope = S3UploadReceipts.scope(config, '/local');
      expect(
        await receipts.pending(scope: scope, local: local, entries: [entry]),
        [entry],
      );
      await receipts.confirm(scope, entry.id, 'note');
      // Fresh service/process must also remember, with no remote calls needed.
      receipts = S3UploadReceipts(preferences: prefs);
      expect(
        await receipts.pending(scope: scope, local: local, entries: [entry]),
        isEmpty,
      );
      await local.update(entry.id, 'edited');
      expect(
        await receipts.pending(scope: scope, local: local, entries: [entry]),
        [entry],
      );
    },
  );

  test(
    'confirmation of an older uploaded snapshot never acknowledges newer edit',
    () async {
      final entry = await local.create('edited', now: DateTime(2026, 10, 1));
      await receipts.confirm('scope', entry.id, 'previous');
      expect(
        await receipts.pending(scope: 'scope', local: local, entries: [entry]),
        [entry],
      );
    },
  );

  test(
    'bucket, directory and access identity have independent receipts',
    () async {
      final entry = await local.create('note', now: DateTime(2026, 10, 1));
      final scope = S3UploadReceipts.scope(config, '/local');
      await receipts.confirm(scope, entry.id, 'note');
      for (final nextScope in [
        S3UploadReceipts.scope(config, '/other'),
        S3UploadReceipts.scope(
          S3Config.fromRaw(bucket: 'other', accessKeyId: 'access'),
          '/local',
        ),
        S3UploadReceipts.scope(
          S3Config.fromRaw(accessKeyId: 'other'),
          '/local',
        ),
      ]) {
        expect(nextScope, isNot(scope));
        expect(
          await receipts.pending(
            scope: nextScope,
            local: local,
            entries: [entry],
          ),
          [entry],
        );
      }
      final serialized = (await SharedPreferences.getInstance()).getString(
        'S3UploadReceipts',
      )!;
      expect(serialized, isNot(contains('access')));
      expect(serialized, isNot(contains('/local')));
      expect(serialized, isNot(contains('secret')));
    },
  );

  test('overlapping confirmations preserve both entries', () async {
    await Future.wait([
      receipts.confirm('scope', 'first', 'one'),
      S3UploadReceipts(preferences: prefs).confirm('scope', 'second', 'two'),
    ]);
    expect(
      (await prefs.s3UploadReceipts())['scope']!.keys,
      containsAll(['first', 'second']),
    );
  });

  test(
    'pruning retains live digests and other scopes, removing empty scopes',
    () async {
      await receipts.confirm('scope', 'kept', 'note');
      await receipts.confirm('scope', 'gone', 'old');
      await receipts.confirm('other', 'gone', 'other note');
      await receipts.prune('scope', {'kept'});
      expect(await prefs.s3UploadReceipts(), {
        'scope': {'kept': S3UploadReceipts.digest('note')},
        'other': {'gone': S3UploadReceipts.digest('other note')},
      });
      await receipts.prune('scope', {});
      await receipts.prune('missing', {});
      expect((await prefs.s3UploadReceipts()).keys, ['other']);
    },
  );

  test('pruning and confirmations serialize across receipt services', () async {
    await receipts.confirm('scope', 'gone', 'old');
    await Future.wait([
      receipts.prune('scope', {}),
      S3UploadReceipts(preferences: prefs).confirm('scope', 'new', 'note'),
      receipts.confirm('other', 'other', 'other note'),
    ]);
    expect(await prefs.s3UploadReceipts(), {
      'scope': {'new': S3UploadReceipts.digest('note')},
      'other': {'other': S3UploadReceipts.digest('other note')},
    });
  });

  test(
    'pruning corrupt receipts preserves the ledger and later writes recover',
    () async {
      final shared = await SharedPreferences.getInstance();
      await shared.setString('S3UploadReceipts', '{damaged');
      await expectLater(receipts.prune('scope', {}), throwsFormatException);
      expect(shared.getString('S3UploadReceipts'), '{damaged');
      await shared.setString('S3UploadReceipts', '{}');
      await receipts.confirm('scope', 'id', 'note');
      expect(
        (await prefs.s3UploadReceipts())['scope']!['id'],
        S3UploadReceipts.digest('note'),
      );
    },
  );

  test('corrupt receipts do not overwrite themselves', () async {
    final shared = await SharedPreferences.getInstance();
    await shared.setString('S3UploadReceipts', '{damaged');
    expect(receipts.confirm('scope', 'id', 'text'), throwsFormatException);
    expect(shared.getString('S3UploadReceipts'), '{damaged');
  });
}
