import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/models/managed_network.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_spinner.dart';
import '../../../shared/widgets/error_box.dart';
import '../../../shared/widgets/labeled_field.dart';
import '../../../shared/widgets/toast.dart';
import '../logic/create_network_controller.dart';
import 'grid_type_picker.dart';

/// Modal to create a managed (hosted) grid via the control-plane API.
/// Open with [CreateNetworkDialog.show].
class CreateNetworkDialog extends ConsumerStatefulWidget {
  const CreateNetworkDialog({super.key});

  static Future<void> show(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (_) => const CreateNetworkDialog(),
    );
  }

  @override
  ConsumerState<CreateNetworkDialog> createState() =>
      _CreateNetworkDialogState();
}

class _CreateNetworkDialogState extends ConsumerState<CreateNetworkDialog> {
  final _name = TextEditingController();
  ManagedNetworkType _type = ManagedNetworkType.fallback;

  @override
  void initState() {
    super.initState();
    // Drop any state from a previous open so we start on the form.
    Future.microtask(
      () => ref.read(createNetworkControllerProvider.notifier).reset(),
    );
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    ref
        .read(createNetworkControllerProvider.notifier)
        .submit(name: _name.text, type: _type);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(createNetworkControllerProvider, (_, next) {
      if (next is! CreateNetworkDone) return;
      // Grab the host *before* popping: this context is the dialog's, and once
      // it's gone `ToastScope.of` can no longer walk up to find the scope.
      final toast = ToastScope.of(context);
      Navigator.of(context).pop();
      final warning = next.joinWarning;
      // The grid was created either way — a warning is a caveat on a success,
      // not a failure.
      toast?.show(
        warning != null
            ? ToastSpec(message: warning, severity: ToastSeverity.warning)
            : ToastSpec(
                message: 'Grid “${next.network.name}” created.',
                severity: ToastSeverity.success,
              ),
      );
    });

    final state = ref.watch(createNetworkControllerProvider);
    final submitting = state is CreateNetworkSubmitting;
    final error = state is CreateNetworkFailed ? state.message : null;

    return AlertDialog(
      title: const Text('Create grid'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const FieldLabel('Name'),
            TextField(
              controller: _name,
              autofocus: true,
              enabled: !submitting,
              maxLength: 64,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
              style: kFieldTextStyle,
              decoration: const InputDecoration(
                hintText: 'my-team-grid',
                counterText: '',
              ),
            ),
            const SizedBox(height: 14),
            // "Who can join", not "Type": the same question the first-run
            // screen asks, in the same words (§5). They already share the
            // picker; a label of their own is exactly how two screens start
            // asking one question two ways. "Type" also named nothing — the
            // answer to "type of what?" was only in the line underneath.
            const FieldLabel('Who can join'),
            GridTypePicker(
              value: _type,
              enabled: !submitting,
              onChanged: (value) => setState(() => _type = value),
            ),
            const SizedBox(height: 8),
            Text(
              _type.description,
              style: TextStyle(
                color: AppPalette.textSecondary,
                fontSize: 12,
                height: 1.35,
              ),
            ),
            if (error != null) ...[
              const SizedBox(height: 14),
              ErrorBox(message: error),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: submitting ? null : () => Navigator.of(context).pop(),
          // Ink, not accent. Cancel is the way out, not a suggestion — the
          // accent belongs to Create alone, and two blue words in one corner
          // give the dialog two things that look like the answer.
          style: TextButton.styleFrom(
            foregroundColor: AppPalette.textSecondary,
          ),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: submitting ? null : _submit,
          child: submitting
              ? const AppSpinner.onAccent()
              : const Text('Create'),
        ),
      ],
    );
  }
}
