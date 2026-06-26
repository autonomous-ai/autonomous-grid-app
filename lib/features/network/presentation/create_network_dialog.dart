import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/models/managed_network.dart';
import '../../../shared/theme/app_theme.dart';
import '../logic/create_network_controller.dart';

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
        () => ref.read(createNetworkControllerProvider.notifier).reset());
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
      Navigator.of(context).pop();
      final warning = next.joinWarning;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(warning ?? 'Grid “${next.network.name}” created.'),
        duration: const Duration(seconds: 3),
      ));
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
            TextField(
              controller: _name,
              autofocus: true,
              enabled: !submitting,
              maxLength: 64,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
              decoration: const InputDecoration(
                labelText: 'Name',
                hintText: 'my-team-grid',
                counterText: '',
              ),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<ManagedNetworkType>(
              initialValue: _type,
              decoration: const InputDecoration(labelText: 'Type'),
              onChanged: submitting
                  ? null
                  : (value) => setState(() => _type = value ?? _type),
              items: [
                for (final type in ManagedNetworkType.values)
                  DropdownMenuItem(value: type, child: Text(type.label)),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              _type.description,
              style: const TextStyle(
                  color: AppPalette.textSecondary, fontSize: 12),
            ),
            if (error != null) ...[
              const SizedBox(height: 14),
              _ErrorBanner(message: error),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: submitting ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: submitting ? null : _submit,
          child: submitting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Create'),
        ),
      ],
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.error;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(message,
                style: TextStyle(color: color, fontSize: 12.5)),
          ),
        ],
      ),
    );
  }
}
