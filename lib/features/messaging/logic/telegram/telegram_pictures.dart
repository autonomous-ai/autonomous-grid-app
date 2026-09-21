import '../../../../infrastructure/api/telegram_bot_api.dart';
import '../../../../infrastructure/api/telegram_wire.dart';
import '../../../../infrastructure/logging/app_log.dart';
import '../../../playground/logic/image_shrink.dart';
import '../../../playground/logic/playground_request.dart';

/// What the assistant is asked when a picture comes with no caption.
///
/// A chat turn needs words — an empty one is dropped before it is sent — and a
/// picture on its own is still a question: a bare screenshot is about the most
/// ordinary thing anyone sends a bot.
const String kTelegramBarePicturePrompt = 'Take a look at this picture.';

/// What the sender is told when Grid fetched their picture but can't use it —
/// a format it doesn't read (HEIC, sent as a file), or one it can't shrink to
/// fit a message. Sent as a photo, it arrives as a JPEG Telegram has already
/// shrunk, which always fits.
const String kTelegramPictureUnreadable =
    "Grid couldn't read that picture. Send it as a photo rather than a file "
    'and it arrives in a format Grid reads.';

/// The words a Telegram [message] puts in its chat turn — see
/// [kTelegramBarePicturePrompt].
String telegramTurnText(TelegramText message) =>
    message.pictureId != null && message.text.trim().isEmpty
    ? kTelegramBarePicturePrompt
    : message.text;

/// What the sender is told when their picture couldn't be fetched.
String telegramPictureFailure(TelegramFailure failure) => switch (failure) {
  TelegramRefused(tooBig: true) =>
    'That file is bigger than the 20 MB Telegram lets a bot fetch. Send it as '
        'a photo instead — Telegram shrinks those.',
  _ => "Couldn't fetch that picture from Telegram. Try sending it again.",
};

/// The pictures a Telegram message adds to its chat turn — or, in [problem],
/// what to tell its sender instead of answering.
typedef TelegramPictures = ({List<MediaAttachment> pictures, String? problem});

const TelegramPictures _none = (pictures: [], problem: null);

/// Nothing attached, and [problem] to tell the sender instead.
TelegramPictures _turnedAway(String problem) =>
    (pictures: const <MediaAttachment>[], problem: problem);

/// The picture on [message], fetched and made ready for a chat turn; none for
/// plain text.
///
/// Shrunk exactly as a picture dropped on the window is ([fitImageToBudget]),
/// so a big one fits the request the relay accepts rather than coming back as
/// a refusal nobody on a phone could act on.
Future<TelegramPictures> telegramPicturesOf(
  TelegramBotApi api,
  TelegramText message, {
  required AppLog log,
}) async {
  final id = message.pictureId;
  if (id == null) return _none;
  // Turned away before the download, not after it: a picture sent as a file is
  // the full-resolution original, and an iPhone's is both the likeliest format
  // Grid can't read and tens of megabytes of it.
  final sent = message.pictureName;
  if (sent != null && !isImageFilename(sent)) {
    log.warn('telegram', "couldn't read a picture: $sent");
    return _turnedAway(kTelegramPictureUnreadable);
  }
  final TelegramFile file;
  try {
    file = await api.downloadFile(id);
  } on TelegramFailure catch (error) {
    log.warn('telegram', "couldn't fetch a picture: $error");
    return _turnedAway(telegramPictureFailure(error));
  }
  final picture = isImageFilename(file.name)
      ? await fitImageToBudget(
          MediaAttachment(filename: file.name, bytes: file.bytes),
        )
      : null;
  if (picture != null) return (pictures: [picture], problem: null);
  log.warn('telegram', "couldn't read a picture: ${file.name}");
  return _turnedAway(kTelegramPictureUnreadable);
}
