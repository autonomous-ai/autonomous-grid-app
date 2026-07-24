import 'installer_controller.dart';

/// What the installer's header says, as pure functions of where the install is.
///
/// The headline changes with the state rather than staying a static "Setting
/// up…": on a failure it must not keep implying work is happening, and when it
/// finishes it should say so.
String installerHeadline(InstallerState state) => switch (state) {
  InstallerFailed() => "Setup didn't finish",
  InstallerDone() => 'Ready',
  _ => 'Setting up your AI',
};

/// One honest line about what is happening. Setup here is quick — just the
/// assistant — and "done" leads to choosing how the grid gets a model, so it
/// mustn't promise a model download that only the "run local" choice starts.
String installerSubtitle(InstallerState state) => switch (state) {
  InstallerFailed() =>
    'You can try again, or go in and use an engine someone else shares.',
  InstallerDone() =>
    "You're all set — next, choose how your grid gets a model.",
  InstallerRunning() => 'This only takes a moment.',
  _ => 'Grid will set this computer up for you.',
};
