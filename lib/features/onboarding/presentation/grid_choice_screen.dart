import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/analytics/analytics_events.dart';
import '../../../infrastructure/analytics/analytics_providers.dart';
import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/layouts/onboarding_page.dart';
import '../../../shared/theme/app_theme.dart';
import '../../auth/logic/session_controller.dart';
import '../../network/logic/grid_choice.dart';
import '../../network/logic/grid_choice_row.dart';
import '../../network/logic/grid_sync_controller.dart';
import 'widgets/grid_pick_list.dart';
import 'widgets/grid_search_field.dart';
import 'widgets/new_grid_form.dart';

/// The first thing after signing in: which grid is this?
///
/// The app used to answer it silently — [CredentialsFile.active] picks a grid
/// out of a five-deep fallback — so a user on more than one grid landed
/// somewhere they hadn't chosen and had no reason to look for the switch. Every
/// screen behind this one reads the answer (what model the grid serves, where
/// chat sends, what this computer would share), so it is worth one screen.
///
/// Choosing is two steps now: press a grid, then press the button. That reads
/// like a step too many until you have three grids and no idea which of them
/// has anything running — the rows carry that, and a list you can compare is
/// only comparable if pressing one doesn't end the screen.
///
/// Asked once per sign-in. [gridChoiceNeededProvider] is false the moment a grid
/// is entered, and with "Always start here" ticked the answer survives a
/// relaunch too — but never a sign-out, which clears it (`AuthController`).
class GridChoiceScreen extends ConsumerStatefulWidget {
  const GridChoiceScreen({super.key});

  @override
  ConsumerState<GridChoiceScreen> createState() => _GridChoiceScreenState();
}

class _GridChoiceScreenState extends ConsumerState<GridChoiceScreen> {
  /// The grid the button would enter. Null until the reader picks, which is
  /// also what keeps the button honest about having nothing to do yet.
  String? _selectedId;

  /// Whether the create block is open. Null until the reader says either way,
  /// so the default below can follow the account.
  bool? _creating;

  /// Whether entering a grid writes it down for next time.
  ///
  /// Ticked by default: most people work on one grid, and asking them the same
  /// question at every launch is friction with nothing to show for it. The tick
  /// is what makes that default safe — the way out is visible *before* the
  /// choice is made, not buried in Settings afterwards.
  bool _remember = true;

  final _query = TextEditingController();

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
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _enter(NetworkCredential network) {
    ref.read(analyticsProvider).gridChoice('existing');
    ref
        .read(gridChoiceGateProvider.notifier)
        .choose(network, remember: _remember);
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final networks = ref.watch(sessionProvider).networks;
    final matches = filterGrids(networks, _query.text);
    final selected = matches
        .where((n) => n.networkId == _selectedId)
        .firstOrNull;
    // An account with no grids has only one honest answer, so the create block
    // opens itself rather than making the reader press a row whose alternative
    // isn't there. Otherwise the list leads.
    final creating = _creating ?? networks.isEmpty;

    return OnboardingPage(
      // A question the reader can answer, in words carrying no product
      // vocabulary at all. "Choose your grid" asked them to pick one of a thing
      // they had never heard of, using its name as though they already knew it.
      title: 'Where should your chats run?',
      // What the word means, what to do about it, and that doing it is
      // reversible — a reader who does not know what a grid is cannot know to
      // go looking behind a link for it.
      subtitle:
          'A grid is a set of computers that answer your chats. Pick one to '
          'get started. Switching later takes a click.',
      footer: _Footer(
        remember: _remember,
        onRemember: (next) => setState(() => _remember = next),
        // Nothing to confirm while the create block is open: that block has its
        // own button, and two primaries on one screen is a coin toss.
        selected: creating ? null : selected,
        onEnter: () => _enter(selected!),
      ),
      children: [
        // Only once the list is long enough to be worth searching. Below that
        // it is a box that costs a row of height to save nobody any scrolling.
        if (networks.length > 5) ...[
          GridSearchField(
            controller: _query,
            countLabel: gridCountLabel(
              shown: matches.length,
              total: networks.length,
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
        ],
        if (networks.isNotEmpty)
          GridPickList(
            networks: matches,
            selected: creating ? null : selected,
            onSelect: (network) => setState(() {
              _selectedId = network.networkId;
              _creating = false;
            }),
          ),
        const SizedBox(height: 6),
        NewGridForm(
          open: creating,
          onToggle: () => setState(() {
            _creating = !creating;
            if (_creating!) _selectedId = null;
          }),
        ),
      ],
    );
  }
}

/// The strip across the bottom: what outlives this choice, and the button that
/// acts on it.
class _Footer extends StatelessWidget {
  const _Footer({
    required this.remember,
    required this.onRemember,
    required this.selected,
    required this.onEnter,
  });

  final bool remember;
  final ValueChanged<bool> onRemember;
  final NetworkCredential? selected;
  final VoidCallback onEnter;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.fromLTRB(26, 16, 26, 16),
      decoration: BoxDecoration(
        color: AppPalette.panelBg,
        border: Border(top: BorderSide(color: AppPalette.divider)),
      ),
      child: Row(
        children: [
          Expanded(
            child: _RememberTick(value: remember, onChanged: onRemember),
          ),
          const SizedBox(width: 16),
          SizedBox(
            height: 36,
            child: FilledButton(
              // Dead until there is something to enter, and saying which of the
              // two it is: "Pick a grid" is the instruction, "Start chatting"
              // is the promise. A button that only ever said the second would
              // be a control the reader presses and nothing happens.
              onPressed: selected == null ? null : onEnter,
              child: Text(selected == null ? 'Pick a grid' : 'Start chatting'),
            ),
          ),
        ],
      ),
    );
  }
}

/// "Always start here" — whether this answer outlives the session.
class _RememberTick extends StatelessWidget {
  const _RememberTick({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => onChanged(!value),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 17,
                height: 17,
                decoration: BoxDecoration(
                  color: value ? AppPalette.accent : AppCard.base,
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(
                    color: value ? AppPalette.accent : AppPalette.textFaint,
                    width: 1.5,
                  ),
                ),
                child: value
                    ? const Icon(
                        Icons.check_rounded,
                        size: 12,
                        color: Colors.white,
                      )
                    : null,
              ),
              const SizedBox(width: 9),
              Text(
                'Always start here',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontSize: 12.5,
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
