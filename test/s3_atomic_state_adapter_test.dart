import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quicklog/services/dual_write_s3_repair.dart';
import 'package:quicklog/services/preferences.dart';
import 'package:quicklog/services/s3_upload_receipts.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('ql-atomic-adapter-test');
  const first = 'ql-261001-090000.md';
  const second = 'ql-261001-090001.md';
  late Map<String, dynamic> document;
  late Map<String, Map<String, String>> receipts;
  late PreferencesService ui;
  late PreferencesService worker;
  var revision = 0;

  setUp(() {
    SharedPreferences.setMockInitialValues({'flutter.Directory': '/notes'});
    document = {'folders': <String, dynamic>{}};
    receipts = {};
    revision = 0;
    ui = PreferencesService(
      atomicStateChannel: channel,
      useAtomicS3State: true,
    );
    worker = PreferencesService(
      atomicStateChannel: channel,
      useAtomicS3State: true,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          final args = Map<String, dynamic>.from(call.arguments as Map);
          if (call.method == 'repairRead') return jsonEncode(document);
          if (call.method == 'receiptPrune') {
            final scope = args['scope'] as String;
            final ids = (args['localIds'] as List).cast<String>().toSet();
            receipts[scope]?.removeWhere((id, _) => !ids.contains(id));
            if (receipts[scope]?.isEmpty ?? false) receipts.remove(scope);
            await (await SharedPreferences.getInstance()).setString(
              'S3UploadReceipts',
              jsonEncode(receipts),
            );
            return null;
          }
          if (call.method == 'receiptConfirm') {
            (receipts[args['scope'] as String] ??= {})[args['id'] as String] =
                args['digest'] as String;
            await (await SharedPreferences.getInstance()).setString(
              'S3UploadReceipts',
              jsonEncode(receipts),
            );
            return null;
          }
          expect(call.method, 'repairMutate');
          final folder =
              (document['folders'] as Map).putIfAbsent(
                    args['folder'],
                    () => {
                      'uploads': <String>[],
                      'deletes': <String>[],
                      'revisions': <String, String>{},
                    },
                  )
                  as Map;
          final id = args['id'] as String;
          final revisions = folder['revisions'] as Map;
          // This fake exercises Dart callers against a shared native-like
          // state. The native algorithm has separate JVM tests.
          final changed =
              args['checkRevision'] != true ||
              args['expectedRevision'] == revisions[id];
          if (changed) {
            (folder['uploads'] as List).remove(id);
            (folder['deletes'] as List).remove(id);
            switch (args['operation']) {
              case 'upload':
                (folder['uploads'] as List).add(id);
                revisions[id] = '${++revision}';
              case 'delete':
                (folder['deletes'] as List).add(id);
                revisions[id] = '${++revision}';
              case 'clear':
                revisions.remove(id);
            }
          }
          return {'document': jsonEncode(document), 'changed': changed};
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'separate repair services merge and reject stale same-ID clears',
    () async {
      final uiRepairs = DualWriteS3Repair(preferences: ui);
      final workerRepairs = DualWriteS3Repair(preferences: worker);
      await uiRepairs.enqueueUpload(first);
      final captured = await worker.repairRevision('/notes', first);
      await workerRepairs.enqueueUpload(second);
      await uiRepairs.enqueueUpload(first);
      await workerRepairs.clear(
        first,
        folderKey: '/notes',
        expectedRevision: captured,
        checkRevision: true,
      );
      expect(await ui.dualWritePendingUploads(), [first, second]);
      final latest = await worker.repairRevision('/notes', first);
      await workerRepairs.clear(
        first,
        folderKey: '/notes',
        expectedRevision: latest,
        checkRevision: true,
      );
      expect(await ui.dualWritePendingUploads(), [second]);
      await uiRepairs.enqueueDelete(second);
      expect(await worker.dualWritePendingUploads(), isEmpty);
      expect(await worker.dualWritePendingDeletes(), [second]);
      expect(() => ui.setDualWritePendingFolders({}), throwsStateError);
    },
  );

  test(
    'separate receipt services confirm exact payload and refresh cache',
    () async {
      await S3UploadReceipts(
        preferences: ui,
      ).confirm('scope', first, 'old payload');
      await S3UploadReceipts(
        preferences: worker,
      ).confirm('scope', second, 'new');
      expect(await ui.s3UploadReceipts(), {
        'scope': {
          first: S3UploadReceipts.digest('old payload'),
          second: S3UploadReceipts.digest('new'),
        },
      });
    },
  );
  test(
    'native prune receives IDs and refreshes separate engine caches',
    () async {
      final uiReceipts = S3UploadReceipts(preferences: ui);
      final workerReceipts = S3UploadReceipts(preferences: worker);
      await uiReceipts.confirm('scope', first, 'kept');
      await workerReceipts.confirm('scope', second, 'gone');
      await uiReceipts.confirm('other', second, 'other');
      await workerReceipts.prune('scope', {first});
      expect(await worker.s3UploadReceipts(), {
        'scope': {first: S3UploadReceipts.digest('kept')},
        'other': {second: S3UploadReceipts.digest('other')},
      });
      await uiReceipts.confirm('scope', second, 'new');
      expect((await ui.s3UploadReceipts())['scope']!.keys, [first, second]);
      await uiReceipts.prune('scope', {});
      expect((await ui.s3UploadReceipts()).keys, ['other']);
    },
  );
}
