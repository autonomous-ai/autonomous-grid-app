import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Which way Docs is showing the open document.
///
/// Two views over one file, and each is honest about what it can do rather than
/// one screen that half-does both:
enum OfficeViewMode {
  /// The document as it really is — the page size its `w:sectPr` asks for, its
  /// styles, tables, pictures, headers and footers, drawn by `docx_file_viewer`.
  /// Read-only, and faithful.
  read('Read'),

  /// The document's paragraphs, editable, carrying enough of their formatting to
  /// be recognisable. Where the caret goes.
  edit('Edit');

  const OfficeViewMode(this.label);

  /// The word on the switch. Carried here so the control and the mode can't drift
  /// apart.
  final String label;
}

/// The open view. Session state, and deliberately not per document: someone who
/// prefers to type wants the next document open for typing too.
final officeViewModeProvider =
    NotifierProvider<OfficeViewModeNotifier, OfficeViewMode>(
      OfficeViewModeNotifier.new,
    );

class OfficeViewModeNotifier extends Notifier<OfficeViewMode> {
  /// Opens on Read: it is what the document actually looks like, and a person
  /// opening a file wants to see it before they change it.
  @override
  OfficeViewMode build() => OfficeViewMode.read;

  void select(OfficeViewMode mode) => state = mode;

  void toggle() => state = state == OfficeViewMode.read
      ? OfficeViewMode.edit
      : OfficeViewMode.read;
}
