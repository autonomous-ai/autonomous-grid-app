import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/app_dialog.dart';
import '../../../shared/theme/app_theme.dart';
import 'model_manager_split.dart';

/// "Manage models" — the model hub that used to be its own tab: download a GGUF
/// and see every model already under `~/.grid/models`. Opened from the local
/// engine block. (Node setup / installing llama.cpp lives in the Engines tab.)
Future<void> showModelManager(BuildContext context) => showAppDialog<void>(
  context: context,
  // A download can be running in the background — an accidental tap outside
  // shouldn't dismiss the dialog. Only the Close/X button closes it.
  barrierDismissible: false,
  builder: (_) => const _ModelManagerDialog(),
);

class _ModelManagerDialog extends ConsumerWidget {
  const _ModelManagerDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);

    final screen = MediaQuery.sizeOf(context);
    final maxWidth = screen.width < 1100 ? screen.width - 96 : 980.0;
    final maxHeight = screen.height < 860 ? screen.height * 0.9 : 720.0;

    return Dialog(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            const _DialogHeader(),
            const SizedBox(height: 12),
            const Expanded(child: ModelManagerSplitView()),
          ],
        ),
      ),
    );
  }
}

/// Title + close. The downloaded/total count doesn't live here: it belongs
/// beside the models it counts, which is the storage strip at the foot of the
/// sidebar — and there it is a way in, not a statistic.
class _DialogHeader extends StatelessWidget {
  const _DialogHeader();

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(26, 22, 26, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Text(
              'Manage models',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            tooltip: 'Close',
            visualDensity: VisualDensity.compact,
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }
}
