/// The type-a-code form. The only way in, until there is a camera flow.
///
/// Twenty characters, and everything else about reaching a computer is worked
/// out from them — so this screen asks for one thing and explains where to find
/// it, rather than asking for an address somebody would have to be told.
library;

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grid_theme/grid_theme.dart';

import 'package:grid_pairing/grid_pairing.dart';

import '../logic/phone_link_controller.dart';

/// Takes a code and hands it to the controller.
class PairForm extends ConsumerStatefulWidget {
  const PairForm({super.key, this.problem});

  /// What went wrong last time, if anything.
  final String? problem;

  @override
  ConsumerState<PairForm> createState() => _PairFormState();
}

class _PairFormState extends ConsumerState<PairForm> {
  final _field = TextEditingController();

  /// The code typed so far, once it is a whole one.
  ///
  /// Held rather than recomputed in `build` so the button's enabled state and
  /// what gets submitted are the same value — a button that is enabled by one
  /// check and submits through another is how a code that looks fine gets
  /// refused.
  PairToken? _typed;

  @override
  void initState() {
    super.initState();
    _field.addListener(
      () => setState(() => _typed = PairToken.tryParse(_field.text)),
    );
  }

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  /// Takes a code off the clipboard, from either shape a person may have copied.
  Future<void> _paste() async {
    final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
    final text = clipboard?.text;
    if (text == null || text.trim().isEmpty) return;
    final token = PairToken.tryParse(pairTokenTextOf(text));
    _field.text = token?.pretty ?? text.trim();
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
          'Open Grid on your computer, go to Settings ▸ Phone, and add this '
          'phone. It shows a code — type it here.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: AppPalette.textSecondary,
          ),
        ),
        const SizedBox(height: 20),
        TextField(
          controller: _field,
          autocorrect: false,
          enableSuggestions: false,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          // The code has no lower case and no punctuation but the dashes this
          // adds, so the keyboard is told as much and the field corrects the
          // rest. A person reading `0` off a screen and typing `O` is the
          // mistake this closes, rather than reporting.
          inputFormatters: const [_CodeFormatter()],
          // Mono because this is a string being *copied*, not read — the rule
          // the style guide draws the line on. Via AppFont, since the literal
          // 'Menlo' skips the real SF Mono this app resolves to.
          style: theme.textTheme.bodySmall?.copyWith(
            fontFamily: AppFont.mono,
            fontFamilyFallback: AppFont.monoFallback,
          ),
          decoration: InputDecoration(
            hintText: 'XXXX-XXXX-XXXX-XXXX-XXXX',
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
          onPressed: _typed == null
              ? null
              : () => ref
                    .read(phoneLinkProvider.notifier)
                    .pair(_typed!.normalized),
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

/// Keeps the field showing a code and nothing else.
///
/// Upper case, the two lookalike characters folded the way the alphabet says,
/// everything else dropped, and a dash every four so twenty characters can be
/// checked against the screen they were read from. Twenty is a hard stop: a
/// twenty-first character means something was typed twice, and silently
/// truncating would submit a code nobody typed.
class _CodeFormatter extends TextInputFormatter {
  const _CodeFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final kept = StringBuffer();
    for (final ch in newValue.text.toUpperCase().split('')) {
      if (kept.length == kPairTokenLength) break;
      final fixed = switch (ch) {
        'O' => '0',
        'I' || 'L' => '1',
        _ => ch,
      };
      if (kPairTokenAlphabet.contains(fixed)) kept.write(fixed);
    }
    final code = kept.toString();
    final groups = <String>[];
    for (var i = 0; i < code.length; i += 4) {
      groups.add(code.substring(i, min(i + 4, code.length)));
    }
    final text = groups.join('-');
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}
