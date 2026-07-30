import 'package:flutter/material.dart';

import 'extension_tile_surface.dart';

/// One chapter of an extension list: a header label and the rows under it.
///
/// An empty [label] means "no header" — the flat list is modelled as a single
/// unlabelled section, so [ExtensionList] renders every shape the same way.
class ExtensionSection<T> {
  const ExtensionSection({required this.label, required this.items});

  final String label;
  final List<T> items;
}

/// Group [items] into labelled sections, or fall back to one flat run.
///
/// The fallback rules are shared by every extension screen and each was once
/// its own bug:
/// - While a search is [filtered]-ing, no sections: the user is answering a
///   different question, and a two-hit list doesn't need chapters.
/// - When fewer than two sections have members, no sections: a single header
///   over the whole list says nothing, and a row must then carry its own
///   context (see `showsHeaders`).
///
/// [sectionOf] names the section for each item — return the display label
/// directly. Sections listed in [leading] come first, in that order; the rest
/// follow alphabetically.
List<ExtensionSection<T>> sectionExtensionItems<T>({
  required List<T> items,
  required String Function(T) sectionOf,
  List<String> leading = const [],
  required bool filtered,
}) {
  if (filtered) return [ExtensionSection(label: '', items: items)];

  final groups = <String, List<T>>{};
  for (final item in items) {
    groups.putIfAbsent(sectionOf(item), () => []).add(item);
  }
  if (groups.length < 2) return [ExtensionSection(label: '', items: items)];

  final names = groups.keys.toList()
    ..sort((a, b) {
      final ai = leading.indexOf(a);
      final bi = leading.indexOf(b);
      if (ai != bi) {
        // Listed beats unlisted; among listed, the caller's order holds.
        if (ai == -1) return 1;
        if (bi == -1) return -1;
        return ai - bi;
      }
      return a.compareTo(b);
    });

  return [
    for (final name in names)
      ExtensionSection(label: name, items: groups[name]!),
  ];
}

/// True when [sections] will actually draw headers — the signal for a row to
/// drop context its header now carries (a skill row's category tag, say).
bool sectionsShowHeaders<T>(List<ExtensionSection<T>> sections) =>
    sections.any((section) => section.label.isNotEmpty);

/// The one list scaffold behind the extension screens: chaptered rows with the
/// shared rhythm — 8px between rows, 18px of air before a header so a new block
/// reads as a break rather than one more row.
class ExtensionList<T> extends StatefulWidget {
  const ExtensionList({
    super.key,
    required this.sections,
    required this.rowBuilder,
  });

  final List<ExtensionSection<T>> sections;
  final Widget Function(BuildContext context, T item) rowBuilder;

  @override
  State<ExtensionList<T>> createState() => _ExtensionListState<T>();
}

class _ExtensionListState<T> extends State<ExtensionList<T>> {
  /// Shared with the [Scrollbar] above the list. Handing each of them its own
  /// controller gives the position two attached scrollables and asserts — the
  /// same trap `grid_model_picker` documents.
  final _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final entries = <_Entry<T>>[
      for (final section in widget.sections) ...[
        if (section.label.isNotEmpty)
          _Header(section.label, section.items.length),
        for (final item in section.items) _Row(item),
      ],
    ];
    // The thumb rides in a gutter at the pane's edge and the rows stop short of
    // it, the same way the chat rail does. Left to itself the scrollbar paints
    // flush against the viewport's right edge — on top of the rows' rounded
    // corners and, on a row whose trailing control sits at the end, on top of
    // the control. `EdgeInsets.zero` is what put it there.
    return Scrollbar(
      controller: _controller,
      child: ListView.separated(
        controller: _controller,
        padding: const EdgeInsets.only(right: extensionScrollGutter),
        itemCount: entries.length,
        // Separators only ever fall between two entries, so the lookahead is in
        // range and the first header keeps its flush top edge.
        separatorBuilder: (context, i) =>
            SizedBox(height: entries[i + 1] is _Header<T> ? 18 : 8),
        itemBuilder: (context, i) => switch (entries[i]) {
          _Header<T>(:final label, :final count) => ExtensionSectionHeader(
            label: label,
            count: count,
          ),
          _Row<T>(:final item) => widget.rowBuilder(context, item),
        },
      ),
    );
  }
}

/// The clear space kept between the rows and the scrollbar thumb.
///
/// Also the right inset of the loading skeleton, so the placeholder rows and the
/// real ones occupy the same width and nothing shifts when the data lands.
const double extensionScrollGutter = 14;

sealed class _Entry<T> {
  const _Entry();
}

class _Header<T> extends _Entry<T> {
  const _Header(this.label, this.count);

  final String label;
  final int count;
}

class _Row<T> extends _Entry<T> {
  const _Row(this.item);

  final T item;
}
