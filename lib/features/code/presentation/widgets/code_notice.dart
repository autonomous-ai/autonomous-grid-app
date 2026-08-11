import 'package:flutter/material.dart';

import '../../../../shared/theme/app_theme.dart';

/// One quiet line explaining why something here may not go the way the user
/// expects — nobody online to take the work, a task slot already taken.
///
/// Not an error box: nothing has failed, and dressing "your work may wait" in
/// error red would train people to ignore the box that means something broke.
/// Only ever rendered when there is genuinely something to say.
class CodeNotice extends StatelessWidget {
  const CodeNotice({
    super.key,
    required this.message,
    this.icon = Icons.info_outline_rounded,
    this.trailing,
  });

  final String message;
  final IconData icon;

  /// An action beside it — "Open it" on the task holding the slot.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 15, color: AppPalette.warn),
        const SizedBox(width: 9),
        Expanded(
          child: Text(
            message,
            style: TextStyle(
              fontSize: 12.5,
              height: 1.4,
              color: AppPalette.textSecondary,
            ),
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 8), trailing!],
      ],
    );
  }
}
