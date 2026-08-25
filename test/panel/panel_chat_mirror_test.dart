import 'package:grid_app/infrastructure/panel/panel_frame.dart';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/panel/logic/panel_chat_mirror.dart';
import 'package:grid_app/infrastructure/panel/panel_message.dart';

PanelChat _tile(String id, {String recap = ''}) => PanelChat(
  id: id,
  name: id.toUpperCase(),
  project: 'grid-app',
  recap: recap,
);

Map<String, Object?> _decode(String raw) =>
    jsonDecode(raw) as Map<String, Object?>;

List<String> _idsOf(String raw) => [
  for (final item in _decode(raw)['items']! as List)
    (item as Map<String, Object?>)['id']! as String,
];

void main() {
  _fitTests();
  group('what the panel is told when the chat list moves', () {
    test('a reorder is sent as the whole list, because there is no message '
        'for "the third one is now the first"', () {
      // THE FIRMWARE DEPENDS ON THIS. Its reconcile matches tiles by id and
      // appends the ones it has not seen, so the only thing that can put the
      // ring in the app's order is a `chats` list arriving in that order. Emit
      // `chat.updated` here instead and the panel would draw a chat that had
      // moved to the top of the sidebar wherever it happened to be already.
      final mirror = PanelChatMirror();
      mirror.all([_tile('a'), _tile('b'), _tile('c')]);

      final messages = mirror.onChange([_tile('c'), _tile('a'), _tile('b')]);

      expect(messages, hasLength(1));
      expect(_decode(messages.single)['t'], 'chats');
      expect(_idsOf(messages.single), ['c', 'a', 'b']);
    });

    test('a new chat arrives as the whole list too — it belongs at the top, '
        'and appending it is exactly what the panel would do on its own', () {
      final mirror = PanelChatMirror();
      mirror.all([_tile('a'), _tile('b')]);

      final messages = mirror.onChange([_tile('new'), _tile('a'), _tile('b')]);

      expect(_decode(messages.single)['t'], 'chats');
      expect(_idsOf(messages.single), ['new', 'a', 'b']);
    });

    test('a tile that changed where the order did not is one chat.updated — '
        'resending the list would redraw every tile to move none', () {
      final mirror = PanelChatMirror();
      mirror.all([_tile('a'), _tile('b')]);

      final messages = mirror.onChange([
        _tile('a'),
        _tile('b', recap: 'Finished the migration'),
      ]);

      expect(messages, hasLength(1));
      final message = _decode(messages.single);
      expect(message['t'], 'chat.updated');
      expect((message['item']! as Map<String, Object?>)['id'], 'b');
    });

    test('nothing said when nothing reads differently, however much moved '
        'behind the tiles', () {
      final mirror = PanelChatMirror();
      mirror.all([_tile('a'), _tile('b')]);

      expect(mirror.onChange([_tile('a'), _tile('b')]), isEmpty);
    });

    test('a panel that plugged in knowing nothing is told the list again, '
        'even though it is the same list', () {
      final mirror = PanelChatMirror();
      mirror.all([_tile('a'), _tile('b')]);
      mirror.forget();

      // Not through onChange: `chats.list` is a panel saying it has nothing on
      // screen, and "you already know" would leave it blank.
      expect(_idsOf(mirror.all([_tile('a'), _tile('b')])), ['a', 'b']);
    });
  });
}

void _fitTests() {
  group('a list that has to fit one frame', () {
    PanelChat tile(int i, String name) =>
        PanelChat(id: 'c-$i', name: name, project: 'dự án');

    test('goes out whole when it fits, because trimming a list that fits '
        'would hide chats for nothing', () {
      final tiles = [for (var i = 0; i < 5; i++) tile(i, 'chat $i')];

      expect(panelTilesThatFit(tiles), hasLength(5));
    });

    test('is cut from the end until it fits — the frame throws over 8192 '
        'bytes, and a mirror that throws stops the panel dead', () {
      // Vietnamese titles at three bytes a character, which is what actually
      // overran the budget: 11724 bytes of tiles on 2026-08-21.
      final long = 'Mục tiêu của mày là làm performance cho repo này' * 3;
      final tiles = [for (var i = 0; i < 80; i++) tile(i, long)];

      final kept = panelTilesThatFit(tiles);

      expect(kept.length, lessThan(80));
      expect(kept, isNotEmpty);
      expect(
        utf8.encode(PanelOutbound.chats(kept)).length,
        lessThanOrEqualTo(kPanelMaxPayload),
      );
      expect(
        kept.first.id,
        'c-0',
        reason: 'what falls off is what the sidebar draws last',
      );
    });
  });
}
