import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/layouts/onboarding_page.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/choice_row.dart';
import '../../../shared/widgets/detail_widgets.dart';
import '../../auth/logic/session_controller.dart';
import '../../network/logic/grid_access_summary.dart';
import '../../network/logic/grid_sync_controller.dart';
import 'widgets/grid_pick_list.dart';
import 'widgets/new_grid_form.dart';

/// The first thing after signing in: which grid is this?
///
/// The app used to answer it silently — [CredentialsFile.active] picks a grid
/// out of a five-deep fallback — so a user on more than one grid landed
/// somewhere they hadn't chosen and had no reason to look for the switch. Every
/// screen behind this one reads the answer (what model the grid serves, where
/// chat sends, what this computer would share), so it is worth one screen.
///
/// The explaining is folded away. It began as a subtitle, which made every
/// launch pay for the first one: a definition of "grid" sat between the reader
/// and the rows on the tenth visit exactly as it did on the first, and a
/// subtitle cannot be skipped. Behind a link it costs one line until someone
/// wants it, and the people who do want it are asking *before* they read the
/// list, which is why the link sits above rather than under.
///
/// Asked once per sign-in. [gridChoiceNeededProvider] is false the moment a grid
/// is picked, and with "Remember my choice" ticked the answer survives a
/// relaunch too — but never a sign-out, which clears it (`AuthController`).
class GridChoiceScreen extends ConsumerStatefulWidget {
  const GridChoiceScreen({super.key});

  @override
  ConsumerState<GridChoiceScreen> createState() => _GridChoiceScreenState();
}

class _GridChoiceScreenState extends ConsumerState<GridChoiceScreen> {
  /// Whether the create form is showing. Null until the user says either way,
  /// so the default below can follow the account.
  bool? _creating;

  /// Whether picking a grid writes it down for next time.
  ///
  /// Ticked by default: most people work on one grid, and asking them the same
  /// question at every launch is friction with nothing to show for it. The tick
  /// is what makes that default safe — the way out is visible *before* the
  /// choice is made, not buried in Settings afterwards.
  bool _remember = true;

  /// Whether the "What's a grid?" note is open. Shut to begin with: the
  /// people who need it are a minority of launches, and a definition unfolded
  /// over the list makes everyone else read past an answer to a question they
  /// did not ask.
  bool _explaining = false;

  @override
  void initState() {
    super.initState();
    // Pull the account's grids once, on arrival. This screen lists whatever the
    // last `grid sync` wrote, and a grid shared with you five minutes ago is on
    // your account but not yet on this computer — which used to make the screen
    // a dead end for exactly the person who was invited to a grid. Staleness is
    // the app's problem, not something to hand back as a button. Outside build
    // (§2), non-blocking, and silent on failure: the cached list still works and
    // `GridCliService` has already written the real reason to the log (§6).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(gridSyncControllerProvider.notifier).sync();
    });
  }

  @override
  Widget build(BuildContext context) {
    final networks = ref.watch(sessionProvider).networks;
    final hasGrids = networks.isNotEmpty;
    // An account with no grids has only one honest answer, so the create form
    // opens itself rather than making the user press a row whose alternative
    // isn't there. Otherwise the list leads: picking is one click from here.
    final creating = _creating ?? !hasGrids;

    return OnboardingPage(
      // A question the reader can answer, in words carrying no product
      // vocabulary at all. "Choose your grid" asked them to pick one of a thing
      // they had never heard of, using its name as though they already knew it.
      title: 'Where should your chats run?',
      children: [
        // Above the list, because it answers the question a first-time reader
        // has *before* they look at the rows — and folded, because a returning
        // one already knows and would only have to scroll past it.
        _WhatIsAGrid(
          open: _explaining,
          onToggle: () => setState(() => _explaining = !_explaining),
        ),
        const SizedBox(height: 14),
        if (hasGrids) ...[
          GridPickList(remember: _remember),
          const SizedBox(height: 10),
          _RememberChoice(
            value: _remember,
            onChanged: (next) => setState(() => _remember = next),
          ),
          const SizedBox(height: 18),
        ],
        ChoiceRowGroup(
          outlined: true,
          children: [
            ChoiceRow(
              icon: const Icon(Icons.add_circle_outline),
              // One line, like the rows above it: those are single-line items,
              // and a heavier action under them read as a different weight of
              // thing. Who can join is the form's own first question, so the
              // row does not need to promise it in advance.
              title: 'Create your own grid',
              action: ChoiceRowAction.open,
              expanded: creating,
              onPressed: () => setState(() => _creating = !creating),
              child: creating ? const NewGridForm() : null,
            ),
          ],
        ),
      ],
    );
  }
}

