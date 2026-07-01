import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_info.dart';
import '../../theme/app_theme.dart';
import '../../widgets/glass_surface.dart';
import '../shell_state.dart';

/// Left sidebar — the primary section switcher (Networks / Playground / …).
class SideNav extends ConsumerWidget {
  const SideNav({super.key});

  static const double width = 208;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(navSectionProvider);
    final sections = ref.watch(visibleNavSectionsProvider);

    return SizedBox(
      width: width,
      child: GlassSurface(
        borderRadius: BorderRadius.circular(20),
        boxShadow: AppGlass.shadow,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final section in sections)
              _NavItem(
                section: section,
                selected: section == active,
                onTap: () =>
                    ref.read(navSectionProvider.notifier).select(section),
              ),
            const Spacer(),
            const _VersionFooter(),
          ],
        ),
      ),
    );
  }
}

/// App version pinned to the bottom of the sidebar — quiet, for support/QA.
class _VersionFooter extends ConsumerWidget {
  const _VersionFooter();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final version = ref.watch(appVersionProvider).asData?.value;
    if (version == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(left: 10, top: 8, bottom: 2),
      child: Text('v$version',
          style: const TextStyle(color: AppPalette.textFaint, fontSize: 11.5)),
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
    const radius = BorderRadius.all(Radius.circular(10));
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      // Selected item reads as a lit glass pill on the frosted panel; unselected
      // stays transparent so only the active section catches the light.
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          color: selected ? AppGlass.selected : Colors.transparent,
          border:
              selected ? Border.all(color: AppGlass.selectedBorder) : null,
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: radius,
          child: InkWell(
            borderRadius: radius,
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
      ),
    );
  }
}
