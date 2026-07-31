import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/error_box.dart';
import '../../../shared/widgets/extension_toolbar.dart';
import '../../../shared/widgets/pill_choice.dart';
import '../../agents/presentation/extension_screen.dart';
import '../logic/connector.dart';
import '../logic/connectors_controller.dart';
import '../logic/connectors_refresh.dart';
import 'widgets/add_mcp_dialog.dart';
import 'widgets/browse_connectors_dialog.dart';
import 'widgets/connector_list.dart';

/// What connects the assistant to the outside: the MCP servers in the agent's
/// config, and the catalog of services a future sign-in will connect in one
/// step. The config is the only truth about what's live — the catalog only
/// adds "available" rows under it.
class ConnectorsView extends ConsumerStatefulWidget {
  const ConnectorsView({super.key});

  @override
  ConsumerState<ConnectorsView> createState() => _ConnectorsViewState();
}

enum _ConnectorFilter {
  all('All'),
  connected('Connected'),
  available('Available');

  const _ConnectorFilter(this.label);

  final String label;

  bool keeps(Connector connector) => switch (this) {
    all => true,
    connected => connector.connected,
    available => !connector.connected,
  };
}

/// One of this screen's two toolbar actions.
///
/// Local rather than `ExtensionCreateButton` because this screen is the only one
/// with *two* ways to add something, so it is the only one that has to decide
/// which of them is the primary. Every other screen has a single create action
/// and keeps the shared button; changing that one to take a variant would push
/// this screen's problem onto four that don't have it.
///
/// The geometry — 34px, radius 11, `AppGlass.cardShadow` — is copied from the
/// shared pair on purpose: these sit in the same row as the refresh button, and
/// a toolbar whose buttons are two heights reads as broken before it reads as
/// deliberate.
///
/// [accent] carries the primary. **Browse holds it**: the directory is where
/// someone who does not already have a URL can actually get somewhere, and Add
/// custom is for the narrower case of already knowing the address. Two accent
/// buttons side by side would make the screen ask which is the real one.
class _ToolbarButton extends StatelessWidget {
  const _ToolbarButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.accent = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // follow theme flips — reads AppPalette/AppGlass.
    // White on accent is the shared button's own pairing, kept rather than
    // re-derived: `AppPalette.accent` is tuned as a fill for exactly this ink.
    // The quiet variant takes the default text colour, which resolves per theme.
    final ink = accent ? Colors.white : null;
    return Material(
      color: accent ? AppPalette.accent : AppGlass.surfaceFill,
      borderRadius: BorderRadius.circular(11),
      child: InkWell(
        borderRadius: BorderRadius.circular(11),
        onTap: onPressed,
        child: Container(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(11),
            boxShadow: AppGlass.cardShadow,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 17, color: ink),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  color: ink,
                  fontSize: 13,
                  // The heavier weight belongs to the primary, not to the
                  // label: it is half of what makes one of these read as the
                  // action to take.
                  fontWeight: accent ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConnectorsViewState extends ConsumerState<ConnectorsView> {
  _ConnectorFilter _filter = _ConnectorFilter.all;

  @override
  Widget build(BuildContext context) {
    return ExtensionScreen(
      title: 'Connectors',
      subtitle:
          'Connect the assistant to tools outside this computer — a database, '
          'a design tool, a web service.',
      searchHint: 'Search connectors',
      // Two ways in, so the toolbar owns the button rather than taking the
      // standard one. They are genuinely different questions — "find me
      // something" and "I already have an address" — and a menu would hide the
      // first behind a press for no gain: there are only two.
      //
      // "Add custom", not "Add an MCP server": the rest of this screen speaks in
      // Connect/Disconnect, and a user who doesn't know what MCP is can't tell
      // how that button differs from the Connect on every row.
      createButton: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ToolbarButton(
            icon: Icons.travel_explore_rounded,
            label: 'Browse',
            accent: true,
            onPressed: () => showBrowseConnectorsDialog(context),
          ),
          const SizedBox(width: 8),
          _ToolbarButton(
            icon: Icons.add_rounded,
            label: 'Add custom',
            onPressed: () => showAddMcpDialog(context),
          ),
        ],
      ),
      // The same definition of "reload" the mutations use, so the button can't
      // drift from them as sources are added.
      onRefresh: () => refreshConnectorsFromWidget(ref),
      filterBar: Row(
        children: [
          for (final option in _ConnectorFilter.values)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: PillChoice(
                label: Text(option.label),
                selected: option == _filter,
                onTap: () => setState(() => _filter = option),
              ),
            ),
        ],
      ),
      listBuilder: (context, {required filtered, required matches}) {
        return switch (ref.watch(connectorsProvider)) {
          AsyncData(:final value) => ConnectorList(
            // A status pill narrows the list just like a search does: sections
            // collapse (they'd all be one status anyway) and an empty result
            // reads as "nothing matched", not "nothing configured".
            filtered: filtered || _filter != _ConnectorFilter.all,
            connectors: [
              for (final connector in value)
                if (_filter.keeps(connector) &&
                    matches(connector.name, connector.description))
                  connector,
            ],
          ),
          AsyncError(:final error) => ErrorBox(
            message: "Couldn't read the connectors: $error",
          ),
          _ => const ExtensionLoadingRows(),
        };
      },
    );
  }
}
