import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/models/managed_network.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_spinner.dart';
import '../../../shared/widgets/labeled_field.dart';
import '../../../shared/widgets/toast.dart';
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
            const FieldLabel('Type'),
            _TypePicker(
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
              _ErrorBanner(message: error),
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

/// The grid's visibility, as a two-way segmented control.
///
/// It was a dropdown, which is the wrong instrument for two options: it costs a
/// click, a menu, a read and a second click to flip what is really a switch —
/// and until that first click it *hides* the other choice, so you couldn't tell
/// a private grid was even possible. Laid out flat, both options are readable
/// before you touch anything, and picking one is a single click.
///
/// It also stopped a dropdown from wearing [InputDecoration], the recipe for a
/// box you *type* in. That's why it read as a disabled text field: same fill,
/// same rim, no affordance saying it opens.
///
/// A recessed groove with the picked cell lifted in accent — the app's segmented
/// control, built here rather than shared: this dialog is 380px wide with two
/// glyph-less cells, which is nothing like the narrow, glyph-stacked cells the
/// pattern came from.
class _TypePicker extends StatelessWidget {
  const _TypePicker({
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final ManagedNetworkType value;
  final bool enabled;
  final ValueChanged<ManagedNetworkType> onChanged;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppSurface.recess,
          borderRadius: BorderRadius.circular(AppControl.radius + 2),
        ),
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: Row(
            children: [
              for (final type in ManagedNetworkType.values)
                Expanded(
                  child: _TypeSegment(
                    label: type.label,
                    selected: type == value,
                    onTap: enabled ? () => onChanged(type) : null,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One cell of [_TypePicker].
class _TypeSegment extends StatelessWidget {
  const _TypeSegment({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final foreground = selected ? Colors.white : AppPalette.textSecondary;
    return Material(
      color: selected ? AppPalette.accent : Colors.transparent,
      borderRadius: BorderRadius.circular(AppControl.radius),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppControl.radius),
        onTap: onTap,
        child: SizedBox(
          height: AppControl.height,
          child: Center(
            child: Text(
              label,
              maxLines: 1,
              style: TextStyle(
                fontFamily: AppFont.sans,
                fontFamilyFallback: AppFont.sansFallback,
                fontSize: AppControl.fontSize,
                fontWeight: FontWeight.w600,
                color: foreground,
              ),
            ),
          ),
        ),
      ),
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
            child: Text(
              message,
              style: TextStyle(color: color, fontSize: 12.5),
            ),
          ),
        ],
      ),
    );
  }
}
