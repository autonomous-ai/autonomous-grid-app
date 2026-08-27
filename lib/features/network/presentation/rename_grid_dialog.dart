import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/app_dialog.dart';
import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_spinner.dart';
import '../../../shared/widgets/error_box.dart';
import '../../../shared/widgets/labeled_field.dart';
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
    return showAppDialog<void>(
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

  /// Held so the selection can be (re)applied the moment the field takes focus.
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    // Select the whole name, so the first keystroke replaces it — Finder's
    // rename, where you type over the old name rather than clearing it
    // yourself. Otherwise an autofocused field just parks the caret at one end
    // and makes you backspace through a name you already decided to throw away.
    //
    // On the focus event, not at construction: `autofocus` sets its own
    // selection when the field first takes focus, which lands *after* the
    // controller is built and quietly replaces anything set there. (A widget
    // test doesn't catch this — it reports the constructed selection surviving,
    // because the headless binding never runs the platform's focus handoff.)
    _focus.addListener(_selectAllOnFocus);
  }

  void _selectAllOnFocus() {
    if (!_focus.hasFocus) return;
    _focus.removeListener(_selectAllOnFocus);
    _name.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _name.text.length,
    );
  }

  @override
  void dispose() {
    _focus.dispose();
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
            const FieldLabel('Grid name'),
            TextField(
              controller: _name,
              focusNode: _focus,
              autofocus: true,
              enabled: !saving,
              maxLength: gridNameMaxLength,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
              style: kFieldTextStyle,
              decoration: const InputDecoration(counterText: ''),
            ),
            const SizedBox(height: 8),
            Text(
              'Only the name changes. Everyone on this grid keeps their '
              'access, and apps you connected keep working.',
              // The same note style as the Type description on
              // [CreateNetworkDialog] — `bodySmall` carries the text theme's
              // own colour, which is not [AppPalette.textSecondary], so the two
              // dialogs' explanatory lines sat at different weights of grey.
              style: TextStyle(
                color: AppPalette.textSecondary,
                fontSize: 12,
                height: 1.35,
              ),
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
          // Ink, not accent — the accent belongs to Save alone. See the same
          // note on [CreateNetworkDialog].
          style: TextButton.styleFrom(
            foregroundColor: AppPalette.textSecondary,
          ),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: saving ? null : _submit,
          child: saving ? const AppSpinner.onAccent() : const Text('Save'),
        ),
      ],
    );
  }
}
