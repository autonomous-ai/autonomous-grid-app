import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../logic/plugins_controller.dart';

/// Adds a plugin from a Git repository — the one way new plugins arrive.
///
/// Says plainly what it's about to do (download and run someone else's code), so
/// a user pasting a link from the internet knows what they're agreeing to.
Future<void> showAddPluginDialog(BuildContext context) => showDialog<void>(
  context: context,
  builder: (_) => const _AddPluginDialog(),
);

class _AddPluginDialog extends ConsumerStatefulWidget {
  const _AddPluginDialog();

  @override
  ConsumerState<_AddPluginDialog> createState() => _AddPluginDialogState();
}

class _AddPluginDialogState extends ConsumerState<_AddPluginDialog> {
  final _identifier = TextEditingController();
  bool _installing = false;

  @override
  void dispose() {
    _identifier.dispose();
    super.dispose();
  }

  Future<void> _install() async {
    setState(() => _installing = true);
    final error = await ref
        .read(pluginsProvider.notifier)
        .install(_identifier.text);
    if (!mounted) return;
    setState(() => _installing = false);
    final messenger = ScaffoldMessenger.of(context);
    if (error != null) {
      messenger.showSnackBar(SnackBar(content: Text(error)));
      return;
    }
    Navigator.of(context).pop();
    messenger.showSnackBar(
      const SnackBar(content: Text('Plugin installed and turned on.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add a plugin'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _identifier,
              autofocus: true,
              enabled: !_installing,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Git repository',
                hintText: 'owner/repo, or a full https://… link',
              ),
            ),
            const SizedBox(height: 14),
            const Text(
              'This downloads the repository onto this computer and lets the '
              "assistant run it. Only add plugins from people you trust.",
              style: TextStyle(fontSize: 12.5, color: AppPalette.textSecondary),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _installing ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _identifier.text.trim().isEmpty || _installing
              ? null
              : _install,
          child: Text(_installing ? 'Installing…' : 'Install'),
        ),
      ],
    );
  }
}
