import 'dart:io';

import 'package:file_selector/file_selector.dart';

import '../../../infrastructure/platform/native_documents.dart';
import '../../playground/logic/chat_file.dart';
import '../../playground/logic/image_budget.dart';
import '../../playground/logic/image_shrink.dart';
import '../../playground/logic/playground_request.dart';
import 'document_text.dart';

/// How many documents one message may carry.
///
/// A limit for the model's sake, not the app's: each file spends prompt space
/// the conversation itself needs, and a message that arrives as five documents
/// and one line of text is already asking a lot of an answer.
const int maxChatFiles = 5;

/// The largest file the app will read into memory to pull text out of.
///
/// Past this it is attached by path alone. Reading a 200 MB export to send the
/// first twenty thousand characters of it would freeze the window for what a
/// single line of the file could have said.
const int kMaxReadableFileBytes = 25 * 1024 * 1024;

/// What one drop, paste or pick turned into.
class ComposerAttachments {
  const ComposerAttachments({
    this.images = const [],
    this.files = const [],
    this.paths = const [],
    this.overflow = const [],
    this.oversized = const [],
  });

  /// Pictures, for a model that can see.
  final List<MediaAttachment> images;

  /// Documents, read where the app could read them.
  final List<ChatFile> files;

  /// What couldn't be attached but can still be pointed at — a folder, a file
  /// the app can't open. These go into the message as text, so the assistant
  /// hears about them rather than the drop doing nothing.
  final List<String> paths;

  /// Names left behind because the message is already carrying its limit. Kept
  /// apart from [paths]: the user asked for a file, not for its path in their
  /// sentence, so the composer says what happened instead.
  final List<String> overflow;

  /// Pictures too large to send even after the app shrank them. Their own list
  /// because the reason — and so the way out of it — is not the message's
  /// limit but the picture's own size.
  final List<String> oversized;
}

/// Turns dropped, pasted or picked [paths] into what the composer holds:
/// pictures as attachments, documents as [ChatFile]s with their text read out,
/// and anything that fits neither as a path to mention.
///
/// [imageBytesBudget] is the picture budget still free on this message (see
/// [imageBudgetLeft]) and [fileBudget] the document slots left.
Future<ComposerAttachments> readAttachments(
  Iterable<String> paths, {
  required int imageBytesBudget,
  required int fileBudget,
}) async {
  var imageBytesLeft = imageBytesBudget;
  final images = <MediaAttachment>[];
  final files = <ChatFile>[];
  final mentioned = <String>[];
  final overflow = <String>[];
  final oversized = <String>[];

  for (final path in paths) {
    final trimmed = path.trim();
    if (trimmed.isEmpty) continue;
    if (await FileSystemEntity.isDirectory(trimmed)) {
      mentioned.add(trimmed);
      continue;
    }

    if (isImageFilename(trimmed)) {
      // Pictures are bounded by what the wire holds, not by how many there are:
      // a message takes as many as fit, and only runs out of room on bytes.
      if (imageBytesLeft <= 0) {
        overflow.add(fileNameOf(trimmed));
        continue;
      }
      final room = imageBudgetForNext(imageBytesLeft);
      final (:image, :tooBig) = await _readImage(trimmed, budgetBytes: room);
      if (image != null) {
        images.add(image);
        imageBytesLeft -= image.bytes.length;
        continue;
      }
      if (tooBig) {
        // A picture that would have fitted an empty message but not what is
        // left of this one didn't do anything wrong — that is overflow, and
        // telling the user to crop a perfectly ordinary screenshot would send
        // them off to fix the wrong thing.
        final crowdedOut = room < kMaxAttachmentBytes;
        (crowdedOut ? overflow : oversized).add(fileNameOf(trimmed));
        continue;
      }
      // Unreadable (a sandbox denial, a file that moved between the drop and
      // the read): the path is still real, so point at it rather than lose it.
      mentioned.add(trimmed);
      continue;
    }

    if (files.length >= fileBudget) {
      overflow.add(fileNameOf(trimmed));
      continue;
    }
    final file = await readChatFile(trimmed);
    if (file == null) {
      mentioned.add(trimmed);
      continue;
    }
    files.add(file);
  }

  return ComposerAttachments(
    images: images,
    files: files,
    paths: mentioned,
    overflow: overflow,
    oversized: oversized,
  );
}

