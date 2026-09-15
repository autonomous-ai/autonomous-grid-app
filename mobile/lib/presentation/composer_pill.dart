/// One of the composer's pickers, and the sheet it opens.
///
/// One widget for all three — model, assistant, access — because they are the
/// same control over different lists. On the desktop these are three separate
/// pickers that have to be kept looking alike by hand; there is no reason to
/// repeat that here.
library;

import 'package:flutter/material.dart';

import '../logic/phone_chat_options.dart';

/// A tappable pill showing what is picked.
class ComposerPill extends StatelessWidget {
  const ComposerPill({
    required this.icon,
    required this.title,
    required this.picker,
    required this.onPick,
    this.enabled = true,
    super.key,
  });

  /// What it is, at a glance.
  final IconData icon;

  /// What the sheet is called — also what the pill falls back to when nothing
  /// is picked yet.
  final String title;

  /// What is chosen and what else there is.
  final Picker picker;

  /// Called with the id of whatever was chosen.
  final ValueChanged<String> onPick;

  /// False while the link is down, so a pill cannot open a sheet whose picks
  /// would all fail.
  final bool enabled;

  String get _label {
    for (final option in picker.options) {
      if (option.id == picker.selected) return option.label;
    }
    return picker.selected.isEmpty ? title : picker.selected;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: enabled ? () => _open(context) : null,
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 6, 8, 6),
        decoration: BoxDecoration(
          border: Border.all(color: theme.dividerColor),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: theme.textTheme.bodySmall?.color),
            const SizedBox(width: 6),
            // Flexible, not fixed: a model id can be long and three pills share
            // one phone-width row, so each has to be able to give way.
            Flexible(
              child: Text(
                _label,
                style: theme.textTheme.bodySmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Icon(
              Icons.expand_more,
              size: 14,
              color: theme.textTheme.bodySmall?.color,
            ),
          ],
        ),
      ),
    );
  }

  void _open(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => _PickSheet(
        title: title,
        picker: picker,
        onPick: (id) {
          Navigator.of(sheetContext).pop();
          onPick(id);
        },
      ),
    );
  }
}

/// The list of choices.
class _PickSheet extends StatelessWidget {
  const _PickSheet({
    required this.title,
    required this.picker,
    required this.onPick,
  });

  final String title;
  final Picker picker;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.7,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(title, style: theme.textTheme.titleMedium),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: picker.options.length,
                itemBuilder: (context, index) {
                  final option = picker.options[index];
                  return ListTile(
                    enabled: option.enabled,
                    leading: Icon(
                      option.id == picker.selected
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      size: 20,
                    ),
                    title: Text(option.label),
                    // The reason sits under the row it disables. A greyed row
                    // with no explanation is the thing people tap twice and
                    // then decide the app is broken.
                    subtitle: option.why.isEmpty ? null : Text(option.why),
                    onTap: () => onPick(option.id),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
