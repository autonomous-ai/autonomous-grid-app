import 'chat_message.dart';
import 'message_media.dart';
import 'playground_request.dart';

/// The largest request body the relay accepts, in bytes.
///
/// The relay's own number, quoted back in the failure it sends when a body is
/// bigger than it: `Request body exceeds 20000000 bytes`. Pictures travel
/// inside that body as base64 text, so this ceiling — not the model's context
/// — is what decides how much picture one message can carry.
const int kMaxRequestBytes = 20000000;

/// How many raw picture bytes one request may carry.
///
/// Base64 adds a third on top ([base64Size]), so 10 MB of picture is 13.4 MB on
/// the wire and leaves the rest of [kMaxRequestBytes] for the conversation's
/// text — every earlier turn is re-sent with the new one.
const int kImagePayloadBudget = 10 * 1000 * 1000;

/// The raw-byte ceiling for one attached picture.
///
/// A whole message's worth of them has to fit [kImagePayloadBudget] together,
/// so the cap is that budget split [maxChatImages] ways: even four pictures at
/// the limit make a request the relay accepts.
const int kMaxAttachmentBytes = kImagePayloadBudget ~/ maxChatImages;

/// The largest picture file the app will read into memory to shrink.
///
/// Past this it is refused unopened: shrinking has to decode the picture first,
/// and a 200 MB file would stop the window for a picture that was never going
/// to fit the wire anyway.
const int kMaxImageFileBytes = 25 * 1024 * 1024;

/// The longest side, in pixels, an oversized picture is shrunk towards.
///
/// Vision models tile what they are given and read a picture at roughly this
/// size anyway, so the pixels beyond it cost upload and prompt space without
/// telling the model anything it could otherwise not see.
const int kMaxImageDimension = 1568;

/// Longest sides tried in turn while shrinking a picture to fit its budget.
///
/// Re-encoding is PNG (the only encoder Flutter ships), which can be larger
/// than the JPEG it came from at the same size — so one step is not enough on
/// its own, and each step quarters the pixels of the one before it.
const List<int> kImageShrinkSteps = [kMaxImageDimension, 1024, 768, 512];

/// How many bytes [bytes] of binary become once base64-encoded.
int base64Size(int bytes) => ((bytes + 2) ~/ 3) * 4;

/// The size to decode a [width]×[height] picture at so its longest side is at
/// most [longestSide], or null when it is already that small.
///
/// Null rather than the original size on purpose: there is nothing to gain from
/// re-encoding a picture at the size it already is, and enlarging one to reach
/// a byte budget would make the file bigger, not smaller.
({int width, int height})? targetImageSize({
  required int width,
  required int height,
  required int longestSide,
}) {
  if (width <= 0 || height <= 0 || longestSide <= 0) return null;
  final longest = width > height ? width : height;
  if (longest <= longestSide) return null;
  final scale = longestSide / longest;
  return (
    width: (width * scale).round().clamp(1, width),
    height: (height * scale).round().clamp(1, height),
  );
}

/// [name] with a `.png` extension — what a re-encoded picture has to be called.
///
/// The wire's MIME type is derived from the filename, so PNG bytes sent under
/// the name `photo.jpg` reach the model labelled as something they are not, and
/// it fails to read them.
String pngFilename(String name) {
  final dot = name.lastIndexOf('.');
  final stem = dot <= 0 ? name : name.substring(0, dot);
  return '$stem.png';
}

/// Which of a conversation's pictures fit in one request, and how many did not.
///
/// Every earlier turn goes out again with the new one, so a chat that collected
/// screenshots over an afternoon outgrows the relay's ceiling even though each
/// picture was inside its own limit when it was attached. The newest turns win:
/// the picture the question is *about* is the one that has to arrive.
///
/// [sizeOf] gives the bytes on disk for a path, and any negative number for a
/// file that is no longer there.
({Set<String> keep, int dropped}) imagesWithinBudget(
  List<ChatMessage> history, {
  required int Function(String path) sizeOf,
  int budgetBytes = kImagePayloadBudget,
}) {
  final keep = <String>{};
  var dropped = 0;
  var spent = 0;

  for (final message in history.reversed) {
    for (final media in message.media) {
      if (media.kind != MediaKind.image) continue;
      final size = sizeOf(media.path);
      // Unreadable is not the same as over budget: the encoder drops such a
      // path anyway, and counting its size would push out a picture that does
      // still exist.
      if (size < 0) continue;
      if (spent + size > budgetBytes) {
        dropped++;
        continue;
      }
      spent += size;
      keep.add(media.path);
    }
  }
  return (keep: keep, dropped: dropped);
}

/// What to tell the user when [oversized] pictures were too big to send.
///
/// Its own message, not the one for a full message: the composer had room, the
/// picture was the problem — and the app already tried shrinking it before
/// saying anything, so the only thing left to suggest is a smaller picture.
String? oversizedAttachmentMessage(List<String> oversized) {
  if (oversized.isEmpty) return null;
  final rest = oversized.length - 1;
  final what = rest == 0
      ? '“${oversized.first}” is'
      : '“${oversized.first}” and $rest more are';
  return '$what too large to send, even after shrinking. Crop it or save a '
      'smaller copy, then attach it again.';
}
