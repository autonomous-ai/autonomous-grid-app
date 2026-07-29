import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
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
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
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
class ExtensionLoadingRows extends StatelessWidget {
  const ExtensionLoadingRows({super.key});

  @override
  Widget build(BuildContext context) {
    return const Align(
      alignment: Alignment.topCenter,
      child: SkeletonList(rows: 7),
    );
  }
}