/// What to tell the user when [overflow] files didn't fit on the message.
///
/// Names the first one so it's clear *which* was left behind, and says the limit
/// so the next attempt isn't the same surprise. Empty when nothing overflowed.
String? attachmentOverflowMessage(List<String> overflow) {
  if (overflow.isEmpty) return null;
  final rest = overflow.length - 1;
  final what = rest == 0
      ? '“${overflow.first}” wasn’t added'
      : '“${overflow.first}” and $rest more weren’t added';
  return '$what — a message holds up to '
      '${kImagePayloadBudget ~/ 1000000} MB of pictures and $maxChatFiles '
      'files.';
}

/// Opens the system picker for everything a message can carry — pictures and
/// documents in one list, because "attach a file" is one thought.
///
/// Returns the chosen paths (empty when the user cancelled) for
/// [readAttachments] to sort out, so the picker, a drop and a paste all land in
/// the same place.
Future<List<String>> pickAttachmentPaths() async {
  final files = await openFiles(
    acceptedTypeGroups: const [
      XTypeGroup(
        label: 'Pictures and documents',
        extensions: [...kImageExtensions, ...kDocumentExtensions],
      ),
    ],
  );
  return [for (final file in files) file.path];
}

/// Reads the file at [path] into a [ChatFile], with its text where the app can
/// get it. Null when there is no readable file there at all — deleted between
/// the drop and the read, or denied by the sandbox.
///
/// A file whose *text* can't be read still comes back: the path is real, the
/// chip names it, and an agent with file tools may open what the app couldn't.
Future<ChatFile?> readChatFile(String path) async {
  final file = File(path);
  final int size;
  try {
    size = await file.length();
  } on FileSystemException {
    return null;
  }

  final name = fileNameOf(path);
  final extracted = await _extract(file, name, size);
  return ChatFile(
    path: path,
    name: name,
    sizeBytes: size,
    text: extracted?.text,
    truncated: extracted?.truncated ?? false,
  );
}

/// The text inside a file, from whichever reader knows the format — the
/// operating system for PDF, the pure extractor for everything else.
Future<DocumentText?> _extract(File file, String name, int size) async {
  // A 400-page contract goes through the same tidy-and-cap as a Word file, so
  // one attachment can't eat the whole prompt just because macOS read it whole.
  if (fileExtensionOf(name) == 'pdf') {
    final text = await NativeDocuments.pdfText(file.path);
    return text == null ? null : tidyAndCap(text);
  }
  if (size > kMaxReadableFileBytes) return null;
  try {
    return extractDocumentText(name, await file.readAsBytes());
  } on FileSystemException {
    return null;
  }
}

/// Reads the picture at [path], shrunk to fit [budgetBytes].
///
/// `tooBig` separates the two ways this comes back empty-handed: a picture the
/// app can't get under the wire's limit (say so — the user can crop it) and a
/// file it couldn't read at all (mention the path instead).
Future<({MediaAttachment? image, bool tooBig})> _readImage(
  String path, {
  required int budgetBytes,
}) async {
  final file = File(path);
  try {
    // Never read a huge file into memory just to find out it can't be sent:
    // the resize would have to decode it first, and the window would stop.
    if (await file.length() > kMaxImageFileBytes) {
      return (image: null, tooBig: true);
    }
    final read = MediaAttachment(
      filename: fileNameOf(path),
      bytes: await file.readAsBytes(),
    );
    final fitted = await fitImageToBudget(read, budgetBytes: budgetBytes);
    return (image: fitted, tooBig: fitted == null);
  } on FileSystemException {
    return (image: null, tooBig: false);
  }
}
