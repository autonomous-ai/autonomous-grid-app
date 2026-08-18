import 'package:flutter/material.dart';

import '../../../shared/theme/app_theme.dart';
import '../../agents/logic/agent_questions.dart';

/// One question: its heading, the question itself, and the answers on offer.
class AgentQuestionBlock extends StatelessWidget {
  const AgentQuestionBlock({
    super.key,
    required this.question,
    required this.picked,
    required this.onPick,
  });

  final AgentQuestion question;
  final Set<String> picked;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8, right: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (question.header.isNotEmpty) ...[
            Text(
              question.header.toUpperCase(),
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                color: AppPalette.textSecondary,
              ),
            ),
            const SizedBox(height: 4),
          ],
          Text(
            question.question,
            style: const TextStyle(fontSize: 13, height: 1.35),
          ),
          if (question.multiSelect) ...[
            const SizedBox(height: 3),
            Text(
              'Pick as many as apply',
              style: TextStyle(fontSize: 11.5, color: AppPalette.textFaint),
            ),
          ],
          const SizedBox(height: 7),
          for (final option in question.options)
            _OptionRow(
              option: option,
              selected: picked.contains(option.label),
              multi: question.multiSelect,
              onTap: () => onPick(option.label),
            ),
        ],
      ),
    );
  }
}

/// One answer on offer — its label, and the trade-off under it in the agent's
/// own words, so the choice is made on what it means rather than on its name.
class _OptionRow extends StatelessWidget {
  const _OptionRow({
    required this.option,
    required this.selected,
    required this.multi,
    required this.onTap,
  });

  final AgentQuestionOption option;
  final bool selected;
  final bool multi;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final radius = BorderRadius.circular(AppControl.radius);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: Colors.transparent,
        borderRadius: radius,
        child: InkWell(
          onTap: onTap,
          borderRadius: radius,
          hoverColor: AppSurface.hoverFill,
          splashFactory: NoSplash.splashFactory,
          child: Ink(
            decoration: BoxDecoration(
              color: selected ? AppSurface.accentWash : AppCard.inset,
              borderRadius: radius,
              border: Border.all(
                color: selected ? AppCard.tint25 : AppCard.insetHair,
              ),
            ),
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  _mark,
                  size: AppControl.iconSize,
                  color: selected ? AppPalette.accent : AppPalette.textFaint,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        option.label,
                        style: const TextStyle(
                          fontSize: 13,
                          height: 1.3,
                          fontWeight: AppFont.medium,
                        ),
                      ),
                      if (option.description.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          option.description,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.35,
                            color: AppPalette.textSecondary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// A box for a question that takes several answers, a circle for one that
  /// takes one — the shape says how many picks are allowed before the user
  /// tries a second.
  IconData get _mark => multi
      ? (selected ? Icons.check_box_rounded : Icons.check_box_outline_blank)
      : (selected
            ? Icons.radio_button_checked_rounded
            : Icons.radio_button_unchecked_rounded);
}
