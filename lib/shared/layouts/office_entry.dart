import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/office/logic/office_doc_chat.dart';
import '../../features/office/logic/office_doc_controller.dart';
import '../../features/office/logic/office_doc_state.dart';
import '../../features/office/presentation/discard_changes_dialog.dart';
import 'shell_state.dart';

/// The rail's way into an Office app.
///
/// In `shared/layouts` because three rails use it — the sidebar's Office group,
/// the folded mini rail, and ⌘K — and none of them may reach into another
/// feature's internals to do it (§1). It is navigation, which is what this
/// folder is for.
///
/// Docs is not merely selected: it is **entered fresh**. A conversation in Docs
/// belongs to one document, so arriving with no document chosen has to arrive
/// with no conversation either — otherwise whatever chat was last on screen
/// would sit beside the file the user is about to open and quietly become its
/// chat. The empty desk and the empty compose are the same gesture.
///
/// Returning to a document you were working on is the *other* door: its own row
/// in the sidebar, which opens the chat and the file together (see
/// `openChat`).
Future<void> enterOfficeApp(
  BuildContext context,
  WidgetRef ref,
  ShellSection app,
) async {
  if (app != ShellSection.officeDocs) {
    ref.read(shellSectionProvider.notifier).select(app);
    return;
  }
  // The one click in Docs that can lose typing nobody has saved — so it asks,
  // in the same words opening another document asks.
  final open = ref.read(officeDocProvider);
  if (open is OfficeDocOpen && open.dirty) {
    final ok = await confirmDiscardChanges(context, open.name);
    if (!ok) return;
  }
  ref.read(officeDocProvider.notifier).close();
  ref.read(officeDocChatProvider.notifier).startFresh();
  ref.read(shellSectionProvider.notifier).select(ShellSection.officeDocs);
}
