import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/app_spinner.dart';
import '../../../../shared/widgets/error_box.dart';
import '../../../../shared/widgets/toast.dart';
import '../../logic/commit_action.dart';
import '../../logic/commit_controller.dart';
import '../../logic/commit_message_writer.dart';
import '../../logic/review_file.dart';
import '../../logic/review_snapshot.dart';
import '../../../../shared/widgets/menu_row.dart';
import 'review_mark.dart' show ChangeCount;
import 'review_toolbar.dart' show ReviewBranchLine;

/// What the commit control opens: what to say about the change, what to put in
/// it, and the three things that can be done with it.
///
/// A panel under the button rather than a dialog over the app, because
/// committing is the last step of reading a diff — a modal that greys out the
/// changes you were describing takes away the only thing you needed to write
/// the message. It also means the message box and the actions are one surface
/// instead of a form with a button bar.
class CommitPopover extends ConsumerStatefulWidget {
  const CommitPopover({
    super.key,
    required this.snapshot,
    required this.folder,
    required this.onClose,
  });

  final ReviewSnapshot snapshot;
  final String folder;

  /// Dismisses the panel — after it finishes, or when the user asks.
  final VoidCallback onClose;

  /// Wide enough for "Commit and push" beside its glyph, and for a message of
  /// a sensible length to be readable while it is typed.
  static const double width = 320;

  @override
  ConsumerState<CommitPopover> createState() => _CommitPopoverState();
}

class _CommitPopoverState extends ConsumerState<CommitPopover> {
  final _message = TextEditingController();
  late bool _includeUnticked;

  /// A draft being written, and why the last attempt didn't produce one.
  ///
  /// Local to the panel rather than a provider: a half-written message belongs
  /// to the box it is being written into, and the panel is closed the moment
  /// the commit it feeds is made.
  bool _writing = false;
  String? _writeFailed;

  @override
  void initState() {
    super.initState();
    // On when nothing is ticked, off when the user has already picked files —
    // the same reading [commitActionFor] makes, so the panel opens agreeing
    // with the button that opened it.
    _includeUnticked =
        commitActionFor(widget.snapshot) == CommitAction.commitAll;
    // The controller outlives this panel, so a failure from the last attempt
    // would otherwise be the first thing the user sees.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(commitProvider(widget.folder).notifier).reset();
    });
  }

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final snapshot = widget.snapshot;
    final state = ref.watch(commitProvider(widget.folder));
    final running = state is CommitRunning;
    final unticked = _unticked(snapshot);
    final ready = !running && _message.text.trim().isNotEmpty && _hasContent();
    final canPush = snapshot.ahead > 0 && !snapshot.detached && !running;

    ref.listen(commitProvider(widget.folder), (_, next) => _onDone(next));

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, meta: true): () {
          if (ready) _commit(push: false);
        },
        const SingleActivator(LogicalKeyboardKey.escape): widget.onClose,
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(15, 11, 15, 9),
            child: ReviewBranchLine(snapshot: snapshot),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(15, 0, 15, 11),
            child: _Message(
              controller: _message,
              enabled: !running,
              // The actions turn on with the first character typed, so the
              // panel has to hear every one of them.
              onChanged: (_) => setState(() {}),
            ),
          ),
          if (_writeFailed != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(15, 0, 15, 10),
              child: Text(
                _writeFailed!,
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.35,
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ),
          const MenuDivider(),
          MenuRow(
            label: _writing ? 'Writing it…' : 'Write the message for me',
            icon: LucideIcons.sparkles,
            width: CommitPopover.width,
            // Not while a commit is in flight, and not with nothing to read:
            // a model asked to describe an empty change invents one.
            enabled: !running && !_writing && _hasContent(),
            trailing: _writing
                ? const AppSpinner(size: SpinnerSize.small)
                : null,
            onTap: _writeMessage,
          ),
          if (unticked.isNotEmpty && snapshot.scope.canStage)
            MenuRow(
              label: 'Include the files not ticked',
              icon: _includeUnticked
                  ? LucideIcons.squareCheck
                  : LucideIcons.square,
              width: CommitPopover.width,
              enabled: !running,
              trailing: ChangeCount(
                added: totalAdded(unticked),
                removed: totalRemoved(unticked),
              ),
              onTap: () => setState(() => _includeUnticked = !_includeUnticked),
            ),
          MenuRow(
            label: 'Commit',
            icon: LucideIcons.gitCommitHorizontal,
            width: CommitPopover.width,
            enabled: ready,
            trailing: const _Shortcut('⌘↵'),
            onTap: () => _commit(push: false),
          ),
          MenuRow(
            label: 'Commit and push',
            icon: LucideIcons.cloudUpload,
            width: CommitPopover.width,
            // A detached HEAD has no branch to push to; committing there is
            // still possible, and the row above still offers it.
            enabled: ready && !snapshot.detached,
            onTap: () => _commit(push: true),
          ),
          MenuRow(
            label: snapshot.ahead > 0
                ? 'Push ${snapshot.ahead} commit'
                      '${snapshot.ahead == 1 ? '' : 's'}'
                : 'Push',
            icon: LucideIcons.arrowUp,
            width: CommitPopover.width,
            enabled: canPush,
            onTap: _push,
          ),
          if (state is CommitRunning) _Step(step: state.step),
          if (state is CommitFailed) _Failure(state: state),
        ],
      ),
    );
  }

  /// The files the list is showing that a commit wouldn't carry as things
  /// stand — what the toggle would add.
  List<ReviewFile> _unticked(ReviewSnapshot snapshot) => [
    for (final file in snapshot.files)
      if (!file.staged) file,
  ];

  /// Whether a commit would carry anything at all: something ticked, or the
  /// toggle set to sweep the rest in.
  bool _hasContent() {
    if (widget.snapshot.staged.isNotEmpty) return true;
    return _includeUnticked && widget.snapshot.files.isNotEmpty;
  }

  /// Ask a model to describe the change, and put what it says in the box.
  ///
  /// Straight into the field, not committed: it is a draft the user reads and
  /// edits, which is also why a failure is a line under the box rather than a
  /// dialog — the box still works.
  Future<void> _writeMessage() async {
    setState(() {
      _writing = true;
      _writeFailed = null;
    });
    final (written, failed) = await ref
        .read(commitMessageWriterProvider)
        .write(snapshot: widget.snapshot, includeUnticked: _includeUnticked);
    if (!mounted) return;
    setState(() {
      _writing = false;
      _writeFailed = failed;
      if (written != null) {
        _message.text = written;
        // The caret at the end, so the first keystroke adds to the draft
        // instead of landing in the middle of it.
        _message.selection = TextSelection.collapsed(offset: written.length);
      }
    });
  }

  Future<void> _commit({required bool push}) => ref
      .read(commitProvider(widget.folder).notifier)
      .run(
        message: _message.text,
        push: push,
        includeUnticked: _includeUnticked,
      );

  Future<void> _push() =>
      ref.read(commitProvider(widget.folder).notifier).pushOnly();

  /// Close on success and say what happened, in the words of what actually took
  /// place — "Committed" when only that was asked for.
  void _onDone(CommitState state) {
    if (state is! CommitDone || !mounted) return;
    final toast = ToastScope.of(context);
    widget.onClose();
    toast?.show(
      ToastSpec(
        message: state.pushed
            ? 'Committed and pushed “${state.branch}”.'
            : 'Committed. It is on this computer only until you push.',
        severity: ToastSeverity.success,
      ),
    );
  }
}

