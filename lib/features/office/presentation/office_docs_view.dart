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
import 'widgets/office_chat_column.dart';
import 'widgets/office_doc_bar.dart';
import 'widgets/office_editor_view.dart';
import 'widgets/office_rulers.dart';
import 'widgets/office_toolbar.dart';

/// Docs: a Word document on the right, the assistant beside it on the left.
///
/// The chat is on the *left* deliberately, where the app's own sidebar is and
/// where the reference this screen follows puts it: the document is the work, so
/// it takes the side of the window that grows, and the conversation keeps a fixed
/// column the eye returns to.
///
/// One view over the file, and it is the editable one. There was a second — a
/// faithful read-only render by `docx_file_viewer` — kept while the editor
/// couldn't draw pictures. It went when the editor could: the package's reader
/// dropped the text of list items whose content is one paragraph of soft breaks,
/// so the prettier view was the one that quietly lost words.
///
/// No ribbon: nothing here formats text. See `docx_edit.dart` for exactly what a
/// save preserves and what it flattens.
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
            // No hover mark on this one — it stays a plain hairline and the
            // resize cursor does the talking. See [PanelSplitter.highlightOnHover]:
            // beside the page's light chrome, a lit seam reads as a caret in
            // accent and as a white rule in grey.
            highlightOnHover: false,
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
        // Only with a document on the desk: a toolbar over an empty screen
        // formats nothing, and every control on it would be greyed out.
        if (open != null) OfficeToolbar(doc: open),
        // The file moved on under the document — the assistant edited it — and
        // there are unsaved edits here, so the app didn't choose between them.
        // This is the one notice that carries an action, because the way out
        // isn't on screen anywhere else.
        if (open != null && open.staleOnDisk)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
            child: ComposerNoticeBar(
              icon: LucideIcons.fileClock,
              label:
                  '${open.name} changed on disk. Your edits here are not in '
                  'the file, and saving them would undo that change.',
              actions: [
                TextButton(
                  onPressed: () =>
                      ref.read(officeDocProvider.notifier).reloadFromDisk(),
                  child: const Text('Reload'),
                ),
              ],
            ),
          ),
        // Reports, and offers nothing — because the offer is already on screen:
        // a failed save leaves the document dirty, so Save in the bar above is
        // live and is the retry. A "Try again" here would be a second door to
        // the same action, and one the bar has no room for at its narrowest.
        // The stale-file failure is the exception, and the notice above carries
        // its action instead.
        if (open?.save case OfficeSaveFailed(
          :final message,
        ) when !(open?.staleOnDisk ?? false))
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
            child: ComposerNoticeBar(
              icon: LucideIcons.triangleAlert,
              label: message,
            ),
          ),
        // The desk is drawn by the page, not by this half of the screen.
        //
        // It used to sit under every state here, so a document arriving didn't
        // repaint the background — which was right while the desk followed the
        // app's theme. It doesn't any more ([AppPalette.paperDesk] is one fixed
        // grey now), and these three states are written in the app's own ink:
        // on a dark theme that put near-white words on a light grey desk. A
        // desk with no page on it is furniture for nothing.
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) => switch (state) {
              OfficeDocEmpty() => _NoDocument(
                withAction: constraints.maxWidth >= _buttonRoomWidth,
              ),
              OfficeDocOpening(:final name) => LoadingView(
                message: 'Opening $name…',
              ),
              OfficeDocOpen() => _RuledPage(doc: state),
              OfficeDocFailed(:final name, :final message) => _CouldNotOpen(
                name: name,
                message: message,
                withAction: constraints.maxWidth >= _buttonRoomWidth,
              ),
            },
          ),
        ),
      ],
    );
  }
}

/// The page with its two rulers around it.
///
/// The vertical strip takes its width out of the row **before** the page is
/// centred, and the horizontal ruler is inset by that same width — so both
/// rulers and the paper agree about where the middle is. Laid out the other way
/// round, the ruler's inch marks sit 22px off the margin they are supposed to
/// be measuring, which is worse than having no ruler.
class _RuledPage extends StatelessWidget {
  const _RuledPage({required this.doc});

  final OfficeDocOpen doc;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          // The corner where the two rulers meet, in their own colour — a
          // spreadsheet's blank corner box. Left transparent it was a notch of
          // app surface cut out of the light strip.
          const ColoredBox(
            color: AppPalette.paperChrome,
            child: SizedBox(
              width: OfficeVerticalRuler.width,
              height: OfficeHorizontalRuler.height,
            ),
          ),
          Expanded(child: OfficeHorizontalRuler(doc: doc)),
        ],
      ),
      Expanded(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const OfficeVerticalRuler(),
            Expanded(child: OfficeEditorView(doc: doc)),
          ],
        ),
      ),
    ],
  );
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
        'Open a Word document (.docx) — or start an empty one. Either way the '
        'assistant works beside it, in a chat that belongs to that file.',
    compact: !withAction,
    // Two ways in, and the order says which is which: most people arrive with a
    // file. Starting from nothing is the quieter button, not a hidden one.
    action: withAction
        ? Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              FilledButton(
                onPressed: () =>
                    ref.read(officeDocProvider.notifier).pickAndOpen(),
                child: const Text('Open document'),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () =>
                    ref.read(officeDocProvider.notifier).createBlank(),
                child: const Text('New blank document'),
              ),
            ],
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
