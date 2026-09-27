import 'package:flutter_test/flutter_test.dart';

import '../bin/quicklog_drain.dart' as drain;

/// Unit tests for the CLI argument parser of bin/quicklog_drain.dart.
///
/// The parser is public (parseDrainArgs) so this file can import it directly
/// from bin/ — the rest of the bin wiring (S3 client, stdin/stdout protocol)
/// is covered end-to-end by the dotfiles scripts/quicklog-drain-e2e harness.
void main() {
  group('mode selection', () {
    test('defaults to nothing without a mode (usage error)', () {
      expect(drain.parseDrainArgs([]), isNull);
    });

    test('parses each single mode', () {
      expect(drain.parseDrainArgs(['--import'])!.mode, drain.DrainMode.import);
      expect(drain.parseDrainArgs(['--keys'])!.mode, drain.DrainMode.keys);
      expect(
        drain.parseDrainArgs(['--dest', '/tmp/x'])!.mode,
        drain.DrainMode.dest,
      );
      expect(
        drain.parseDrainArgs(['--delete', 'ql-1.md'])!.mode,
        drain.DrainMode.delete,
      );
    });

    test('rejects two modes in one invocation', () {
      expect(drain.parseDrainArgs(['--import', '--keys']), isNull);
      expect(drain.parseDrainArgs(['--dest', '/tmp/x', '--import']), isNull);
    });

    test('--dest requires a directory argument', () {
      expect(drain.parseDrainArgs(['--dest']), isNull);
    });

    test('help is a usage error path', () {
      expect(drain.parseDrainArgs(['-h']), isNull);
      expect(drain.parseDrainArgs(['--help']), isNull);
    });

    test('unknown arguments are usage errors', () {
      expect(drain.parseDrainArgs(['--import', '--bogus']), isNull);
      expect(drain.parseDrainArgs(['--import', 'stray']), isNull);
    });
  });

  group('--limit', () {
    test('accepts positive integers', () {
      expect(drain.parseDrainArgs(['--import', '--limit', '2'])!.limit, 2);
      expect(drain.parseDrainArgs(['--keys', '--limit', '10'])!.limit, 10);
    });

    test('rejects 0 (would silently process nothing)', () {
      expect(drain.parseDrainArgs(['--import', '--limit', '0']), isNull);
    });

    test('rejects negative and non-numeric values', () {
      expect(drain.parseDrainArgs(['--import', '--limit', '-1']), isNull);
      expect(drain.parseDrainArgs(['--import', '--limit', 'abc']), isNull);
      expect(drain.parseDrainArgs(['--import', '--limit']), isNull);
    });
  });

  group('--delete key consumption', () {
    test('consumes all following plain keys', () {
      final opts = drain.parseDrainArgs(['--delete', 'ql-1.md', 'ql-2.md']);
      expect(opts, isNotNull);
      expect(opts!.keys, ['ql-1.md', 'ql-2.md']);
    });

    test('stops at the next option and turns it into a usage error', () {
      // Regression: this used to swallow `--limit` and `2` as keys.
      expect(
        drain.parseDrainArgs(['--delete', 'ql-1.md', '--limit', '2']),
        isNull,
      );
      expect(drain.parseDrainArgs(['--delete', '--import']), isNull);
    });

    test('requires at least one key', () {
      expect(drain.parseDrainArgs(['--delete']), isNull);
    });
  });

  group('--only', () {
    test('parses comma-separated keys for import and dest', () {
      expect(
        drain.parseDrainArgs(['--import', '--only', 'ql-1.md,ql-2.md'])!
            .onlyKeys,
        ['ql-1.md', 'ql-2.md'],
      );
      expect(
        drain
            .parseDrainArgs(['--dest', '/tmp/x', '--only', 'ql-1.md'])!
            .onlyKeys,
        ['ql-1.md'],
      );
    });

    test('rejects empty or blank key parts', () {
      expect(drain.parseDrainArgs(['--import', '--only', '']), isNull);
      expect(drain.parseDrainArgs(['--import', '--only', 'a,,b']), isNull);
      expect(drain.parseDrainArgs(['--import', '--only']), isNull);
    });

    test('trims whitespace around key parts and rejects blank-after-trim parts', () {
      // Regression: " b" used to be kept verbatim and silently matched nothing.
      expect(
        drain.parseDrainArgs(['--import', '--only', ' ql-1.md , ql-2.md '])!
            .onlyKeys,
        ['ql-1.md', 'ql-2.md'],
      );
      expect(
        drain.parseDrainArgs(['--import', '--only', 'a,\tb'])!.onlyKeys,
        ['a', 'b'],
      );
      expect(drain.parseDrainArgs(['--import', '--only', 'a, ,b']), isNull);
      expect(drain.parseDrainArgs(['--import', '--only', 'a,\t,b']), isNull);
    });

    test('rejected for the read-only keys mode and for delete', () {
      expect(drain.parseDrainArgs(['--keys', '--only', 'ql-1.md']), isNull);
      expect(
        drain.parseDrainArgs(['--delete', 'ql-1.md', '--only', 'ql-1.md']),
        isNull,
      );
    });
  });

  group('flag/mode combinations', () {
    test('--force only valid with --dest', () {
      expect(drain.parseDrainArgs(['--dest', '/tmp/x', '--force']), isNotNull);
      expect(drain.parseDrainArgs(['--import', '--force']), isNull);
    });

    test('--dry-run valid with import and dest only', () {
      expect(drain.parseDrainArgs(['--import', '--dry-run']), isNotNull);
      expect(
        drain.parseDrainArgs(['--dest', '/tmp/x', '--dry-run']),
        isNotNull,
      );
      expect(drain.parseDrainArgs(['--keys', '--dry-run']), isNull);
      expect(
        drain.parseDrainArgs(['--delete', 'ql-1.md', '--dry-run']),
        isNull,
      );
    });
  });
}