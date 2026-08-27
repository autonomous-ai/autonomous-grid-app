import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'app_icon_button.dart';
import 'extension_list.dart';
import 'extension_tile_surface.dart';
import 'skeleton.dart';

/// The raised search capsule the extension screens share — same surface and
/// radius as the rows it filters, so the toolbar and the list read as one
/// system.
class ExtensionSearchField extends StatelessWidget {
  const ExtensionSearchField({
    super.key,
    required this.controller,
    required this.hintText,
    required this.onChanged,
  });

  final TextEditingController controller;
  final String hintText;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // follow theme flips — reads AppGlass tokens.
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppGlass.surfaceFill,
        borderRadius: BorderRadius.circular(14),
        boxShadow: AppGlass.cardShadow,
      ),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          filled: false,
          hintText: hintText,
          prefixIcon: const Icon(Icons.search_rounded, size: 18),
          // Only while there is something to clear. A ✕ sitting on an empty
          // field is a control that does nothing, and on a row of quiet icons
          // it reads as one more thing to work out.
          //
          // `ValueListenableBuilder` rather than making this stateful: the
          // controller is already a `ValueNotifier`, so this rebuilds the icon
          // and nothing else on every keystroke.
          suffixIcon: ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, value, _) => value.text.isEmpty
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: AppIconButton(
                      icon: Icons.close_rounded,
                      tooltip: 'Clear search',
                      onPressed: () {
                        controller.clear();
                        // The field's own `onChanged` does not fire for a
                        // programmatic clear, and every caller derives its list
                        // from that callback — without this the text goes and
                        // the results stay.
                        onChanged('');
                      },
                    ),
                  ),
          ),
          // Keeps the field from growing when the button appears: without a
          // bound, `suffixIcon` reserves the icon's own 48px minimum and the
          // search bar changes height on the first keystroke.
          suffixIconConstraints: const BoxConstraints(
            minWidth: 0,
            minHeight: 0,
          ),
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 12,
          ),
        ),
      ),
    );
  }
}

/// The 34px raised refresh square beside the search field.
class ExtensionRefreshButton extends StatelessWidget {
  const ExtensionRefreshButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // follow theme flips — reads AppGlass tokens.
    return Tooltip(
      message: 'Refresh',
      child: Material(
        color: AppGlass.surfaceFill,
        borderRadius: BorderRadius.circular(11),
        child: InkWell(
          borderRadius: BorderRadius.circular(11),
          onTap: onPressed,
          child: Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(11),
              boxShadow: AppGlass.cardShadow,
            ),
            child: const Icon(Icons.refresh_rounded, size: 17),
          ),
        ),
      ),
    );
  }
}

/// The screen's one primary action — accent fill, white ink, 34px, radius 11.
///
/// Each extension screen has exactly one way to add something, so this is a
/// plain button; the old three-way Create menu died with the tabs it served.
class ExtensionCreateButton extends StatelessWidget {
  const ExtensionCreateButton({
    super.key,
    required this.label,
    required this.onPressed,
  });

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // follow theme flips — reads AppPalette/AppGlass.
    return Material(
      color: AppPalette.accent,
      borderRadius: BorderRadius.circular(11),
      child: InkWell(
        borderRadius: BorderRadius.circular(11),
        onTap: onPressed,
        child: Container(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(11),
            boxShadow: AppGlass.cardShadow,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.add_rounded, size: 17, color: Colors.white),
              const SizedBox(width: 8),
              // A label, not the page's text — the rule `unselectableLabel`
              // applies to every Material button. This one is an `InkWell`, so
              // no `ButtonStyle` reaches it and it has to say so itself.
              SelectionContainer.disabled(
                child: Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The extension lists all load the same shape — an icon, a name, a line of
/// description — so they wait as rows rather than as a spinner: nothing jumps
/// when the real list lands.
///
/// "Nothing jumps" is the whole point, and it only holds if the placeholder is
/// the row's shape rather than a suggestion of it. A bare [SkeletonList] paints
/// unhoused grey bars on the page, so the raised cards *appear* on arrival —
/// exactly the shift a skeleton exists to prevent. So each placeholder wears the
/// real [ExtensionTileSurface] at its real padding, with a 30px mark well and two
/// lines where the name and the summary go, and the block keeps the list's own
/// 8px rhythm and right-hand scrollbar gutter.
class ExtensionLoadingRows extends StatelessWidget {
  const ExtensionLoadingRows({super.key, this.rows = 7});

  final int rows;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // reads AppGlass via the tile surface below.
    return ListView.separated(
      padding: const EdgeInsets.only(right: extensionScrollGutter),
      // Not interactive yet, and a placeholder that scrolls under the pointer
      // reads as content. It still lives in a ListView so it clips at the pane's
      // bottom edge the way the real list does.
      physics: const NeverScrollableScrollPhysics(),
      itemCount: rows,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      // Fading down the column says "more below" instead of ending at an
      // arbitrary row — the same trick `SkeletonList` uses.
      itemBuilder: (context, i) => Opacity(
        opacity: 1 - (i / rows) * 0.65,
        child: const ExtensionTileSurface(child: _LoadingRow()),
      ),
    );
  }
}

/// One placeholder row, laid out on the same grid as a real one: a 30px mark, a
/// 12px gap, then the name and summary lines.
class _LoadingRow extends StatelessWidget {
  const _LoadingRow();

  @override
  Widget build(BuildContext context) {
    return const Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Square with radius 10, matching `ExtensionIconBadge` — a circle here
        // would be the one piece of the row that moves when the data lands.
        Skeleton(width: 30, height: 30, radius: 10),
        SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // 13px title, 4px gap, 11px summary — the row's real metrics, so
              // the block is the height the loaded list will be.
              SkeletonLine(widthFactor: 0.28, height: 13),
              SizedBox(height: 6),
              SkeletonLine(widthFactor: 0.62, height: 11),
            ],
          ),
        ),
      ],
    );
  }
}
