import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;

import 'active_note_store.dart';
import 's3_object_client.dart';

/// Image files saved next to the notes, named `ql-img-YYMMDD-HHmmss-SSS.ext`.
///
/// They share the `ql-` prefix so they sort with the notes in a synced
/// folder, but never match the `ql-YYMMDD-HHmmss.md` note contract, so every
/// note listing (local, SAF, S3, drain) skips them. Milliseconds keep two
/// pictures taken in the same second apart.
final _imageIdRegex = RegExp(
  r'^ql-img-\d{6}-\d{6}-\d{3}\.(jpg|png|gif|webp|heic)$',
);
final _imageStampFormat = DateFormat('yyMMdd-HHmmss');

/// Image types a note can embed, by lowercase file extension.
const Map<String, String> imageMimeTypes = {
  'jpg': 'image/jpeg',
  'png': 'image/png',
  'gif': 'image/gif',
  'webp': 'image/webp',
  'heic': 'image/heic',
};

/// The stored extension for a picked file named [name]: its own extension
/// when it is a supported image type, otherwise `jpg` (what the camera and
/// the picker's re-encoding produce).
String imageExtensionFor(String name) {
  var ext = p.extension(name).toLowerCase().replaceFirst('.', '');
  if (ext == 'jpeg') ext = 'jpg';
  return imageMimeTypes.containsKey(ext) ? ext : 'jpg';
}

/// Builds the attachment id for an image saved at [stamp].
String imageAttachmentIdFor(DateTime stamp, String extension) {
  final ms = stamp.millisecond.toString().padLeft(3, '0');
  return 'ql-img-${_imageStampFormat.format(stamp)}-$ms.$extension';
}

/// Whether [id] is a bare image attachment name (no path components).
bool isImageAttachmentId(String id) => _imageIdRegex.hasMatch(id);

void requireImageAttachmentId(String id) {
  if (!isImageAttachmentId(id)) {
    throw ArgumentError.value(
      id,
      'id',
      'must match ql-img-YYMMDD-HHmmss-SSS.<image extension>',
    );
  }
}

String _mimeTypeOf(String id) => imageMimeTypes[p.extension(id).substring(1)]!;

/// The Markdown that embeds the image [id] in a note. The path is relative,
/// so the link resolves wherever the folder is synced to.
String markdownImageLink(String id) => '![]($id)';

/// Inserts [markdownImageLink] for [id] at the cursor of [controller] (or
/// replaces the selection), on a line of its own, and puts the cursor after
/// it. Without a valid selection the link is appended.
void insertImageLink(TextEditingController controller, String id) {
  final text = controller.text;
  final selection = controller.selection;
  final start = selection.isValid ? selection.start : text.length;
  final end = selection.isValid ? selection.end : text.length;
  final before = text.substring(0, start);
  final after = text.substring(end);
  final lead = before.isEmpty || before.endsWith('\n') ? '' : '\n';
  final trail = after.startsWith('\n') ? '' : '\n';
  final inserted = '$lead${markdownImageLink(id)}$trail';
  controller.value = TextEditingValue(
    text: '$before$inserted$after',
    selection: TextSelection.collapsed(offset: start + inserted.length),
  );
}

/// Where an image attachment is written. Writes never overwrite: an
/// existing file with the same name is an error.
abstract class ImageAttachmentStore {
  Future<void> write(String id, Uint8List bytes);
}

/// Image files in the plain local notes directory.
class LocalImageAttachmentStore implements ImageAttachmentStore {
  LocalImageAttachmentStore(this.directory);

  final String directory;

  @override
  Future<void> write(String id, Uint8List bytes) async {
    requireImageAttachmentId(id);
    await Directory(directory).create(recursive: true);
    final file = File(p.join(directory, id));
    // exclusive: a same-millisecond name clash fails instead of replacing
    // the picture an earlier note already links to.
    await file.create(exclusive: true);
    try {
      await file.writeAsBytes(bytes, flush: true);
    } catch (_) {
      // A half-written picture is worse than none: the caller reports the
      // error and no link is inserted.
      try {
        await file.delete();
      } catch (_) {}
      rethrow;
    }
  }
}

/// Image files in the Android document tree selected in Preferences.
class SafImageAttachmentStore implements ImageAttachmentStore {
  SafImageAttachmentStore(this.treeUri, {MethodChannel? channel})
    : _channel =
          channel ?? const MethodChannel('org.buetow.quicklog/saf-notes');

  final String treeUri;
  final MethodChannel _channel;

  @override
  Future<void> write(String id, Uint8List bytes) async {
    requireImageAttachmentId(id);
    await _channel.invokeMethod<void>('writeImage', {
      'treeUri': treeUri,
      'id': id,
      'mimeType': _mimeTypeOf(id),
      'bytes': bytes,
    });
  }
}

/// Image objects in the S3 bucket, next to the `ql-*.md` note objects.
class S3ImageAttachmentStore implements ImageAttachmentStore {
  S3ImageAttachmentStore(this.client);

  final S3ObjectClient client;

  @override
  Future<void> write(String id, Uint8List bytes) async {
    requireImageAttachmentId(id);
    await client.putObject(id, bytes, contentType: _mimeTypeOf(id));
  }
}

/// Saves picked image bytes with [extension] and returns the stored id plus
/// where it landed. Implemented by [ActiveNoteStore.saveImage].
typedef ImageSaver =
    Future<ImageSaveResult> Function(Uint8List bytes, String extension);

/// The outcome of saving an image: [id] to link, and whether it reached
/// every backend the storage mode targets (same meaning as for notes).
typedef ImageSaveResult = ({String id, NoteCreateOutcome outcome});
