/// The paste-a-code form. The only way in, until there is a camera flow.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grid_theme/grid_theme.dart';

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
    AppTheme.watch(context);
    final theme = Theme.of(context);
    final radius = BorderRadius.circular(AppCard.radius);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Connect to your computer', style: theme.textTheme.titleLarge),
        const SizedBox(height: 4),
        Text(
          'Open Grid on your computer and it will show a pairing code. '
          'Paste the whole line here.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: AppPalette.textSecondary,
          ),
        ),
        const SizedBox(height: 20),
        TextField(
          controller: _field,
          minLines: 2,
          maxLines: 4,
          autocorrect: false,
          enableSuggestions: false,
          // Mono because this is a string being *copied*, not read — the rule
          // the style guide draws the line on. Via AppFont, since the literal
          // 'Menlo' skips the real SF Mono this app resolves to.
          style: theme.textTheme.bodySmall?.copyWith(
            fontFamily: AppFont.mono,
            fontFamilyFallback: AppFont.monoFallback,
          ),
          decoration: InputDecoration(
            hintText: 'grid://pair?code=...',
            hintStyle: theme.textTheme.bodySmall?.copyWith(
              color: AppPalette.textFaint,
              fontFamily: AppFont.mono,
              fontFamilyFallback: AppFont.monoFallback,
            ),
            filled: true,
            fillColor: AppPalette.cardBg,
            contentPadding: const EdgeInsets.fromLTRB(14, 12, 4, 12),
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
            suffixIcon: IconButton(
              tooltip: 'Paste',
              onPressed: _paste,
              iconSize: 18,
              color: AppPalette.textSecondary,
              icon: const Icon(Icons.content_paste_rounded),
            ),
          ),
        ),
        if (widget.problem case final problem?) ...[
          const SizedBox(height: 16),
          _Problem(problem),
        ],
        const SizedBox(height: 20),
        FilledButton(
          // 46 rather than the shared 32: that height is a pointer target, and
          // this is the one button the whole app depends on being hit.
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(46)),
          onPressed: _canSubmit
              ? () => ref.read(phoneLinkProvider.notifier).pair(_field.text)
              : null,
          child: const Text('Connect'),
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
    AppTheme.watch(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
      decoration: BoxDecoration(
        // A quiet inset with a danger-coloured mark, not a slab of red: the
        // app separates surfaces with a rim, and a filled error block is the
        // densest thing on a screen that is mostly calm.
        color: AppCard.inset,
        borderRadius: BorderRadius.circular(AppCard.insetRadius),
        border: Border.all(color: AppCard.insetHair),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.error_outline_rounded,
            size: 17,
            color: AppPalette.dangerFill,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(message, style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}
