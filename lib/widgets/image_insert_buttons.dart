import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../services/active_note_store.dart';
import '../services/image_attachments.dart';

export 'package:image_picker/image_picker.dart' show ImageSource;

/// A picture chosen by the user: its original file name (for the
/// extension) and its bytes.
typedef PickedImage = ({String name, Uint8List bytes});

/// Lets the user choose a picture from [source]; null when they cancel.
typedef ImagePickFn = Future<PickedImage?> Function(ImageSource source);

/// Longest side, in pixels, of a picture added to a note. Phone cameras
/// shoot 4000px and more; notes are synced to every peer, and this is
/// plenty to read a whiteboard or a receipt.
const double kMaxImageDimension = 2560;

/// [ImagePickFn] backed by the platform picker: the system photo picker
/// (gallery) or the camera app, downscaled and re-encoded at 85% quality.
Future<PickedImage?> pickWithImagePicker(ImageSource source) async {
  final file = await ImagePicker().pickImage(
    source: source,
    maxWidth: kMaxImageDimension,
    maxHeight: kMaxImageDimension,
    imageQuality: 85,
  );
  if (file == null) return null;
  return (name: file.name, bytes: await file.readAsBytes());
}

/// Whether the platform can take a picture with a camera (not on Linux).
bool platformSupportsCamera() {
  try {
    return ImagePicker().supportsImageSource(ImageSource.camera);
  } catch (_) {
    return false;
  }
}

/// An "Add image" button (gallery or camera) that saves the chosen picture next to the
/// notes via [saveImage] and insert a Markdown image link to it at the
/// cursor of [controller].
class ImageInsertButtons extends StatefulWidget {
  const ImageInsertButtons({
    super.key,
    required this.controller,
    required this.saveImage,
    this.enabled = true,
    this.pickImage = pickWithImagePicker,
    this.cameraSupported,
    this.onInserted,
  });

  final TextEditingController controller;
  final ImageSaver saveImage;
  final bool enabled;
  final ImagePickFn pickImage;

  /// Overrides [platformSupportsCamera] (tests, and platforms without a
  /// camera app hide the camera button).
  final bool? cameraSupported;

  /// Called after a link was inserted, e.g. to refocus the text field.
  final VoidCallback? onInserted;

  @override
  State<ImageInsertButtons> createState() => _ImageInsertButtonsState();
}

class _ImageInsertButtonsState extends State<ImageInsertButtons> {
  bool _busy = false;
  late final bool _camera = widget.cameraSupported ?? platformSupportsCamera();

  Future<void> _add(ImageSource source) async {
    setState(() => _busy = true);
    try {
      final picked = await widget.pickImage(source);
      if (picked == null) return;
      final result = await widget.saveImage(
        picked.bytes,
        imageExtensionFor(picked.name),
      );
      insertImageLink(widget.controller, result.id);
      widget.onInserted?.call();
      final message = _outcomeMessage(result.outcome);
      if (message != null) _snack(message);
    } catch (e) {
      _snack('Could not add the image: $e', isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static String? _outcomeMessage(NoteCreateOutcome outcome) =>
      switch (outcome) {
        NoteCreateOutcome.saved => null,
        NoteCreateOutcome.savedLocalOnly =>
          'S3 unavailable — the image was saved on this device.',
        NoteCreateOutcome.savedS3Only =>
          'The local write failed — the image is in the S3 bucket only.',
        NoteCreateOutcome.savedLocalS3SettingsInvalid =>
          'S3 settings invalid — the image was saved on this device. '
              'Check Preferences.',
      };

  void _snack(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled && !_busy;
    const icon = Icon(Icons.add_photo_alternate_outlined);
    // One button keeps the editor's action row narrow enough for a phone;
    // it opens a gallery / camera menu, or the gallery directly where
    // there is no camera.
    if (!_camera) {
      return IconButton(
        tooltip: 'Add image',
        icon: icon,
        visualDensity: VisualDensity.compact,
        onPressed: enabled ? () => _add(ImageSource.gallery) : null,
      );
    }
    return PopupMenuButton<ImageSource>(
      tooltip: 'Add image',
      icon: icon,
      enabled: enabled,
      style: IconButton.styleFrom(visualDensity: VisualDensity.compact),
      onSelected: _add,
      itemBuilder: (_) => const [
        PopupMenuItem(
          value: ImageSource.gallery,
          child: ListTile(
            leading: Icon(Icons.photo_library_outlined),
            title: Text('Choose from gallery'),
          ),
        ),
        PopupMenuItem(
          value: ImageSource.camera,
          child: ListTile(
            leading: Icon(Icons.photo_camera_outlined),
            title: Text('Take a photo'),
          ),
        ),
      ],
    );
  }
}
