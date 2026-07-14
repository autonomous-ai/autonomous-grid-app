import 'package:flutter/material.dart';

import '../../../../shared/widgets/pill_choice.dart';

/// A compact segmented pill for the Plugins screen.
class PluginPillChoice extends StatelessWidget {
  const PluginPillChoice({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => PillChoice(
    label: Text(label),
    selected: selected,
    onTap: onTap,
    icon: icon,
  );
}
