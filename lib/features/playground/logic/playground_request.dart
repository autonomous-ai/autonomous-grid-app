import 'dart:typed_data';

import '../../../infrastructure/api/models/media_event.dart';

/// What the Playground does with a message, decided by the selected model's
/// modality (from the grid overview): plain text goes to `chat/completions`,
/// `image`/`video` go to the relay's media endpoints. See [modalityFromString].
enum PlaygroundModality { text, image, video }

/// Maps a grid-overview `modality` string to a [PlaygroundModality]. The relay's
/// vocabulary is `chat` / `image` / `video` (model_catalog.VALID_MODALITIES);
/// anything unknown or missing is treated as text, the safe default.
PlaygroundModality modalityFromString(String? modality) =>
    switch (modality?.trim().toLowerCase()) {
      'image' => PlaygroundModality.image,
      'video' => PlaygroundModality.video,
      _ => PlaygroundModality.text,
    };

/// The relay media endpoint (appended to `{relayBaseUrl}/`) and provider
/// capability for each media operation. The relay derives the capability from
/// the path first, falling back to the request body's `capability`
/// (relay.py:1422) — we send both so the request matches the documented API.
enum MediaOperation {
  imageGenerate('media/image/generate', kCapImageGenerate),
  imageEdit('media/image/edit', kCapImageEdit),
  i2v('media/video/i2v', kCapI2V);

  const MediaOperation(this.path, this.capability);

  /// Path segment after `{relayBaseUrl}/`, e.g. `media/image/generate`.
  final String path;

  /// Provider capability id the relay routes on, e.g. `comfyui:image_generation`.
  final String capability;
}

/// The image file types the app accepts as attachments. The picker's filter, the
/// composer's drag-and-drop sorter and the paste handler share this list so the
/// three never drift.
const List<String> kImageExtensions = [
  'png',
  'jpg',
  'jpeg',
  'webp',
  'gif',
  'bmp',
];

/// Whether [name] — a filename or a path — ends in one of [kImageExtensions], so
/// a dropped image is attached as a picture rather than mentioned by path.
bool isImageFilename(String name) {
  final dot = name.lastIndexOf('.');
  return dot >= 0 &&
      kImageExtensions.contains(name.substring(dot + 1).toLowerCase());
}

/// How many pictures one message may carry to a vision model.
const int maxChatImages = 4;

/// An image the user attached for an edit / image-to-video request. Held in
/// memory as raw bytes until it's encoded into a request payload.
class MediaAttachment {
  const MediaAttachment({required this.filename, required this.bytes});
  final String filename;
  final Uint8List bytes;

  MediaFile toMediaFile() => MediaFile.fromBytes(filename, bytes);
}

/// Default image dimensions and step count — the relay accepts these directly
/// (relay.py media schema); 1024² is the documented product default.
const int kDefaultImageSize = 1024;
const int kDefaultImageSteps = 4;

/// Text-to-image body for `media/image/generate`.
Map<String, dynamic> imageGeneratePayload(
  String prompt, {
  int width = kDefaultImageSize,
  int height = kDefaultImageSize,
  int steps = kDefaultImageSteps,
}) => {
  'capability': MediaOperation.imageGenerate.capability,
  'prompt': prompt,
  'width': width,
  'height': height,
  'steps': steps,
};

/// Image-edit body for `media/image/edit`: a prompt plus one to three source
/// images (relay rejects more than three).
Map<String, dynamic> imageEditPayload(
  String prompt,
  List<MediaAttachment> images, {
  int steps = kDefaultImageSteps,
}) => {
  'capability': MediaOperation.imageEdit.capability,
  'prompt': prompt,
  'steps': steps,
  'input_images': [for (final image in images) image.toMediaFile().toJson()],
};

/// Image-to-video body for `media/video/i2v`: a prompt plus a single source
/// image the model animates.
Map<String, dynamic> i2vPayload(
  String prompt,
  MediaAttachment image, {
  String duration = '5s',
  String aspectRatio = '2:3',
}) => {
  'capability': MediaOperation.i2v.capability,
  'prompt': prompt,
  'duration': duration,
  'aspect_ratio': aspectRatio,
  'input_image': image.toMediaFile().toJson(),
};
