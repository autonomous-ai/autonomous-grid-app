import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/chip_remove_button.dart';
import '../../../../shared/widgets/composer_buttons.dart';
import '../../../../shared/widgets/composer_keys.dart';
import '../../../../shared/widgets/liquid_glass.dart';
import '../../../../shared/widgets/toast.dart';
import '../../logic/code_argv.dart';
import '../../logic/code_side_panel.dart';
import '../../logic/project_flow.dart';

/// The box at the foot of a project: say what should be done, attach anything
/// the agent will need, and the grid runs it.
///
/// The same box as the chat's, minus the two pickers — nobody chooses the agent
/// or the model here, because the computer that claims the task brings its own.
/// Everything else is deliberately identical, down to Enter sending and the
/// round knob on the right: asking a computer to do something is one gesture,
/// and it had to stop being a dialog to feel like one.
class TaskComposer extends ConsumerStatefulWidget {
  const TaskComposer({
    super.key,
    required this.projectId,
    required this.slotHeld,
  });

  final String projectId;

  /// A task of this member's is still going, and the grid takes one at a time
  /// per project. The draft stays typable — the notice above says why Send is
  /// off, and the running task is a few inches up with a Stop under it.
  final bool slotHeld;

  @override
  ConsumerState<TaskComposer> createState() => _TaskComposerState();
}

class _TaskComposerState extends ConsumerState<TaskComposer> {
  final _prompt = TextEditingController();

  /// Paths on this computer, uploaded with the task and committed before any
  /// provider can claim it — so the agent always finds them.
  final _files = <String>[];

  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Send is gated on there being something to send, so the row has to redraw
    // as the box fills and empties.
    _prompt.addListener(_onChanged);
  }

  @override
  void dispose() {
    _prompt.removeListener(_onChanged);
    _prompt.dispose();
    super.dispose();
  }

  void _onChanged() => setState(() {});

  bool get _canSend =>
      !_busy && !widget.slotHeld && _prompt.text.trim().isNotEmpty;

  Future<void> _attach() async {
    final file = await openFile();
    if (file == null || !mounted) return;
    setState(() => _files.add(file.path));
  }

  /// Hand the task to the grid, catching up first.
  ///
  /// The box is cleared on the way *out*, not on the way in: nothing goes into
  /// the transcript until the flow has caught up and the relay has taken the
  /// task, so clearing early would throw away a paragraph somebody typed the
  /// moment either step refused it. A conflict on catch-up is one such refusal —
  /// the flow throws, the text stays, and the message says a merge is running
  /// first.
  Future<void> _send() async {
    if (!_canSend) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(projectFlowProvider(widget.projectId).notifier)
          .submit(
            prompt: _prompt.text.trim(),
            files: [for (final path in _files) fileSpec(path)],
          );
      if (!mounted) return;
      setState(() {
        _prompt.clear();
        _files.clear();
      });
    } on Object catch (error) {
      if (!mounted) return;
      ToastScope.show(
        context,
        ToastSpec(message: '$error', severity: ToastSeverity.error),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    // Review's "ask about this" drops its message here rather than sending it,
    // the same way the chat's panels hand a message to its composer. Put in the
    // box, ready to edit, so the request is still the user's to word and send.
    ref.listen(codeComposerPrefillProvider, (_, text) {
      if (text == null) return;
      _prompt.text = text;
      _prompt.selection = TextSelection.collapsed(offset: text.length);
      ref.read(codeComposerPrefillProvider.notifier).taken();
    });
    return LiquidGlass(
      borderRadius: BorderRadius.circular(18),
      fill: AppGlass.surfaceFill,
      shadow: AppSurface.composerShadow,
      showBorder: true,
      borderColor: AppGlass.lift,
      borderWidth: 1.5,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_files.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (var i = 0; i < _files.length; i++)
                    _PathChip(
                      path: _files[i],
                      onRemove: () => setState(() => _files.removeAt(i)),
                    ),
                ],
              ),
            ),
          ComposerKeys(
            canSend: _canSend,
            onSend: _send,
            builder: (context, focusNode) => TextField(
              controller: _prompt,
              focusNode: focusNode,
              minLines: 1,
              maxLines: 6,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              style: const TextStyle(fontSize: 15),
              decoration: const InputDecoration(
                hintText: 'What should the agent do?',
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                disabledBorder: InputBorder.none,
                contentPadding: EdgeInsets.fromLTRB(18, 17, 18, 20),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                ComposerIconButton(
                  icon: LucideIcons.paperclip300,
                  tooltip: 'Send a file along with the task',
                  onPressed: _busy ? null : _attach,
                ),
                ComposerSendButton(
                  sending: _busy,
                  canSend: _canSend,
                  onSend: _send,
                  // Nothing to stop from here: a task is stopped from its own
                  // turn in the transcript, where the thing being stopped is
                  // visible.
                  onStop: null,
                  busyTooltip: 'Catching up, then sending…',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One file riding on the task being written, by the name it has on disk.
///
/// The whole path is in the tooltip: two files called `config.toml` from
/// different folders are one chip apart, and the basename alone cannot tell
/// them apart.
class _PathChip extends StatelessWidget {
  const _PathChip({required this.path, required this.onRemove});

  final String path;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Tooltip(
      message: path,
      child: Container(
        padding: const EdgeInsets.fromLTRB(9, 7, 2, 7),
        constraints: const BoxConstraints(maxWidth: 240),
        decoration: BoxDecoration(
          color: AppPalette.cardBg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppPalette.divider),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                path.split(RegExp(r'[/\\]')).last,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  color: AppPalette.textSecondary,
                ),
              ),
            ),
            ChipRemoveButton(onTap: onRemove, semanticLabel: 'Remove file'),
          ],
        ),
      ),
    );
  }
}
