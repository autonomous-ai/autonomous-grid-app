import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/shared/theme/app_theme.dart';
import 'package:grid_app/shared/widgets/anchored_menu_position.dart';

/// Where an upward-opening menu lands is arithmetic, and getting it wrong is
/// invisible until a user opens the panel over the thing they were reading.
/// A menu grows *down* from the offset it is given, so one that opens upward is
/// placed at "anchor top − the height it is about to take": every pixel the
/// caller over-estimates that height by is a pixel of gap between the panel and
/// the button it belongs to.

/// A composer pill at the bottom of a 900×700 window, 8px in from the right.
const _overlay = Size(900, 700);
const _anchorSize = Size(120, 28);
const _anchorTopLeft = Offset(772, 650);

/// Where the panel's top edge ends up in overlay coordinates.
double _topOf(Offset offset) => _anchorTopLeft.dy + offset.dy;

void main() {
  group('a menu opening upward', () {
    test('sits on its button when the list is short enough to draw whole', () {
      final offset = anchoredMenuOffset(
        anchorTopLeft: _anchorTopLeft,
        anchorSize: _anchorSize,
        overlaySize: _overlay,
        menuSize: const Size(340, 120),
        gap: 6,
        margin: 8,
        alignEnd: true,
        preferAbove: true,
      );

      expect(_topOf(offset) + 120, _anchorTopLeft.dy - 6);
    });

    test(
      'sits on its button even when its list is taller than a panel can draw',
      () {
        // What the chat model picker asks for on a grid serving a dozen models.
        final offset = anchoredMenuOffset(
          anchorTopLeft: _anchorTopLeft,
          anchorSize: _anchorSize,
          overlaySize: _overlay,
          menuSize: const Size(340, 310),
          gap: 6,
          margin: 8,
          alignEnd: true,
          preferAbove: true,
        );

        // The panel is capped at AppControl.menuMaxHeight, so its *bottom* is
        // what has to land on the pill: placing it by the uncapped 310 hung it
        // 70px higher, over the conversation.
        expect(
          _topOf(offset) + AppControl.menuMaxHeight,
          _anchorTopLeft.dy - 6,
        );
      },
    );

    test('drops back below the button when there is no room above it', () {
      const highAnchor = Offset(772, 40);

      final offset = anchoredMenuOffset(
        anchorTopLeft: highAnchor,
        anchorSize: _anchorSize,
        overlaySize: _overlay,
        menuSize: const Size(340, 200),
        gap: 6,
        margin: 8,
        alignEnd: true,
        preferAbove: true,
      );

      expect(highAnchor.dy + offset.dy, highAnchor.dy + _anchorSize.height + 6);
    });
  });

  group('horizontally', () {
    test('a right-aligned menu ends where its trigger ends', () {
      final offset = anchoredMenuOffset(
        anchorTopLeft: _anchorTopLeft,
        anchorSize: _anchorSize,
        overlaySize: _overlay,
        menuSize: const Size(340, 120),
        gap: 6,
        margin: 8,
        alignEnd: true,
        preferAbove: true,
      );

      final left = _anchorTopLeft.dx + offset.dx;
      expect(left + 340, _anchorTopLeft.dx + _anchorSize.width);
    });

    test('a menu wider than the room beside it stays inside the window', () {
      // A trigger hard against the left edge: a 340px menu hung off it would
      // run past the window, and clipped rows are unreadable rows.
      const leftAnchor = Offset(4, 650);

      final offset = anchoredMenuOffset(
        anchorTopLeft: leftAnchor,
        anchorSize: _anchorSize,
        overlaySize: _overlay,
        menuSize: const Size(340, 120),
        gap: 6,
        margin: 8,
        alignEnd: true,
        preferAbove: true,
      );

      expect(leftAnchor.dx + offset.dx, 8);
    });
  });
}