/// The tick deciding whether this answer outlives the session.
///
/// One quiet line, sized and coloured to sit *under* the list rather than
/// compete with it. It had a bold title and a sentence explaining both states,
/// which gave a setting more weight than the choice it modifies — the rows above
/// are what this screen is for, and a two-line block in ink as dark as theirs
/// read as a third thing to decide.
class _RememberChoice extends StatelessWidget {
  const _RememberChoice({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: InkWell(
        onTap: () => onChanged(!value),
        borderRadius: BorderRadius.circular(AppCard.insetRadius),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Scaled rather than resized: the box shrinks to the weight of the
              // line beside it while the hit area stays the full control, so a
              // quieter tick is not a harder one to hit (§11).
              SizedBox(
                width: 18,
                height: 18,
                child: Transform.scale(
                  scale: 0.82,
                  child: Checkbox(
                    value: value,
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    onChanged: (next) => onChanged(next ?? false),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                'Remember my choice',
                style: theme.textTheme.bodySmall?.copyWith(
                  // Not `textFaint`: a control's own label has to clear 4.5:1
                  // on this white card (§11).
                  color: AppPalette.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The folded note over the list: a link, and what it opens.
///
/// A link rather than a paragraph because this screen's job is to be answered,
/// not read. The words that were here as a subtitle made every launch pay for
/// the first one — and a subtitle is not skippable, which is the whole
/// difference between explaining and being in the way.
///
/// It names both things it opens, in the order it opens them. Two clauses look
/// long for a link this quiet, but each covers a question the card genuinely
/// raises and neither answers the other: a reader who has never heard of a grid
/// is not helped by a glossary of words, and one who has still meets `Owner`
/// and `Public` here for the first time, unexplained, on the very rows they are
/// being asked to choose between.
///
/// It says the words themselves rather than naming what they are. "What do
/// these tags mean?" asks the reader to know that the coloured thing on a row
/// is called a tag — interface vocabulary they have no reason to hold, and the
/// wrong half of the sentence to spend their attention on. Quoting `Owner` and
/// `Public` back to them points at something already on the screen.
class _WhatIsAGrid extends StatelessWidget {
  const _WhatIsAGrid({required this.open, required this.onToggle});

  final bool open;
  final VoidCallback onToggle;

  /// The words as the rows below spell them, read off [GridAccessTag] rather
  /// than typed out again — a link quoting a label that has since been renamed
  /// points at nothing, and would do it in the one sentence promising to
  /// explain the labels.
  static String get _tagNames {
    final names = GridAccessTag.values.map((tag) => tag.label).toList();
    final head = names.sublist(0, names.length - 1).join(', ');
    return '$head and ${names.last}';
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: onToggle,
          borderRadius: BorderRadius.circular(AppCard.insetRadius),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'What’s a grid, and what do $_tagNames mean?',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppPalette.accent,
                    fontWeight: AppFont.medium,
                  ),
                ),
                const SizedBox(width: 3),
                // Ends up pointing at what it opened, exactly as [ChoiceRow]'s
                // marker does, so the two disclosures on this card behave alike.
                AnimatedRotation(
                  turns: open ? 0.25 : 0,
                  duration: AppMotion.hover,
                  curve: AppMotion.curve,
                  child: Icon(
                    Icons.chevron_right_rounded,
                    size: 17,
                    color: AppPalette.accent,
                  ),
                ),
              ],
            ),
          ),
        ),
        AnimatedSize(
          duration: AppMotion.fold,
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: open
              ? const Padding(
                  padding: EdgeInsets.fromLTRB(4, 10, 0, 2),
                  child: _GridLegend(),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}

/// What a grid is, and what each tag on the rows below means.
///
/// Shows the real pills rather than naming them: the fastest answer to "what
/// does Public mean?" is the same badge the row wears, sitting next to its
/// sentence. Spelling the words out in prose would leave the reader to match
/// the two up themselves.
class _GridLegend extends StatelessWidget {
  const _GridLegend();

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // In the link's own order: it asks what a grid is first, so that is what
        // opens first. Answering the second half before the first makes the
        // reader hunt through the panel for what they clicked for.
        Text(
          'A grid is a group of computers that answer your chats. You can '
          'switch anytime.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: AppPalette.textSecondary,
          ),
        ),
        const SizedBox(height: 12),
        for (final tag in GridAccessTag.values) ...[
          _LegendRow(tag: tag),
          if (tag != GridAccessTag.values.last) const SizedBox(height: 7),
        ],
      ],
    );
  }
}

/// One tag beside what it means.
class _LegendRow extends StatelessWidget {
  const _LegendRow({required this.tag});

  final GridAccessTag tag;

  /// Written from the reader's side — what the tag says about *them* and this
  /// grid, not what the control plane calls the rule.
  String get _meaning => switch (tag) {
    GridAccessTag.public => 'Anyone can use this one.',
    GridAccessTag.owner => 'You created it, so you decide who joins.',
    GridAccessTag.invited => 'Someone gave you access to theirs.',
  };

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // A fixed column so the three sentences line up. The pills are three
        // different widths, and a ragged left edge reads as three unrelated
        // notes rather than one legend.
        SizedBox(
          width: 74,
          child: Align(
            alignment: Alignment.centerLeft,
            child: gridPill(tag.label, gridTagColour(tag)),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            _meaning,
            style: theme.textTheme.bodySmall?.copyWith(
              color: AppPalette.textSecondary,
            ),
          ),
        ),
      ],
    );
  }
}
