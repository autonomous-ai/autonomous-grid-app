/// Putting a picture or a document on the computer, a piece at a time.
///
/// The channel carries one frame at a time and the relay **ends the connection**
/// for a frame over 8 MB rather than refusing it, so a file cannot simply be
/// sent. It is begun, fed in pieces the computer sizes, and then named in the
/// message that uses it.
///
/// The piece size comes back from `uploads.begin` rather than being decided
/// here: it is the computer's ceiling, and a phone guessing its own would either
/// waste round trips or lose the channel on a frame that was too big.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'phone_link_controller.dart';
import 'relay_phone_client.dart';

/// A file chosen on the phone, before it has been sent anywhere.
typedef PickedFile = ({String name, Uint8List bytes});

/// The most files one message may carry.
///
/// Not a technical limit — the computer caps what it accepts on its own — but a
/// composer that will take twenty pictures is one somebody sends twenty
/// pictures through, over a phone connection, before noticing.
const int kMaxAttachments = 5;

/// Sends [file] to the computer and returns the id the message names it by.
///
/// Throws [RelayPhoneFailure] carrying the computer's own sentence: it is the
/// side that knows whether the file was too big, too many, or simply refused.
Future<String> uploadFile(WidgetRef ref, PickedFile file) async {
  final link = ref.read(phoneLinkProvider.notifier);
  final begun = await link.call('uploads.begin', {
    'name': file.name,
    'size': file.bytes.length,
  });
  final id = begun['uploadId'];
  if (id is! String || id.isEmpty) {
    throw const RelayPhoneFailure('That file could not be sent.');
  }
  final chunkBytes = begun['chunkBytes'];
  final size = chunkBytes is int && chunkBytes > 0 ? chunkBytes : 128 * 1024;

  for (var start = 0; start < file.bytes.length; start += size) {
    final end = (start + size).clamp(0, file.bytes.length);
    // base64 on a background isolate: a 20 MB document encodes in chunks that
    // are each big enough to drop frames on the UI thread, and the composer is
    // on screen while this runs.
    final piece = await compute(
      _encode,
      Uint8List.sublistView(file.bytes, start, end),
    );
    await link.call('uploads.chunk', {'uploadId': id, 'data': piece});
  }
  return id;
}

/// Reads the file at [path] for sending, keeping the name a person would know
/// it by.
Future<PickedFile> readForUpload(String path, String name) async =>
    (name: name, bytes: await File(path).readAsBytes());

String _encode(Uint8List bytes) => base64Encode(bytes);
