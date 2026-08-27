import 'package:flutter/material.dart';

import '../../../../shared/theme/app_theme.dart';

/// The box that narrows a long grid list, with the count it has narrowed it to.
///
/// The count is the half that earns this control's height. A search box on its
/// own tells you nothing until you type; "12 grids" says how much list there is
/// before you decide whether to search it at all, and "3 of 12" afterwards says
/// how much of it you are still looking at.
class GridSearchField extends StatelessWidget {
  const GridSearchField({
    super.key,
    required this.controller,
    required this.countLabel,
    required this.onChanged,
  });

  final TextEditingController controller;
  final String countLabel;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 11),
      decoration: BoxDecoration(
        color: AppPalette.panelBg,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: AppPalette.divider),
      ),
      child: Row(
        children: [
          Icon(Icons.search, size: 15, color: AppPalette.textSecondary),
          const SizedBox(width: 9),
          Expanded(
            child: TextField(
              controller: controller,
              onChanged: onChanged,
              style: theme.textTheme.bodyMedium?.copyWith(fontSize: 13.5),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                contentPadding: EdgeInsets.zero,
                hintText: 'Search grids',
                hintStyle: theme.textTheme.bodyMedium?.copyWith(
                  fontSize: 13.5,
                  color: AppPalette.textFaint,
                ),
              ),
            ),
          ),
          const SizedBox(width: 9),
          Text(
            countLabel,
            style: theme.textTheme.labelSmall?.copyWith(
              fontSize: 11.5,
              fontWeight: AppFont.semibold,
              color: AppPalette.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}
