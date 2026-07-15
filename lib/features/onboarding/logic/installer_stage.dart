/// The steps a brand-new computer goes through before it can be asked how its
/// grid gets a model, in order.
///
/// They are shown to the user as a checklist, so they are named for what the
/// person gets — not for the command that runs (`join`, `hermes` mean nothing to
/// them). The engine isn't here: running a model on this computer is a choice the
/// user makes on the screen after setup, so it's installed only then.
enum InstallerStage {
  grid('Set up your grid', 'Your own private space for AI.'),
  agent(
    'Install the assistant',
    'The part that can use tools and act on what '
        'you ask.',
  );

  const InstallerStage(this.title, this.detail);

  final String title;
  final String detail;
}

/// Where a step is. [done] also covers "was already there" — a machine that
/// already has the engine doesn't install it twice, and the user sees it ticked.
enum InstallStatus { pending, running, done, failed }

/// One row of the installer checklist.
class InstallerRow {
  const InstallerRow({required this.stage, required this.status, this.message});

  final InstallerStage stage;
  final InstallStatus status;

  /// Why this step failed, in the user's terms. Null unless [status] is failed.
  final String? message;
}