/// The message box: no label and no rim, because the panel around it is the
/// label and a boxed field inside a floating panel reads as a form.
class _Message extends StatelessWidget {
  const _Message({
    required this.controller,
    required this.enabled,
    required this.onChanged,
  });

  final TextEditingController controller;
  final bool enabled;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return TextField(
      controller: controller,
      enabled: enabled,
      onChanged: onChanged,
      autofocus: true,
      minLines: 2,
      maxLines: 4,
      style: TextStyle(fontSize: 13, color: AppPalette.textPrimary),
      decoration: InputDecoration(
        hintText: 'What does this change do?',
        hintStyle: TextStyle(fontSize: 13, color: AppPalette.textFaint),
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        disabledBorder: InputBorder.none,
        filled: false,
        isDense: true,
        contentPadding: EdgeInsets.zero,
      ),
    );
  }
}

/// The keys that do the same thing as the row.
class _Shortcut extends StatelessWidget {
  const _Shortcut(this.keys);

  final String keys;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Text(
      keys,
      style: TextStyle(fontSize: 11.5, color: AppPalette.textFaint),
    );
  }
}

/// What is happening now — the two halves take very different amounts of time,
/// and "Pushing…" after a commit that already landed is the difference between
/// a hang and progress.
class _Step extends StatelessWidget {
  const _Step({required this.step});

  final String step;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(15, 6, 15, 12),
      child: Row(
        children: [
          const AppSpinner(size: SpinnerSize.small),
          const SizedBox(width: 8),
          Text(
            step,
            style: TextStyle(fontSize: 12.5, color: AppPalette.textSecondary),
          ),
        ],
      ),
    );
  }
}

/// Why it didn't finish, where the user asked for it.
class _Failure extends StatelessWidget {
  const _Failure({required this.state});

  final CommitFailed state;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(15, 6, 15, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ErrorBox(message: state.message, maxHeight: 120),
          if (state.committed) ...[
            const SizedBox(height: 8),
            Text(
              'The commit itself was made — only sending it on failed, so '
              'there is no need to commit again.',
              style: TextStyle(
                fontSize: 11.5,
                height: 1.35,
                color: AppPalette.textSecondary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
