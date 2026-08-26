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
      // Three short sentences doing three jobs: what the word means, what to do
      // about it, and that doing it is reversible. It sat behind the link for a
      // while, which was wrong — a reader who does not know what a grid is
      // cannot know to go looking behind a link for it. What belongs there is
      // the part that is optional.
      subtitle:
          'A grid is a group of computers that answer your chats. Choose one '
          'to get started. You can switch anytime.',
      children: [
        if (hasGrids) ...[
          GridPickList(remember: _remember),
          const SizedBox(height: 8),
          // One quiet row under the list carrying both asides: what the labels
          // on it mean, and whether this answer is kept. Neither is a step, and
          // on separate lines they read like two more of them.
          //
          // Wrap, not Row: both halves grow with the user's font size, and on a
          // narrow card they drop onto their own lines rather than overflow.
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            runSpacing: 2,
            children: [
              _LabelsLink(
                open: _explaining,
                onToggle: () => setState(() => _explaining = !_explaining),
              ),
              _RememberChoice(
                value: _remember,
                onChanged: (next) => setState(() => _remember = next),
              ),
            ],
          ),
          _LabelsReveal(open: _explaining),
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
              title: 'Create a new grid',
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
    return InkWell(
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
                // Matched to the link it shares a row with. Not `textFaint`:
                // a control's own label has to clear 4.5:1 on this white card,
                // and shrinking it buys no slack there (§11).
                fontSize: 12,
                color: AppPalette.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The link half of the labels note, sized to sit in a row beside the tick.
///
/// It says the words themselves rather than naming what they are. "What do
/// these labels mean?" asks the reader to know that the coloured thing on a row
/// is called a label — interface vocabulary they have no reason to hold, and
/// the wrong half of the sentence to spend their attention on. Quoting `Owner`
/// and `Public` back to them points at something already on the screen.
class _LabelsLink extends StatelessWidget {
  const _LabelsLink({required this.open, required this.onToggle});

  final bool open;
  final VoidCallback onToggle;

  /// The words as the rows above spell them, read off [GridAccessTag] rather
  /// than typed out again — a link quoting a label that has since been renamed
  /// points at nothing, and would do it in the one sentence promising to
  /// explain the labels.
  static String get _names {
    final names = GridAccessTag.values.map((tag) => tag.label).toList();
    final head = names.sublist(0, names.length - 1).join(', ');
    return '$head and ${names.last}';
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    return InkWell(
      onTap: onToggle,
      borderRadius: BorderRadius.circular(AppCard.insetRadius),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'What do $_names mean?',
              // A step under bodySmall, matched by the tick beside it: these
              // two annotate the list rather than belonging to it, and at the
              // rows' own size they competed with what they annotate.
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 12,
                color: AppPalette.accent,
                fontWeight: AppFont.medium,
              ),
            ),
            const SizedBox(width: 2),
            // Ends up pointing at what it opened, exactly as [ChoiceRow]'s
            // marker does, so the two disclosures on this card behave alike.
            AnimatedRotation(
              turns: open ? 0.25 : 0,
              duration: AppMotion.hover,
              curve: AppMotion.curve,
              child: Icon(
                Icons.chevron_right_rounded,
                size: 15,
                color: AppPalette.accent,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// What the link opens, folding in under the row the link sits in.
class _LabelsReveal extends StatelessWidget {
  const _LabelsReveal({required this.open});

  final bool open;

  @override
  Widget build(BuildContext context) => AnimatedSize(
    duration: AppMotion.fold,
    curve: Curves.easeOutCubic,
    alignment: Alignment.topCenter,
    child: open
        ? const Padding(
            padding: EdgeInsets.fromLTRB(4, 10, 0, 2),
            child: _GridLegend(),
          )
        : const SizedBox(width: double.infinity),
  );
}

/// What each label on the rows above means.
///
/// Shows the real pills rather than naming them: the fastest answer to "what
/// does Public mean?" is the same badge the row wears, sitting next to its
/// sentence. Spelling the words out in prose would leave the reader to match
/// the two up themselves.
class _GridLegend extends StatelessWidget {
  const _GridLegend();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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
