part of 'new_job_dialog.dart';

/// A small uppercase label that opens a group of controls ("When it runs"). Gives
/// the dialog the sections it was missing — the controls used to pour into one
/// flat column with nothing to say where one concern ended and the next began.
class _GroupLabel extends StatelessWidget {
  const _GroupLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.8,
        color: AppPalette.textFaint,
      ),
    );
  }
}

/// Picks the assistant that answers the task when it fires.
///
/// Shown because the scheduler's own agent used to answer everything: a task
/// set up while talking to Claude Code was run by Hermes, with none of Claude's
/// tools or skills, and nothing said so.
class _RunnerRow extends StatelessWidget {
  const _RunnerRow({
    required this.runner,
    required this.installed,
    required this.onChanged,
  });

  final TaskRunner runner;

  /// The runners this computer can actually run. An agent that isn't installed
  /// is left off rather than offered and then failing at 8am.
  final List<TaskRunner> installed;

  final ValueChanged<TaskRunner> onChanged;

  @override
  Widget build(BuildContext context) => AppSelectField<TaskRunner>(
    label: 'Which assistant runs it',
    showLabel: false,
    value: runner,
    options: [
      for (final option in installed)
        AppSelectOption(
          value: option,
          label: option.agent.name,
          detail: option == TaskRunner.hermes
              ? 'Answers with the model below'
              : 'Answers on its own sign-in and model',
        ),
    ],
    onChanged: onChanged,
  );
}

/// Picks where a finished run's answer is put.
class _DestinationRow extends StatelessWidget {
  const _DestinationRow({
    required this.destination,
    required this.chats,
    required this.projects,
    required this.onChanged,
  });

  final TaskDestination destination;

  /// The conversations worth offering: the user's own, newest first. A task's
  /// own chat is not among them — it is the default above.
  final List<Conversation> chats;

  final List<Project> projects;
  final ValueChanged<TaskDestination> onChanged;

  @override
  Widget build(BuildContext context) => AppSelectField<String>(
    label: 'Where the answer goes',
    showLabel: false,
    value: taskDeliverValue(destination),
    options: [
      AppSelectOption(
        value: taskDeliverValue(const TaskOwnChat()),
        label: 'A chat of its own',
        detail: 'Every run of this task in one thread',
      ),
      for (final project in projects)
        AppSelectOption(
          value: taskDeliverValue(TaskProjectDestination(project.id)),
          label: project.name,
          detail: 'Filed under this project',
        ),
      for (final chat in chats)
        AppSelectOption(
          value: taskDeliverValue(TaskChatDestination(chat.id)),
          label: chat.title,
          detail: 'Into this conversation',
        ),
    ],
    onChanged: (value) => onChanged(parseTaskDeliver(value)),
  );
}

/// One-tap example prompts under the "what should it do?" box — the cure for the
/// blank field. Tapping one fills the prompt (and the schedule) so the user
/// edits an example rather than inventing a task from nothing.
class _ExampleRow extends StatelessWidget {
  const _ExampleRow({required this.onPick});

  final ValueChanged<JobSuggestion> onPick;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(Icons.auto_awesome_rounded, size: 14, color: AppPalette.textFaint),
        const SizedBox(width: 7),
        Text(
          'Try:',
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: AppFont.medium,
            color: AppPalette.textFaint,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Wrap(
            spacing: 7,
            runSpacing: 7,
            children: [
              for (final example in kJobSuggestions)
                _ExampleChip(label: example.name, onTap: () => onPick(example)),
            ],
          ),
        ),
      ],
    );
  }
}

class _ExampleChip extends StatelessWidget {
  const _ExampleChip({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(999);
    return Material(
      color: Colors.transparent,
      borderRadius: radius,
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: radius,
            border: Border.all(color: AppPalette.divider),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: AppFont.medium,
              color: AppPalette.accent,
            ),
          ),
        ),
      ),
    );
  }
}

/// A labelled text field: a fixed label above, then a bordered input that lifts
/// to the accent on focus.
///
/// Material's floating label was the problem — on the multi-line prompt it sat
/// mid-box and read as placeholder text, and the borderless grey fill gave the
/// field no edge at all. A hard label plus a real border restores the hierarchy.
class _TaskField extends StatefulWidget {
  const _TaskField({
    required this.controller,
    required this.label,
    required this.hint,
    required this.onChanged,
    this.autofocus = false,
    this.minLines = 1,
    this.maxLines = 1,
  });

  final TextEditingController controller;
  final String label;
  final String hint;
  final VoidCallback onChanged;
  final bool autofocus;
  final int minLines;
  final int maxLines;

  @override
  State<_TaskField> createState() => _TaskFieldState();
}

class _TaskFieldState extends State<_TaskField> {
  final _focus = FocusNode();
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() => _focused = _focus.hasFocus));
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: AppFont.medium,
            color: _focused ? AppPalette.accent : AppPalette.textSecondary,
          ),
        ),
        const SizedBox(height: 7),
        // The rim and its accent focus ring come from inputDecorationTheme, so
        // this only says what's specific to the field: how tall, and its hint.
        TextField(
          controller: widget.controller,
          focusNode: _focus,
          autofocus: widget.autofocus,
          minLines: widget.minLines,
          maxLines: widget.maxLines,
          onChanged: (_) => widget.onChanged(),
          style: const TextStyle(fontSize: 14.5, height: 1.35),
          decoration: InputDecoration(
            hintText: widget.hint,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 11,
            ),
          ),
        ),
      ],
    );
  }
}
