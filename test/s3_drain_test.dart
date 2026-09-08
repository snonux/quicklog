import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quicklog/services/s3_drain.dart';
import 'package:quicklog/services/s3_object_client.dart';

void main() {
  late Directory dest;
  late MemoryS3ObjectClient client;

  setUp(() async {
    dest = await Directory.systemTemp.createTemp('ql-drain-');
    client = MemoryS3ObjectClient();
  });

  tearDown(() async {
    if (await dest.exists()) await dest.delete(recursive: true);
  });

  test('fetch then delete remote; leaves local file', () async {
    await client.putText('ql-260908-100000.md', 'hello drain');
    final summary = await drainQuicklogObjects(client: client, destDir: dest);
    expect(summary.fetched, 1);
    expect(summary.deleted, 1);
    expect(summary.failed, 0);
    expect(client.objects.containsKey('ql-260908-100000.md'), isFalse);
    final file = File(p.join(dest.path, 'ql-260908-100000.md'));
    expect(await file.readAsString(), 'hello drain');
  });

  test('does not delete remote when local write fails', () async {
    const id = 'ql-260908-100001.md';
    await client.putText(id, 'keep remote');
    // Occupy the target path with a directory so the atomic rename fails.
    await Directory(p.join(dest.path, id)).create();

    final summary = await drainQuicklogObjects(client: client, destDir: dest);
    expect(summary.failed, 1);
    expect(summary.deleted, 0);
    expect(client.objects.containsKey(id), isTrue);
  });

  test('skips existing local file unless --force', () async {
    await client.putText('ql-260908-100002.md', 'remote');
    final local = File(p.join(dest.path, 'ql-260908-100002.md'));
    await local.writeAsString('local already');

    final skipped = await drainQuicklogObjects(client: client, destDir: dest);
    expect(skipped.skipped, 1);
    expect(skipped.fetched, 0);
    expect(client.objects.containsKey('ql-260908-100002.md'), isTrue);
    expect(await local.readAsString(), 'local already');

    final forced = await drainQuicklogObjects(
      client: client,
      destDir: dest,
      force: true,
    );
    expect(forced.fetched, 1);
    expect(forced.deleted, 1);
    expect(await local.readAsString(), 'remote');
  });

  test('dry-run does not write or delete', () async {
    await client.putText('ql-260908-100003.md', 'dry');
    final summary = await drainQuicklogObjects(
      client: client,
      destDir: dest,
      dryRun: true,
    );
    expect(summary.fetched, 1);
    expect(summary.deleted, 1);
    expect(client.objects.containsKey('ql-260908-100003.md'), isTrue);
    expect(await File(p.join(dest.path, 'ql-260908-100003.md')).exists(), isFalse);
  });

  test('limit caps how many objects are drained', () async {
    await client.putText('ql-260908-100010.md', 'a');
    await client.putText('ql-260908-100011.md', 'b');
    final summary = await drainQuicklogObjects(
      client: client,
      destDir: dest,
      limit: 1,
    );
    expect(summary.fetched, 1);
    expect(client.objects.length, 1);
  });

  test('ignores non ql-*.md keys', () async {
    await client.putText('readme.txt', 'nope');
    final summary = await drainQuicklogObjects(client: client, destDir: dest);
    expect(summary.fetched, 0);
    expect(client.objects.containsKey('readme.txt'), isTrue);
  });
}
