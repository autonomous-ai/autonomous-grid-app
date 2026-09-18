/// Naming a new project.
///
/// A sheet rather than a screen: it asks one question. The answer is a *name* —
/// the phone never names a folder, because it has no view of the computer's
/// disk and should not be able to create one anywhere on it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grid_theme/grid_theme.dart';

import '../logic/phone_chat_options.dart';
import '../logic/relay_phone_client.dart';

/// Asks for a name and starts the project.
Future<void> showNewProjectSheet(BuildContext context) => showModalBottomSheet(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (_) => const _NewProjectSheet(),
);

class _NewProjectSheet extends ConsumerStatefulWidget {
  const _NewProjectSheet();

  @override
  ConsumerState<_NewProjectSheet> createState() => _NewProjectSheetState();
}

class _NewProjectSheetState extends ConsumerState<_NewProjectSheet> {
  final _name = TextEditingController();
  bool _starting = false;
  String? _problem;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    if (_name.text.trim().isEmpty || _starting) return;
    setState(() {
      _starting = true;
      _problem = null;
    });
    try {
      await startProject(ref, _name.text);
      if (mounted) Navigator.of(context).pop();
    } on RelayPhoneFailure catch (failure) {
      if (!mounted) return;
      setState(() {
        _starting = false;
        _problem = failure.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    final radius = BorderRadius.circular(AppCard.radius);
    return Padding(
      // Lifts the sheet clear of the keyboard it summons.
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('New project', style: theme.textTheme.titleSmall),
              const SizedBox(height: 12),
              TextField(
                controller: _name,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                style: theme.textTheme.bodyMedium,
                onSubmitted: (_) => _start(),
                decoration: InputDecoration(
                  hintText: 'What is it called?',
                  hintStyle: theme.textTheme.bodyMedium?.copyWith(
                    color: AppPalette.textFaint,
                  ),
                  filled: true,
                  fillColor: AppPalette.cardBg,
                  contentPadding: const EdgeInsets.all(14),
                  border: OutlineInputBorder(
                    borderRadius: radius,
                    borderSide: BorderSide(color: AppGlass.hair),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: radius,
                    borderSide: BorderSide(color: AppGlass.hair),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: radius,
                    borderSide: BorderSide(color: AppPalette.accentOnSurface),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              // Said out loud rather than left to be discovered. A folder made
              // on somebody's computer from a phone is not a thing to be quiet
              // about, and they have to know where to look for it.
              Text(
                'Your computer makes a folder for it in your home folder, '
                'under Grid.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppPalette.textFaint,
                ),
              ),
              if (_problem case final problem?) ...[
                const SizedBox(height: 12),
                Text(
                  problem,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppPalette.dangerFill,
                  ),
                ),
              ],
              const SizedBox(height: 16),
              FilledButton(
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(46),
                ),
                onPressed: _starting ? null : _start,
                child: Text(_starting ? 'Starting…' : 'Create project'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
