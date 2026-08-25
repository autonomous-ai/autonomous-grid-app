import 'dart:convert';

import '../../../infrastructure/panel/panel_frame.dart';
import '../../../infrastructure/panel/panel_message.dart';

/// As many of [tiles] as fit one frame, longest prefix first.
///
/// The whole list goes out as a single message and a frame's payload is capped
/// at [kPanelMaxPayload]; over that, [encodePanelFrame] throws — deliberately,
/// since a caller building an oversized message has a bug. This is that
/// caller's side of the deal, and the bug it is answering was real: titles
/// stopped being clipped in the store on 2026-08-20 so that renaming a chat
/// could offer the whole name back, and the next morning thirty-odd tiles of
/// full sentences went 11724 bytes into an 8192-byte frame, thrown straight out
/// of the mirror with nothing catching it.
///
/// Dropped from the end, because the list arrives in the order the sidebar
/// draws it: what falls off the panel is what the user would have had to scroll
/// furthest to reach.
List<PanelChat> panelTilesThatFit(List<PanelChat> tiles) {
  var kept = tiles;
  while (kept.isNotEmpty && !_fits(kept)) {
    kept = kept.sublist(0, kept.length - 1);
  }
  return kept;
}

bool _fits(List<PanelChat> tiles) =>
    utf8.encode(PanelOutbound.chats(tiles)).length <= kPanelMaxPayload;

/// Keeps the panel's tiles in step with the app's chat list, and remembers
/// what it has already said.
///
/// The memory is the whole point. Chat state moves on every streamed token, and
/// a project's list moves for reasons a tile cannot show — instructions edited,
/// a note added to its memory, a folder pinned somewhere off screen. Every one
/// of those would otherwise put a frame on the wire describing a tile that is
/// byte-for-byte what the panel is already drawing. Comparing the *encoded
/// tile* is what makes the difference: the tile is a thin projection, so most
/// changes behind it are invisible in it, and the ones that are not are exactly
/// the ones worth sending.
///
/// Nothing here is app state — dropping the object loses only the memory.
class PanelChatMirror {
  /// The last tile sent per chat, encoded.
  final Map<String, String> _sent = {};

  /// The order the panel last saw, which is a fact about the list rather than
  /// about any one tile: pinning a chat moves nothing on it and everything about
  /// where it is drawn.
  List<String> _order = const [];

  /// The whole list, for a panel that asked — or one that has just woken up.
  ///
  /// Always sent, never deduplicated: `chats.list` is a panel saying it has
  /// nothing on screen, and answering "you already know" would leave it blank.
  String all(List<PanelChat> tiles) {
    _remember(tiles);
    return PanelOutbound.chats(tiles);
  }

  /// What to say after the app's own list moved.
  ///
  /// The whole list when its shape changed — a chat added, removed, or moved
  /// past another — because the panel draws them in the order they arrive and
  /// there is no message for "the third one is now the first". One
  /// `chat.updated` per tile that actually reads differently otherwise.
  List<String> onChange(List<PanelChat> tiles) {
    final ids = [for (final tile in tiles) tile.id];
    if (!_sameOrder(ids)) {
      _remember(tiles);
      return [PanelOutbound.chats(tiles)];
    }
    final messages = <String>[];
    for (final tile in tiles) {
      final item = jsonEncode(tile.toJson());
      if (_sent[tile.id] == item) continue;
      _sent[tile.id] = item;
      messages.add(PanelOutbound.chatUpdated(tile));
    }
    return messages;
  }

  /// Forget everything, for a panel that has just plugged in knowing nothing.
  void forget() {
    _sent.clear();
    _order = const [];
  }

  void _remember(List<PanelChat> tiles) {
    _sent
      ..clear()
      ..addEntries([
        for (final tile in tiles) MapEntry(tile.id, jsonEncode(tile.toJson())),
      ]);
    _order = [for (final tile in tiles) tile.id];
  }

  bool _sameOrder(List<String> ids) {
    if (ids.length != _order.length) return false;
    for (var i = 0; i < ids.length; i++) {
      if (ids[i] != _order[i]) return false;
    }
    return true;
  }
}
