import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Which way Docs is showing the open document.
///
/// Two views over one file, and each is honest about what it can do — which is
/// why they are separate rather than one half-capable screen:
enum OfficeViewMode {
  /// The document as the document: its fonts, alignment, spacing, tables and
  /// pictures, read from the file's own styles. Read-only, because editing what
  /// you see means editing runs, not lines.
  formatted('Formatted'),

  /// The document's words in one editable column. No formatting, and none lost —
  /// a save rewrites only the paragraphs whose text changed.
  text('Text');

  const OfficeViewMode(this.label);

  /// The word on the switch. Carried here so the control and the mode can't
  /// drift apart.
  final String label;
}

/// The open view. Session state, and deliberately not per document: someone who
/// prefers to read formatted wants the next document formatted too.
final officeViewModeProvider =
    NotifierProvider<OfficeViewModeNotifier, OfficeViewMode>(
      OfficeViewModeNotifier.new,
    );

class OfficeViewModeNotifier extends Notifier<OfficeViewMode> {
  /// Opens formatted: it is what the document actually looks like, and a person
  /// opening a file wants to read it before they change it.
  @override
  OfficeViewMode build() => OfficeViewMode.formatted;

  void select(OfficeViewMode mode) => state = mode;

  void toggle() => state = state == OfficeViewMode.formatted
      ? OfficeViewMode.text
      : OfficeViewMode.formatted;
}
