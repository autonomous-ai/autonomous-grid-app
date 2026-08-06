import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'git_install.dart';
import 'git_probe.dart';
import 'git_repo.dart';
import 'host_environment.dart';

/// Riverpod wiring for Git.
///
/// Kept apart from [git_probe.dart] and [git_install.dart] so both stay plain
/// Dart: the probe is the piece most worth exercising directly, and a Flutter
/// import would make it unrunnable outside the framework.

/// The installer used across the app; tests override it with a fake so nothing
/// downloads 60 MB.
final gitInstallerProvider = Provider<GitInstaller>(
  (ref) => const GitInstallerImpl(),
);

/// Whether this computer has a Git that runs.
///
/// Kept as an [AsyncValue] rather than a bool so a screen can tell "still
/// looking" from "hasn't got one" — the difference between a quiet row and a row
/// telling the user to go and install something.
///
/// Anything that installs or removes Git has to invalidate this: the probe
/// spawns a process, so it is answered once and cached for the app's lifetime,
/// exactly like `agentInstalledProvider` (see `reprobeAgent`).
final gitStatusProvider = FutureProvider<GitStatus>((ref) => probeGit());

/// Whether Git is ready to use, for the callers that only need yes or no.
/// Unresolved reads as *not yet* rather than *missing*, so nothing tells the
/// user to install Git while the probe is still running.
final gitReadyProvider = Provider<bool>(
  (ref) => ref.watch(gitStatusProvider).value is GitReady,
);

/// Git against a folder on this computer — what a project's folder is, and
/// starting a repository in one that has none.
///
/// Reads [gitStatusProvider] rather than probing again, so the service that
/// runs Git and the screen that reports it can never disagree about which Git
/// that is.
final gitRepoServiceProvider = Provider<GitRepoService>(
  (ref) => GitRepoServiceImpl(() => ref.read(gitStatusProvider.future)),
);

/// Point the spawn environment at the Git that will actually be used — and, if
/// that is the machine's own, explicitly at nothing, so ours never shadows it.
///
/// Shared rather than private to either caller: the background pass and the Git
/// screen's Install button both change which Git a later `hermes` or `grid`
/// spawn resolves, and a copy of this that drifted would leave one of them
/// running a Git the app didn't choose.
void adoptGit(GitReady status) {
  HostEnvironment.adoptGridGit(
    status.ours ? File(status.path).parent.path : null,
  );
}
