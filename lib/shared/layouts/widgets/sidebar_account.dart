import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../features/app_update/logic/app_updater_service.dart';
import '../../../features/auth/logic/auth_controller.dart';
import '../../../features/auth/logic/session_controller.dart';
import '../../../features/feedback/presentation/feedback_dialog.dart';
import '../../../features/network/presentation/share_grid_dialog.dart';
import '../../../features/provider_node/logic/provider_run_controller.dart';
import '../../app_info.dart';
import '../../theme/app_theme.dart';
import '../../widgets/anchored_menu_position.dart';
import '../../widgets/labeled_field.dart';
import '../shell_state.dart';
import 'app_sidebar_mini.dart';

const _accountMenuWidth = 232.0;

// The menu hangs *above* the account row, and it's positioned by subtracting its
// own height from the anchor — so a height that doesn't match what's drawn leaves
// the menu floating in mid-air (or sitting on top of the row). These are the same
// numbers the rows below are built from, and [_accountMenuHeight] adds up exactly
// the rows that are actually rendered — so adding or removing an entry can't put
// the menu back in the air.
// A canonical menu row: 6px outer gutter (which is what makes hover read as an
// inset pill rather than a full-bleed band), then 8px of inner vertical padding
// around a 13/1.2 label. 1px of vertical gutter top and bottom.
const _menuRowHeight = 36.0;
const _menuVersionHeight = 26.0;
const _menuPadding = 5.0;
const _menuRowGutter = 6.0;
const _menuRowInnerPad = 9.0;
const _menuIconSlot = 16.0;
const _menuIconGap = 9.0;
// 8, per the radius ladder — a row nested in a 6-radius panel. Material's own
// menu item is radius 0.
final _menuRowRadius = BorderRadius.circular(AppControl.radius);

/// The menu entries that aren't a section — kept apart from `ShellSection.name`
/// so a section can never collide with one.
const _inviteValue = 'invite';
const _settingsValue = 'settings';
const _feedbackValue = 'feedback';
const _updatesValue = 'check_updates';
const _logoutValue = 'logout';

/// What the menu will actually measure, given what it's about to show: the
/// invite row (only on a grid the user owns), Settings, Send feedback, the
/// update row (not on platforms without an updater), the version (only once
/// it's read), Sign out.
Size _accountMenuSize({
  required bool invite,
  required bool updater,
  required bool version,
}) => Size(
  _accountMenuWidth,
  _menuPadding * 2 +
      (invite ? _menuRowHeight : 0) +
      _menuRowHeight * 2 +
      (updater ? _menuRowHeight : 0) +
      (version ? _menuVersionHeight : 0) +
      _menuRowHeight,
);

/// The sidebar's foot: who's signed in, and the menu that hangs off it — invite
/// someone onto the grid in scope, settings, feedback, check for updates, the
/// app version, sign out.
///
/// Wears a dot while a newer build is waiting, so an update is noticed instead of
/// having to be hunted for. Check outcomes are toasted app-wide by
/// `UpdateToastScope`.
class SidebarAccount extends ConsumerStatefulWidget {
  const SidebarAccount({super.key, this.compact = false});

  /// The avatar alone, for the folded rail: there is no room beside it for a
  /// name and an email, and both are already in the menu it opens. Same anchor,
  /// same menu — only the face of it changes.
  final bool compact;

  @override
  ConsumerState<SidebarAccount> createState() => _SidebarAccountState();
}

class _SidebarAccountState extends ConsumerState<SidebarAccount> {
  final _menu = MenuController();

