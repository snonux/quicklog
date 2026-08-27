import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quicklog/services/storage.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ql-writable-');
  });

  tearDown(() async {
    // Restore permissions first, or the recursive delete cannot descend.
    await Process.run('chmod', ['-R', 'u+rwx', tmp.path]);
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('an existing writable directory is writable', () async {
    expect(await canWriteToDirectory(tmp.path), isTrue);
  });

  test('leaves no probe file behind', () async {
    await canWriteToDirectory(tmp.path);
    expect(await tmp.list().isEmpty, isTrue);
  });

  test('a directory that does not exist yet is writable if it can be created',
      () async {
    // The Storage Scopes flow in docs/installation.md depends on this: the user
    // points Quicklog at a folder that does not exist so the app creates it.
    final fresh = p.join(tmp.path, 'Notes', 'Vault', 'Quicklog');
    expect(await canWriteToDirectory(fresh), isTrue);
  });

  test('checking a missing directory does not create it', () async {
    final fresh = p.join(tmp.path, 'not-yet');
    await canWriteToDirectory(fresh);
    expect(await Directory(fresh).exists(), isFalse);
    // ...and the parent it would have been created under is untouched too.
    expect(await tmp.list().isEmpty, isTrue);
  });

  test('a read-only directory is not writable', () async {
    final locked = await Directory(p.join(tmp.path, 'locked')).create();
    await Process.run('chmod', ['500', locked.path]);
    expect(await canWriteToDirectory(locked.path), isFalse);
  });

  test('a directory under a read-only parent is not writable', () async {
    final parent = await Directory(p.join(tmp.path, 'ro-parent')).create();
    await Process.run('chmod', ['500', parent.path]);
    expect(await canWriteToDirectory(p.join(parent.path, 'child')), isFalse);
  });

  test('an empty path is not writable', () async {
    expect(await canWriteToDirectory(''), isFalse);
    expect(await canWriteToDirectory('   '), isFalse);
  });
}
