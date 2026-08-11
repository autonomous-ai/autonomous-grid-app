import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_theme.dart';
import '../logic/model_pull_controller.dart';

/// The way out of a running download.
///
/// Stopping is not cosmetic here: a model is gigabytes over someone's home
/// connection, and the only alternative to this button is quitting the app. The
/// controller's `cancel` tears down the stream, which SIGTERMs `grid pull`, so
/// the transfer really stops instead of finishing unseen in the background.
///
/// One widget shared by the download row and the model detail panel, so the two
/// places that offer this cannot drift apart in wording or in weight — a "Stop"
/// on one screen and a "Cancel" on the other read as two different actions.
class CancelDownloadButton extends ConsumerWidget {
  const CancelDownloadButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return TextButton(
      onPressed: () => ref.read(modelPullControllerProvider.notifier).cancel(),
      style: TextButton.styleFrom(
        minimumSize: const Size(0, AppControl.heightSmall),
        padding: AppControl.paddingSmall,
        // The error colour marks it as the destructive way out of a running
        // download.
        foregroundColor: Theme.of(context).colorScheme.error,
      ),
      child: const Text('Cancel'),
    );
  }
}
