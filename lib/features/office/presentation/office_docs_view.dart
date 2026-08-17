import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_spinner.dart';
import '../../../shared/widgets/composer_notice_bar.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/panel_splitter.dart';
import '../logic/office_doc_controller.dart';
import '../logic/office_doc_state.dart';
import '../logic/office_layout.dart';
import '../logic/office_view_mode.dart';
import 'widgets/docx_document_view.dart';
import 'widgets/office_chat_column.dart';
import 'widgets/office_doc_bar.dart';
import 'widgets/office_paper.dart';

/// Docs: a Word document on the right, the assistant beside it on the left.
///
/// The chat is on the *left* deliberately, where the app's own sidebar is and
/// where the reference this screen follows puts it: the document is the work, so
/// it takes the side of the window that grows, and the conversation keeps a fixed
/// column the eye returns to.
///
/// First version, and it is honest about that — text in, text out, no ribbon. See
/// `docx_edit.dart` for exactly what a save preserves and what it flattens.
class OfficeDocsView extends ConsumerWidget {
  const OfficeDocsView({super.key});

  /// What the page keeps when the chat is asked to give way, on any window wide
  /// enough to grant it.
  ///
  /// A wish, not a floor: at the app's own smallest window (880 wide, less the
  /// sidebar) there is not this much left over, and the chat's minimum wins —
  /// see [_chatWidth]. The chat's floor has to be the hard one because below it
  /// the composer overflows, where a narrow page only scrolls.
  static const _pageSideWantedWidth = 360.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final wanted = ref.watch(officeChatWidthProvider);
    final chat = ref.read(officeChatWidthProvider.notifier);
    return LayoutBuilder(
      builder: (context, constraints) => Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: _chatWidth(wanted, constraints.maxWidth),
            child: const OfficeChatColumn(),
          ),
          PanelSplitter(
            axis: Axis.vertical,
            onDrag: chat.nudge,
            onReset: chat.reset,
          ),
          const Expanded(child: _DocumentSide()),
        ],
      ),
    );
  }

  /// The chat column's width once the window has had its say.
  ///
  /// A remembered width can outlive the window it was chosen in — drag the seam
  /// wide on an external monitor, unplug it, and a plain `SizedBox` would leave
  /// the page a sliver. When there isn't room for both, the chat keeps its
  /// minimum and the page takes what is left: the page handles a squeeze by
  /// scrolling, the composer handles it by overflowing.
  static double _chatWidth(double wanted, double available) {
    final room = available - _pageSideWantedWidth - PanelSplitter.band;
    if (room < OfficeChatWidthNotifier.minimum) {
      return OfficeChatWidthNotifier.minimum;
    }
    return wanted > room ? room : wanted;
  }
}

/// The document half: its bar, anything that went wrong, and the page.
class _DocumentSide extends ConsumerWidget {
  const _DocumentSide();

  /// Narrower than this and an empty state keeps its words but drops its button:
  /// a button is a fixed width that cannot ellipsis, so past this point it stops
  /// being an offer and becomes a stripe pattern. Nothing is lost — the bar
  /// directly above carries the same Open, as a glyph by then.
  static const _buttonRoomWidth = 230.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final state = ref.watch(officeDocProvider);
    final open = state is OfficeDocOpen ? state : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OfficeDocBar(doc: open),
        // Reports, and offers nothing — because the offer is already on screen:
        // a failed save leaves the document dirty, so Save in the bar above is
        // live and is the retry. A "Try again" here would be a second door to
        // the same action, and one the bar has no room for at its narrowest.
        if (open?.save case OfficeSaveFailed(:final message))
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
            child: ComposerNoticeBar(
              icon: LucideIcons.triangleAlert,
              label: message,
            ),
          ),
        // The desk belongs to this half of the screen, not to any one state on
        // it: the page, the spinner while a file is read and both empty states
        // all sit on the same surface, so a document arriving doesn't repaint
        // the background under it.
        Expanded(
          child: ColoredBox(
            color: AppPalette.paperDesk,
            child: LayoutBuilder(
              builder: (context, constraints) => switch (state) {
                OfficeDocEmpty() => _NoDocument(
                  withAction: constraints.maxWidth >= _buttonRoomWidth,
                ),
                OfficeDocOpening(:final name) => LoadingView(
                  message: 'Opening $name…',
                ),
                OfficeDocOpen() => _OpenDocument(doc: state),
                OfficeDocFailed(:final name, :final message) => _CouldNotOpen(
                  name: name,
                  message: message,
                  withAction: constraints.maxWidth >= _buttonRoomWidth,
                ),
              },
            ),
          ),
        ),
      ],
    );
  }
}

/// The open document, in whichever view the user chose.
///
/// Formatted falls back to the text editor when the file's formatting couldn't be
/// read — the switch is disabled in that case, and this is the same decision made
/// where it has to hold: a mode that has nothing to draw must not draw a blank
/// page.
class _OpenDocument extends ConsumerWidget {
  const _OpenDocument({required this.doc});

  final OfficeDocOpen doc;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final layout = doc.layout;
    final mode = ref.watch(officeViewModeProvider);
    if (mode == OfficeViewMode.formatted && layout != null) {
      return DocxDocumentView(doc: layout);
    }
    return OfficePaper(doc: doc);
  }
}

/// Nothing open yet — so the screen's one job is to offer a document.
class _NoDocument extends ConsumerWidget {
  const _NoDocument({required this.withAction});

  final bool withAction;

  @override
  Widget build(BuildContext context, WidgetRef ref) => EmptyState(
    icon: LucideIcons.fileText300,
    title: 'No document open',
    message:
        'Open a Word document (.docx) to read and edit its text here, with '
        'the assistant beside it.',
    compact: !withAction,
    action: withAction
        ? FilledButton(
            onPressed: () => ref.read(officeDocProvider.notifier).pickAndOpen(),
            child: const Text('Open document'),
          )
        : null,
  );
}

/// The file couldn't be opened, in the words the controller chose — and the way
/// on, which is a different file.
class _CouldNotOpen extends ConsumerWidget {
  const _CouldNotOpen({
    required this.name,
    required this.message,
    required this.withAction,
  });

  final String name;
  final String message;
  final bool withAction;

  @override
  Widget build(BuildContext context, WidgetRef ref) => EmptyState(
    icon: LucideIcons.fileX300,
    title: "Couldn't open $name",
    message: message,
    compact: !withAction,
    action: withAction
        ? FilledButton(
            onPressed: () => ref.read(officeDocProvider.notifier).pickAndOpen(),
            child: const Text('Open another document'),
          )
        : null,
  );
}
