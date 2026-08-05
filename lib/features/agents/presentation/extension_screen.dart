import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/extension_toolbar.dart';
import '../../../shared/widgets/section_scaffold.dart';
import '../logic/adapters/hermes_tool.dart';
import 'no_agent_view.dart';

/// The frame the three extension screens (Skills, Connectors, Plugins) share:
/// a search capsule, a refresh square, the screen's one create action, and the
/// list under them — rows clamped to a readable width so name and trailing
/// controls stay pairable in one glance.
///
/// Also owns the two things every extension screen must agree on: the
/// no-agent gate, and the "is a search narrowing this list" signal that turns
/// an empty list into "nothing matched" rather than "nothing installed".
class ExtensionScreen extends ConsumerStatefulWidget {
  const ExtensionScreen({
    super.key,
    required this.title,
    required this.subtitle,
    required this.searchHint,
    this.createLabel,
    this.onCreate,
    this.createButton,
    required this.onRefresh,
    required this.listBuilder,
    this.filterBar,
    this.onQueryChanged,
    this.maxContentWidth = 940,
  }) : assert(
         createButton != null || (createLabel != null && onCreate != null),
         'give the screen a create action: a label + handler, or a button',
       );

  final String title;
  final String subtitle;
  final String searchHint;

  /// How wide the content column is allowed to grow, whatever the window does.
  ///
  /// 940 by default, and that number is a reading measure: Skills, Plugins and
  /// Models are columns of rows, and a row stretched across a maximised 1900px
  /// display puts its name and its control at opposite ends of the desk.
  ///
  /// Connectors overrides it. That screen is a *grid* of cards rather than a
  /// column of rows, so the width buys columns instead of line length — and it
  /// carries a sidebar the cap made unreachable: measured 2026-08-04, a
  /// maximised 1884px window still handed the pane exactly 940, so the sidebar's
  /// 1164px threshold could never be met and it simply never appeared.
  final double maxContentWidth;

  /// The raw search text, as it is typed.
  ///
  /// Optional, and null for every screen whose list is already in memory —
  /// [listBuilder]'s `matches` is the whole search for those. Connectors is the
  /// exception: its rows come from a directory of four thousand servers and only
  /// fifty are loaded, so a local `matches` searches the page rather than the
  /// directory. That screen sends the text to the registry as well.
  final ValueChanged<String>? onQueryChanged;

  /// The standard create button's label and handler. Skipped when the screen
  /// supplies its own [createButton].
  final String? createLabel;
  final void Function(BuildContext context)? onCreate;

  /// A create control of the screen's own.
  ///
  /// For a screen whose create action isn't one thing: Skills has two ways to
  /// get a skill and opens a menu, which has to own the button it anchors to.
  final Widget? createButton;

  final VoidCallback onRefresh;

  /// An optional row of filter pills between the toolbar and the list — the
  /// Connectors screen narrows by status; the others don't need one.
  final Widget? filterBar;

  /// Builds the list for the current search: [matches] decides row visibility,
  /// [filtered] says whether a search is narrowing the list at all.
  final Widget Function(
    BuildContext context, {
    required bool filtered,
    required bool Function(String name, String description) matches,
  })
  listBuilder;

  @override
  ConsumerState<ExtensionScreen> createState() => _ExtensionScreenState();
}

class _ExtensionScreenState extends ConsumerState<ExtensionScreen> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool get _isFiltering => _query.trim().isNotEmpty;

  bool _matches(String name, String description) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return name.toLowerCase().contains(q) ||
        description.toLowerCase().contains(q);
  }

  @override
  Widget build(BuildContext context) {
    // The extension screens are scoped to the selected agent — Hermes today —
    // and every plane of it dies with the binary, so one gate up here.
    if (!ref.watch(hermesInstalledProvider)) {
      return NoAgentView(title: widget.title, subtitle: widget.subtitle);
    }

    return SectionScaffold(
      title: widget.title,
      subtitle: widget.subtitle,
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: widget.maxContentWidth),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: ExtensionSearchField(
                      controller: _search,
                      hintText: widget.searchHint,
                      onChanged: (value) {
                        setState(() => _query = value);
                        widget.onQueryChanged?.call(value);
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  ExtensionRefreshButton(onPressed: widget.onRefresh),
                  const SizedBox(width: 8),
                  widget.createButton ??
                      ExtensionCreateButton(
                        label: widget.createLabel!,
                        onPressed: () => widget.onCreate!(context),
                      ),
                ],
              ),
              if (widget.filterBar != null) ...[
                const SizedBox(height: 12),
                widget.filterBar!,
              ],
              const SizedBox(height: 14),
              Expanded(
                child: widget.listBuilder(
                  context,
                  filtered: _isFiltering,
                  matches: _matches,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
