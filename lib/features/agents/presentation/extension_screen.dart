import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/extension_toolbar.dart';
import '../../../shared/widgets/section_scaffold.dart';
import '../../agent/logic/hermes_tool.dart';
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
    required this.createLabel,
    required this.onCreate,
    required this.onRefresh,
    required this.listBuilder,
    this.filterBar,
  });

  final String title;
  final String subtitle;
  final String searchHint;
  final String createLabel;
  final void Function(BuildContext context) onCreate;
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
          constraints: const BoxConstraints(maxWidth: 940),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: ExtensionSearchField(
                      controller: _search,
                      hintText: widget.searchHint,
                      onChanged: (value) => setState(() => _query = value),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ExtensionRefreshButton(onPressed: widget.onRefresh),
                  const SizedBox(width: 8),
                  ExtensionCreateButton(
                    label: widget.createLabel,
                    onPressed: () => widget.onCreate(context),
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
