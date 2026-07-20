import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/app_spinner.dart';
import '../logic/auto_router_controller.dart';
import '../logic/auto_router_models.dart';

/// Opens the advisor picker and returns the chosen `provider:model` tokens in
/// priority order, or null if the user cancelled. [current] pre-checks the
/// advisors already on the chain.
Future<List<String>?> showAdvisorPicker(
  BuildContext context,
  WidgetRef ref, {
  required List<String> current,
}) => showDialog<List<String>>(
  context: context,
  builder: (_) => _AdvisorPickerDialog(initial: current),
);

/// Picks up to [kMaxAdvisors] advisors from the platform catalog. Selection is
/// order-preserving — the first checked is the highest priority — matching how
/// the CLI reads the chain.
class _AdvisorPickerDialog extends ConsumerStatefulWidget {
  const _AdvisorPickerDialog({required this.initial});

  final List<String> initial;

  @override
  ConsumerState<_AdvisorPickerDialog> createState() =>
      _AdvisorPickerDialogState();
}

class _AdvisorPickerDialogState extends ConsumerState<_AdvisorPickerDialog> {
  late final List<String> _selected = [...widget.initial];

  void _toggle(String token, bool on) {
    setState(() {
      if (on) {
        if (_selected.length < kMaxAdvisors) _selected.add(token);
      } else {
        _selected.remove(token);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final catalog = ref.watch(advisorCatalogProvider);
    return AlertDialog(
      title: const Text('Choose advisors'),
      content: SizedBox(
        width: 400,
        height: 420,
        child: catalog.when(
          data: _list,
          error: (error, _) => Text('$error'),
          loading: () => const Center(child: AppSpinner()),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _selected.isEmpty
              ? null
              : () => Navigator.of(context).pop(_selected),
          child: const Text('Save'),
        ),
      ],
    );
  }

  Widget _list(AdvisorCatalog catalog) {
    final theme = Theme.of(context);
    final tokens = catalog.allTokens;
    if (tokens.isEmpty) {
      return const Center(child: Text('No advisors are available right now.'));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'An advisor is a cloud AI that reads each request and picks which of '
          'your grid’s own models should answer it — it only decides, your '
          'models still do the work. Pick up to $kMaxAdvisors; the first is '
          'tried first.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: ListView(
            children: [
              for (final token in tokens)
                CheckboxListTile(
                  value: _selected.contains(token),
                  // At the cap, unchecked rows disable so the limit is obvious.
                  onChanged:
                      _selected.length >= kMaxAdvisors &&
                          !_selected.contains(token)
                      ? null
                      : (value) => _toggle(token, value ?? false),
                  title: Text(token, style: theme.textTheme.bodyMedium),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                ),
            ],
          ),
        ),
      ],
    );
  }
}
