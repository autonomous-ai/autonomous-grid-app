import 'dart:math' as math;

import '../../../../infrastructure/api/telegram_wire.dart';

/// Rows a menu shows per page — dev-quen-bots' number, and about what a phone
/// shows without scrolling.
const int kTelegramMenuPage = 6;

/// One row a menu offers.
typedef TelegramMenuItem = ({String label, String value});

/// What a menu button asks for.
///
/// Every tap names the [menu] it was drawn in, so a button left on an older
/// menu does nothing instead of picking row `i` of the newer one — the wrong
/// chat, in dev-quen-bots, when `/sessions` had been run twice.
sealed class TelegramMenuTap {
  const TelegramMenuTap(this.menu);

  final int menu;
}

/// Row [index] of the menu's list.
final class TelegramPickTap extends TelegramMenuTap {
  const TelegramPickTap(super.menu, this.index);

  final int index;
}

/// Show [page] of the menu's list.
final class TelegramPageTap extends TelegramMenuTap {
  const TelegramPageTap(super.menu, this.page);

  final int page;
}

/// Start a new chat in the place the menu is showing.
final class TelegramNewHereTap extends TelegramMenuTap {
  const TelegramNewHereTap(super.menu);
}

/// Back to the list of projects.
final class TelegramBackTap extends TelegramMenuTap {
  const TelegramBackTap(super.menu);
}

/// The page counter — a label that happens to be a button.
final class TelegramNoopTap extends TelegramMenuTap {
  const TelegramNoopTap(super.menu);
}

/// A tap as `callback_data`: short prefixes and numbers, so it stays far below
/// Telegram's 64-byte cap whatever a chat or model is called.
String encodeTelegramMenuTap(TelegramMenuTap tap) => switch (tap) {
  TelegramPickTap(:final menu, :final index) => 'mp:$menu:$index',
  TelegramPageTap(:final menu, :final page) => 'mg:$menu:$page',
  TelegramNewHereTap(:final menu) => 'mn:$menu',
  TelegramBackTap(:final menu) => 'mb:$menu',
  TelegramNoopTap(:final menu) => 'mx:$menu',
};

/// The inverse of [encodeTelegramMenuTap], or null for data it didn't write.
TelegramMenuTap? parseTelegramMenuTap(String data) {
  final parts = data.split(':');
  final menu = parts.length > 1 ? int.tryParse(parts[1]) : null;
  if (menu == null) return null;
  final arg = parts.length == 3 ? int.tryParse(parts[2]) : null;
  return switch ((parts.first, parts.length, arg)) {
    ('mp', 3, final int index) => TelegramPickTap(menu, index),
    ('mg', 3, final int page) => TelegramPageTap(menu, page),
    ('mn', 2, _) => TelegramNewHereTap(menu),
    ('mb', 2, _) => TelegramBackTap(menu),
    ('mx', 2, _) => TelegramNoopTap(menu),
    _ => null,
  };
}

/// Page [page] of [items] as buttons, one per row, under [top] and above
/// [bottom] — with `◀️ Prev · 2/5 · Next ▶️` when there is more than one page.
TelegramKeyboard telegramMenuRows({
  required int menu,
  required List<TelegramMenuItem> items,
  required int page,
  TelegramKeyboard top = const [],
  TelegramKeyboard bottom = const [],
}) {
  final pages = math.max(1, (items.length / kTelegramMenuPage).ceil());
  final current = page.clamp(0, pages - 1);
  final first = current * kTelegramMenuPage;
  final end = math.min(first + kTelegramMenuPage, items.length);
  TelegramButton button(String label, TelegramMenuTap tap) =>
      (label: label, data: encodeTelegramMenuTap(tap));
  return [
    ...top,
    for (var i = first; i < end; i++)
      [button(items[i].label, TelegramPickTap(menu, i))],
    if (pages > 1)
      [
        if (current > 0) button('◀️ Prev', TelegramPageTap(menu, current - 1)),
        button('${current + 1}/$pages', TelegramNoopTap(menu)),
        if (current < pages - 1)
          button('Next ▶️', TelegramPageTap(menu, current + 1)),
      ],
    ...bottom,
  ];
}

/// How long ago [then] was, the way a list reads it.
String telegramAgo(DateTime then, DateTime now) {
  final gap = now.difference(then);
  if (gap.inMinutes < 1) return 'just now';
  if (gap.inHours < 1) return '${gap.inMinutes}m ago';
  if (gap.inHours < 48) return '${gap.inHours}h ago';
  if (gap.inDays < 14) return '${gap.inDays}d ago';
  return '${gap.inDays ~/ 7}w ago';
}

/// [text] cut to [max] characters, with `…` when it was longer.
String telegramTrim(String text, int max) {
  final line = text.trim().replaceAll(RegExp(r'\s+'), ' ');
  return line.length <= max ? line : '${line.substring(0, max - 1)}…';
}

/// A chat in a session list: `✅` on the one this Telegram chat is in, then
/// its title and when it was last talked in.
String telegramSessionLabel({
  required String title,
  required DateTime updatedAt,
  required DateTime now,
  required bool current,
}) =>
    '${current ? '✅' : '💬'} ${telegramTrim(title, 32)} · '
    '${telegramAgo(updatedAt, now)}';
