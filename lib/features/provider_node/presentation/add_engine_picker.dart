import 'package:flutter/material.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/pill_choice.dart';

/// The three ways to put a model on the grid from this computer.
///
/// They were all rendered open at once, stacked: the cloud form and the local
/// form together ran ~560px, about 46% of the idle page, and both asked to be
/// filled in before the user had decided which kind of engine they wanted. Two
/// open forms don't lead anywhere — they compete.
///
/// Splitting the decision ("which kind?") from the work ("fill this in") is what
/// this enum is for. It is a *display* choice only: engines still stack
/// additively on the machine's union (ADR 0010), so picking a tab here never
/// stops or replaces a running engine.
enum AddEngineKind {
  /// A hosted provider (OpenAI, or a Codex / ChatGPT seat) — no download.
  cloud,

  /// The built-in llama.cpp engine, serving a GGUF from `~/.grid/models`.
  local,

  /// An OpenAI-compatible server the user runs themselves (Ollama, llama-server).
  own;

  String get label => switch (this) {
    AddEngineKind.cloud => 'Cloud',
    AddEngineKind.local => 'This computer',
    AddEngineKind.own => 'Your own server',
  };

  IconData get icon => switch (this) {
    AddEngineKind.cloud => Icons.cloud_outlined,
    AddEngineKind.local => Icons.dns_outlined,
    AddEngineKind.own => Icons.computer_outlined,
  };

  /// The one-line "what this costs you" under the pills, so the trade is visible
  /// while choosing rather than only inside the form.
  String get hint => switch (this) {
    AddEngineKind.cloud =>
      'Runs on the provider’s hardware, billed to your own account. Nothing to '
          'download.',
    AddEngineKind.local =>
      'Runs on this computer with the built-in engine. Free, but needs a model '
          'downloaded here.',
    AddEngineKind.own =>
      'Point Grid at an engine you already run on this computer.',
  };
}

/// A pill's text, with an optional count after it.
///
/// The count rides inside the pill rather than as a floating dot, so it reads as
/// "this tab has 2 things" instead of an alert.
class _PillLabel extends StatelessWidget {
  const _PillLabel({required this.text, required this.selected, this.badge});

  final String text;
  final bool selected;
  final int? badge;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    if (badge == null || badge == 0) return Text(text);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(text),
        const SizedBox(width: 7),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(
            // No well on a selected pill: a translucent white one lightens the
            // accent ground to #5D7FEF, where white text falls to 3.65:1. Left
            // on the accent itself, white reads at 5.52:1.
            color: selected ? Colors.transparent : AppSurface.recess,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            '$badge',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: selected ? Colors.white : AppPalette.textSecondary,
            ),
          ),
        ),
      ],
    );
  }
}

/// The segmented chooser above the add-engine form.
///
/// [unavailable] marks a kind that can't be picked right now — today the
/// built-in local engine when another engine is already serving, since it can't
/// share the machine's identity (ADR 0007 D4). The pill stays visible and says
/// why rather than vanishing, so the option doesn't silently disappear from a
/// page the user is learning.
class AddEnginePicker extends StatelessWidget {
  const AddEnginePicker({
    super.key,
    required this.value,
    required this.onChanged,
    this.kinds = AddEngineKind.values,
    this.unavailable = const {},
    this.badges = const {},
  });

  final AddEngineKind value;
  final ValueChanged<AddEngineKind> onChanged;

  /// Which kinds this platform offers at all. Windows has no built-in engine
  /// yet, so it passes a list without [AddEngineKind.local].
  final List<AddEngineKind> kinds;

  /// Kinds shown but not selectable, mapped to the reason.
  final Map<AddEngineKind, String> unavailable;

  /// A count to show on a pill — today the engines already detected running on
  /// this computer.
  ///
  /// Without it, folding the three paths behind a chooser hides a fact the
  /// stacked layout showed for free: a running Ollama used to appear on the page
  /// whether or not you went looking. A user who never opens "Your own server"
  /// would never learn it was there.
  final Map<AddEngineKind, int> badges;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final blocked = unavailable[value];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final kind in kinds)
              Opacity(
                opacity: unavailable.containsKey(kind) ? 0.5 : 1,
                child: PillChoice(
                  label: _PillLabel(
                    text: kind.label,
                    badge: badges[kind],
                    selected: kind == value,
                  ),
                  icon: kind.icon,
                  selected: kind == value,
                  onTap: () => onChanged(kind),
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          // A blocked kind explains itself instead of describing a path that
          // isn't open.
          blocked ?? value.hint,
          style: TextStyle(
            fontSize: 12.5,
            height: 1.35,
            color: blocked != null ? AppPalette.warn : AppPalette.textSecondary,
          ),
        ),
      ],
    );
  }
}