  void _toggleMenu(
    BuildContext context,
    MenuController controller,
    Size menuSize,
  ) {
    if (controller.isOpen) {
      controller.close();
      return;
    }
    controller.open(
      position: anchoredMenuPosition(
        context,
        menuSize: menuSize,
        margin: 8,
        gap: 8,
        preferAbove: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // The account row and its menu read colour tokens from a global the element
    // tree can't track, and the providers watched here don't change on a theme
    // flip — so subscribe to the brightness to re-tint the row and recompute the
    // MenuStyle when the theme changes. (The menu's *contents* subscribe too, in
    // _AccountMenuContent: they live in a detached overlay this build can't reach
    // once the menu is open.)
    AppTheme.watch(context);

    // The padding sits *outside* the anchor on purpose: MenuAnchor measures its
    // whole subtree, so a padded wrapper would make it hang off a box 15px taller
    // than the pill you can see — and the menu would float above nothing.
    //
    // Folded, the same rule sends the [Center] outside too: it hands the anchor
    // loose constraints so the tile measures 40px rather than being stretched to
    // the rail's width, and a 72px-wide anchor would hang the menu off a box
    // wider than anything drawn.
    return Padding(
      padding: widget.compact
          ? const EdgeInsets.fromLTRB(0, 6, 0, 9)
          : const EdgeInsets.fromLTRB(10, 6, 10, 9),
      child: widget.compact ? Center(child: _anchor()) : _anchor(),
    );
  }

  /// The account pill and the menu hanging off it — built here rather than
  /// inline so [build] can wrap it in a [Center] when the rail is folded without
  /// duplicating the whole anchor.
  Widget _anchor() {
    final session = ref.watch(sessionProvider);
    final email = session.userEmail ?? '—';
    final name = session.user['name'] as String? ?? email;
    final updater = ref.read(appUpdaterServiceProvider);
    final version = ref.watch(appVersionProvider).asData?.value;
    final status = ref.watch(appUpdateStatusProvider).asData?.value;
    final available = status is UpdateAvailable ? status : null;
    // Inviting someone is member management, and the control plane only lets a
    // grid's owner do that — see [NetworkCredential.isOwner], which is
    // deliberately narrower than `canManageProvider`. So the row appears only
    // when the grid in scope is one this account owns; for a joined grid there
    // is nothing behind the row but a 403.
    final grid = ref.watch(selectedNetworkProvider);
    final invitable = grid != null && grid.isOwner ? grid : null;
    final menuSize = _accountMenuSize(
      invite: invitable != null,
      updater: updater.isSupported,
      version: version != null,
    );

    return MenuAnchor(
      controller: _menu,
      // `appMenuStyle()` is the app's one menu-panel recipe: a fill lifted
      // clear of *both* grounds a menu can open over, a hairline rim, and a
      // deeper shadow. This used to pass `AppPalette.cardBg` — #1E1E1E, which
      // sits at 1.02:1 against a #202020 block and is pure white on white in
      // light, so the panel had no edge and the rows floated loose on the
      // page. Only the width is ours; everything else is the shared recipe.
      style: appMenuStyle().copyWith(
        minimumSize: const WidgetStatePropertyAll(Size(_accountMenuWidth, 0)),
      ),
      menuChildren: [
        _AccountMenuContent(
          canInvite: invitable != null,
          version: version,
          updateAvailable: available,
          updaterSupported: updater.isSupported,
          onSelected: (value) => _onSelected(context, ref, updater, value),
        ),
      ],
      builder: (context, controller, _) => Semantics(
        button: true,
        label: 'Account',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _toggleMenu(context, controller, menuSize),
          child: widget.compact
              ? _AccountTile(
                  name: name,
                  email: email,
                  updateAvailable: available != null,
                )
              : _AccountRow(
                  name: name,
                  email: email,
                  updateAvailable: available != null,
                ),
        ),
      ),
    );
  }

  Future<void> _onSelected(
    BuildContext context,
    WidgetRef ref,
    AppUpdaterService updater,
    String value,
  ) async {
    _menu.close();
    if (value == _inviteValue) {
      // The same dialog the grid's own header opens, on the same grid — one
      // invite flow, so the two entry points can't drift apart. Re-read the
      // selection rather than trusting the one the menu was built from: the
      // menu outlives a `grid sync` that can swap it underneath.
      final grid = ref.read(selectedNetworkProvider);
      if (grid == null || !grid.isOwner) return;
      await ShareGridDialog.show(context, grid);
      return;
    }
    if (value == _updatesValue) {
      await updater.checkForUpdates();
      return;
    }
    if (value == _settingsValue) {
      ref.read(shellSectionProvider.notifier).select(kDefaultSettingsSection);
      return;
    }
    if (value == _feedbackValue) {
      await showFeedbackDialog(context);
      return;
    }
    if (value != _logoutValue) return;
    final engineRunning =
        ref.read(providerRunControllerProvider) is ProviderRunActive;
    if (!context.mounted) return;
    if (await _confirmSignOut(context, engineRunning: engineRunning)) {
      await ref.read(authControllerProvider.notifier).logout();
    }
  }

  Future<bool> _confirmSignOut(
    BuildContext context, {
    required bool engineRunning,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign out?'),
        content: Text(
          engineRunning
              ? "You'll be signed out and need to sign in again. The model "
                    'running on this computer will be stopped.'
              : "You'll be signed out and need to sign in again.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }
}

class _AccountMenuContent extends StatelessWidget {
  const _AccountMenuContent({
    required this.canInvite,
    required this.version,
    required this.updateAvailable,
    required this.updaterSupported,
    required this.onSelected,
  });

  /// Whether the grid in scope is one this account can add members to. False
  /// drops the invite row entirely rather than disabling it: a row you can't
  /// use explains nothing about why.
  final bool canInvite;

  final String? version;
  final UpdateAvailable? updateAvailable;
  final bool updaterSupported;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    // This subtree lives in the MenuAnchor's overlay — detached from the sidebar,
    // so a theme flip won't reach it top-down. Depend on the brightness directly
    // (BrightnessScope is an ancestor of the overlay too) so the open menu and
    // every row in it re-colour the instant the theme changes.
    AppTheme.watch(context);
    return SizedBox(
      width: _accountMenuWidth,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Bringing someone onto the grid is the one thing here you do *for*
          // other people, so it leads. The row doesn't name the grid because
          // [ShareGridDialog] does, in its title — which matters more from here
          // than from the grid's own page, since this menu is the one place in
          // the app that isn't already grid-scoped.
          if (canInvite)
            _AccountMenuItem(
              icon: LucideIcons.userPlus300,
              label: 'Invite members',
              onPressed: () => onSelected(_inviteValue),
            ),
          // One door to the setup screens — grids, this computer, Telegram, the
          // guide. They were four loose menu entries; a menu is a bad place to
          // keep things you have to come back to.
          _AccountMenuItem(
            icon: LucideIcons.settings300,
            label: 'Settings',
            onPressed: () => onSelected(_settingsValue),
          ),
          // Feedback lives here rather than in Settings because it is an act,
          // not a setting — and this menu is where a desktop app keeps the
          // things you do *to* the app itself. It sits above the update row for
          // the same reason: both are about Grid, and this is the one a user
          // reaches for while something is still fresh.
          _AccountMenuItem(
            icon: LucideIcons.megaphone300,
            label: 'Send feedback',
            onPressed: () => onSelected(_feedbackValue),
          ),
          if (updaterSupported)
            _AccountMenuItem(
              icon: LucideIcons.downloadCloud300,
              iconColor: updateAvailable == null
                  ? AppPalette.textSecondary
                  : AppPalette.brandBolt,
              label: updateAvailable == null
                  ? 'Check for updates'
                  : 'Update to ${updateAvailable?.version ?? 'the latest'}',
              onPressed: () => onSelected(_updatesValue),
            ),
          if (version != null) _AccountVersion(version: version!),
          _AccountMenuItem(
            icon: LucideIcons.logOut300,
            label: 'Sign out',
            onPressed: () => onSelected(_logoutValue),
          ),
        ],
      ),
    );
  }
}

class _AccountMenuItem extends StatelessWidget {
  const _AccountMenuItem({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.iconColor,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  /// Defaults to [AppPalette.textSecondary] (theme-aware) when null.
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    // Lives in the MenuAnchor's overlay, below a const boundary in some of its
    // call sites — depend on the brightness directly or the row keeps whichever
    // palette it first built in.
    AppTheme.watch(context);
    // The canonical menu row, hand-rolled. `MenuItemButton` cannot be used: the
    // app has no `menuButtonTheme`, so a bare one takes M3 defaults that
    // disagree on four counts — radius 0 (vs 8), 14pt labelLarge (vs 13),
    // an onSurface-at-8% hover (vs AppSurface.hoverFill), and an ink ripple
    // every other menu in the app suppresses. Its full-bleed highlight was also
    // why this row had no gutter.
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: _menuRowGutter,
        vertical: 1,
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: _menuRowRadius,
        child: InkWell(
          onTap: onPressed,
          borderRadius: _menuRowRadius,
          hoverColor: AppSurface.hoverFill,
          // macOS clicks land instantly; the global InkRipple would spread a
          // circle across the row. Hover is the affordance here.
          splashFactory: NoSplash.splashFactory,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: _menuRowInnerPad,
              vertical: 8,
            ),
            child: Row(
              children: [
                // A fixed slot, so labels line up whatever the glyph's own
                // width — and drop 18 → AppControl.iconSize, the size every
                // other menu in the app marks its rows with.
                SizedBox(
                  width: _menuIconSlot,
                  child: Icon(
                    icon,
                    size: AppControl.iconSize,
                    color: iconColor ?? AppPalette.textSecondary,
                  ),
                ),
                const SizedBox(width: _menuIconGap),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    // 13/1.2 regular — the system's menu label. It was 13.5
                    // semibold: half a point off the scale, and w600 is how
                    // this app marks *selection*, so every row read as picked.
                    style: TextStyle(
                      color: AppPalette.textPrimary,
                      fontSize: 13,
                      height: 1.2,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AccountVersion extends StatelessWidget {
  const _AccountVersion({required this.version});

  final String version;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // reads colour tokens; follow theme flips.
    return SizedBox(
      height: _menuVersionHeight,
      child: Padding(
        // Indented to the rows' *label* column, not their gutter — this is a
        // note about the app, not something you can pick, so it lines up with
        // what the rows say rather than with the glyphs they say it behind.
        padding: const EdgeInsets.fromLTRB(
          _menuRowGutter + _menuRowInnerPad + _menuIconSlot + _menuIconGap,
          2,
          _menuRowGutter + _menuRowInnerPad,
          8,
        ),
        child: Text(
          'Version $version',
          // 12/1.28 is the system's detail line. textFaint measures 2.8:1 on
          // the dark panel and 3.33:1 on light — under 4.5, but this is
          // incidental metadata rather than body text, and it's the same token
          // every other secondary line in the app's menus uses.
          style: TextStyle(
            fontSize: 12,
            height: 1.28,
            color: AppPalette.textFaint,
          ),
        ),
      ),
    );
  }
}

/// The clickable face of the account menu: initial, name, email.
///
/// The pill and nothing else — it *is* the anchor the menu hangs off, so any
/// padding around it belongs to the parent (see [SidebarAccount.build]).
///
/// Stateful for the hover feedback: with no menu bar tooltip any more, the pill
/// has to say "click me" on its own — so it lifts its fill, firms its rim and
/// darkens the ⋯ under the pointer, and dips a hair on press. The same motion
/// vocabulary the nav rows use.
class _AccountRow extends StatefulWidget {
  const _AccountRow({
    required this.name,
    required this.email,
    required this.updateAvailable,
  });

  final String name;
  final String email;
  final bool updateAvailable;

  @override
  State<_AccountRow> createState() => _AccountRowState();
}

class _AccountRowState extends State<_AccountRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final name = widget.name;
    final initial = name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 130),
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(11),
          // Lifts a step under the pointer so the pill reads as clickable.
          color: _hovered ? AppSurface.recessHover : AppSurface.recess,
          // A hairline rim so the pill reads as its own surface at the rail's
          // foot, rather than dissolving into the recess behind it — the same
          // edge language the rest of the chrome uses. Firms up a touch on hover.
          border: Border.all(
            color: _hovered ? AppGlass.hair : AppPalette.divider,
          ),
          boxShadow: [
            BoxShadow(
              color: AppTheme.pick(
                const Color(0x06000000),
                const Color(0x40000000),
              ),
              blurRadius: 10,
              offset: const Offset(0, 2),
              spreadRadius: -7,
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 7, 7, 7),
          child: Row(
            children: [
              _Avatar(
                initial: initial,
                updateAvailable: widget.updateAvailable,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  widget.email,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppPalette.textSecondary,
                    fontSize: 12.5,
                  ),
                ),
              ),
              // The ⋯ warms from faint to secondary on hover — a small "there's
              // a menu here" nudge that drifts up a hair as the pointer lands.
              AnimatedSlide(
                offset: Offset(0, _hovered ? -0.06 : 0),
                duration: const Duration(milliseconds: 130),
                curve: Curves.easeOut,
                child: Icon(
                  LucideIcons.ellipsis300,
                  size: 20,
                  color: _hovered
                      ? AppPalette.textSecondary
                      : AppPalette.textFaint,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The same account button folded to its avatar, for [AppSidebarMini].
///
/// Not the pill with the email hidden: at 72px the recessed pill would be a
/// rounded box hugging a circle, which reads as a second ring around the avatar.
/// So the tile borrows the folded rail's own recipe instead — a 40px square that
/// takes [AppSurface.hoverFill] under the pointer — and the email it can no
/// longer show moves into the tooltip.
class _AccountTile extends StatefulWidget {
  const _AccountTile({
    required this.name,
    required this.email,
    required this.updateAvailable,
  });

  final String name;
  final String email;
  final bool updateAvailable;

  @override
  State<_AccountTile> createState() => _AccountTileState();
}

class _AccountTileState extends State<_AccountTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final name = widget.name.trim();
    final initial = name.isEmpty ? '?' : name[0].toUpperCase();
    return Tooltip(
      message: widget.email,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: AnimatedContainer(
          duration: AppMotion.hover,
          curve: AppMotion.curve,
          width: MiniRailItem.box,
          height: MiniRailItem.box,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _hovered ? AppSurface.hoverFill : Colors.transparent,
            borderRadius: BorderRadius.circular(AppControl.radius),
          ),
          child: _Avatar(
            initial: initial,
            updateAvailable: widget.updateAvailable,
          ),
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.initial, required this.updateAvailable});

  final String initial;
  final bool updateAvailable;

  @override
  Widget build(BuildContext context) {
    // The one spot of colour at the rail's foot, so it earns a little depth: a
    // soft indigo gradient (accent → a shade toward violet) under a hairline ring
    // and a low accent-tinted glow. Still 26px and flat to the eye — the lift is
    // all edge and shadow, in keeping with the rest of the chrome.
    final avatar = Container(
      width: 26,
      height: 26,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomRight,
          colors: [
            AppPalette.accentMuted,
            Color.lerp(AppPalette.accentMuted, const Color(0xFF7A3CF0), 0.42)!,
          ],
        ),
        border: Border.all(
          color: AppTheme.pick(
            const Color(0x22FFFFFF),
            const Color(0x1FFFFFFF),
          ),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: AppPalette.accent.withValues(alpha: 0.32),
            blurRadius: 7,
            offset: const Offset(0, 2),
            spreadRadius: -2,
          ),
        ],
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12.5,
          fontWeight: AppFont.medium,
        ),
      ),
    );
    if (!updateAvailable) return avatar;
    return Badge(
      backgroundColor: AppPalette.brandBolt,
      smallSize: 8,
      child: avatar,
    );
  }
}
