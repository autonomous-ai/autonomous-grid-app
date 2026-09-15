/// The paste-a-code form. The only way in, until there is a camera flow.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../logic/phone_link_controller.dart';

/// Takes a pairing code and hands it to the controller.
class PairForm extends ConsumerStatefulWidget {
  const PairForm({super.key, this.problem});

  /// What went wrong last time, if anything.
  final String? problem;

  @override
  ConsumerState<PairForm> createState() => _PairFormState();
}

class _PairFormState extends ConsumerState<PairForm> {
  final _field = TextEditingController();
  var _canSubmit = false;

  @override
  void initState() {
    super.initState();
    _field.addListener(
      () => setState(() => _canSubmit = _field.text.trim().isNotEmpty),
    );
  }

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
    final text = clipboard?.text?.trim();
    if (text == null || text.isEmpty) return;
    _field.text = text;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Connect to your computer', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 8),
        Text(
          'Open Grid on your computer and it will show a pairing code. '
          'Paste the whole line here.',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 20),
        TextField(
          controller: _field,
          minLines: 2,
          maxLines: 4,
          autocorrect: false,
          enableSuggestions: false,
          style: const TextStyle(fontFamily: 'Menlo', fontSize: 12),
          decoration: InputDecoration(
            hintText: 'grid://pair?code=...',
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              tooltip: 'Paste',
              onPressed: _paste,
              icon: const Icon(Icons.content_paste),
            ),
          ),
        ),
        if (widget.problem case final problem?) ...[
          const SizedBox(height: 16),
          _Problem(problem),
        ],
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _canSubmit
              ? () => ref.read(phoneLinkProvider.notifier).pair(_field.text)
              : null,
          child: const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('Connect'),
          ),
        ),
      ],
    );
  }
}

class _Problem extends StatelessWidget {
  const _Problem(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, size: 18, color: scheme.onErrorContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: scheme.onErrorContainer, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}
