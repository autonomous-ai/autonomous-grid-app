import 'dart:convert';

import '../../../infrastructure/cli/hermes_acp_service.dart';
import '../../playground/logic/chat_file.dart' show fileExtensionOf;
import '../../playground/logic/playground_request.dart';

/// The pictures on a turn, in the shape ACP puts on the wire.
///
/// Pure and tested rather than inlined at the call site, because the two things
/// it decides both fail silently: a wrong MIME type reaches the model as a
/// picture it can't decode, and a base64 body that never got built reaches it as
/// no picture at all — either way the answer is confidently about nothing.
List<HermesAcpImage> acpImages(List<MediaAttachment> attachments) => [
  for (final attachment in attachments)
    (
      base64: base64Encode(attachment.bytes),
      mimeType: imageMimeType(attachment.filename),
    ),
];

/// The MIME type for an attached picture, from its name.
///
/// PNG when the name says nothing useful: Hermes defaults to `image/png` on a
/// missing type anyway (`acp_adapter/server.py`), so agreeing with it keeps the
/// two ends saying the same thing rather than each guessing separately.
String imageMimeType(String filename) => switch (fileExtensionOf(filename)) {
  'jpg' || 'jpeg' => 'image/jpeg',
  'gif' => 'image/gif',
  'webp' => 'image/webp',
  'bmp' => 'image/bmp',
  'heic' => 'image/heic',
  _ => 'image/png',
};
