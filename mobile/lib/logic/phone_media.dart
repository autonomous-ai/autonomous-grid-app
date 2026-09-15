/// Fetching a picture that is attached to a turn.
///
/// A slice at a time, because the relay ends a connection that frames more than
/// 8 MB and an iPhone photo is measured in megabytes — the one that prompted
/// this was 3.78 MB before base64 grew it by a third.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'phone_link_controller.dart';

/// Which picture: the chat, the turn it hangs on, and which one of them.
typedef MediaRequest = ({String chatId, int message, int media});

/// The bytes of one attached picture, assembled.
///
/// A `FutureProvider.family`, so the same picture scrolled past twice is
/// fetched once and the second view is free — a transcript that re-downloaded
/// every photo on every rebuild would be unusable over a phone connection.
final chatMediaProvider = FutureProvider.family<Uint8List, MediaRequest>((
  ref,
  request,
) async {
  final link = ref.watch(phoneLinkProvider.notifier);
  final bytes = BytesBuilder(copy: false);
  var size = -1;
  while (size < 0 || bytes.length < size) {
    final slice = await link.call('chats.media', {
      'id': request.chatId,
      'message': request.message,
      'media': request.media,
      'offset': bytes.length,
    });
    final data = slice['data'];
    final whole = slice['size'];
    if (data is! String || whole is! int) {
      throw StateError('That picture came back malformed.');
    }
    final piece = base64Decode(data);
    // A slice that carries nothing while bytes are still owed would spin here
    // forever — the file shrank, or the computer refused the range.
    if (piece.isEmpty) break;
    bytes.add(piece);
    size = whole;
  }
  return bytes.takeBytes();
}, retry: null);
