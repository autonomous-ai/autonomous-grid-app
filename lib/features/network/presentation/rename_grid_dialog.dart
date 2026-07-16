import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/widgets/app_spinner.dart';
import '../../../shared/widgets/error_box.dart';
import '../../../shared/widgets/toast.dart';
import '../logic/grid_name.dart';
import '../logic/rename_network_controller.dart';

/// Modal to rename a grid you own. Open with [RenameGridDialog.show]; it saves
/// via the control plane, refreshes the local grid list, and closes itself.
///
/// Renaming only changes the name people see — the grid keeps working for
/// everyone already on it, which the dialog says out loud so nobody fears
/// breaking their setup.
class RenameGridDialog extends ConsumerStatefulWidget {
  const RenameGridDialog({super.key, required this.network});

  final NetworkCredential network;

  /// Opens the dialog on a clean slate: the controller outlives it, so a failure
  /// from a previous attempt would otherwise greet the user on reopen. Resetting
  /// here (from the button's callback) keeps it out of a widget life-cycle,
  /// where Riverpod forbids mutating a provider.
  static Future<void> show(
    BuildContext context,
    WidgetRef ref,
    NetworkCredential network,
  ) {
    ref.read(renameNetworkControllerProvider.notifier).reset();
    return showDialog<void>(
      context: context,
      builder: (_) => RenameGridDialog(network: network),
    );
  }

  @override
  ConsumerState<RenameGridDialog> createState() => _RenameGridDialogState();
}

class _RenameGridDialogState extends ConsumerState<RenameGridDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.network.name,
  );

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _name.text.trim();
    if (name == widget.network.name) {
      Navigator.of(context).pop();
      return;
    }

    final error = await ref
        .read(renameNetworkControllerProvider.notifier)
        .rename(networkId: widget.network.networkId, name: name);

    if (!mounted || error != null) return;
    // Grab the host before popping — once this dialog's context is deactivated
    // it can no longer walk up to find the scope.
    final toast = ToastScope.of(context);
    Navigator.of(context).pop();
    toast?.show(
      ToastSpec(
        message: 'Renamed to "$name".',
        severity: ToastSeverity.success,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(renameNetworkControllerProvider);
    final saving = state is RenameNetworkSaving;
    final error = state is RenameNetworkFailed ? state.message : null;

    return AlertDialog(
      title: const Text('Rename grid'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              enabled: !saving,
              maxLength: gridNameMaxLength,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
              decoration: const InputDecoration(
                labelText: 'Grid name',
                counterText: '',
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Only the name changes. Everyone on this grid keeps their '
              'access, and apps you connected keep working.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (error != null) ...[
              const SizedBox(height: 14),
              ErrorBox(message: error, maxHeight: 120),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: saving ? null : _submit,
          child: saving
              ? const AppSpinner.onAccent()
              : const Text('Save'),
        ),
      ],
    );
  }
}
