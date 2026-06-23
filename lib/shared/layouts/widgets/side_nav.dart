import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../theme/app_theme.dart';
import '../shell_state.dart';

/// Left sidebar — the primary section switcher (Networks / Playground / …).
class SideNav extends ConsumerWidget {
  const SideNav({super.key});

  static const double width = 208;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(navSectionProvider);

    return Container(
      width: width,
      color: AppPalette.panelBg,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final section in NavSection.values)
            _NavItem(
              section: section,
              selected: section == active,
              onTap: () =>
                  ref.read(navSectionProvider.notifier).select(section),
            ),
        ],
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.section,
    required this.selected,
    required this.onTap,
  });

  final NavSection section;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppPalette.textPrimary : AppPalette.textSecondary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: selected ? AppPalette.cardBgHover : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            child: Row(
              children: [
                Icon(section.icon, size: 18, color: color),
                const SizedBox(width: 12),
                Text(section.label,
                    style: TextStyle(
                        color: color,
                        fontSize: 13.5,
                        fontWeight:
                            selected ? FontWeight.w600 : FontWeight.w500)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
