import 'dart:convert';
import 'dart:io';

import 'host_environment.dart';

/// The Node major version `hermes --tui` needs.
///
/// Hermes documents ≥20 for the TUI bundle. The rest of Hermes is Python and
/// needs none of this, which is the whole reason the check exists: a machine
/// where the ACP lane answers every turn perfectly is a machine where the
/// terminal lane can still be unable to start.
const int kHermesTuiNodeMajor = 20;

/// The major version of the `node` the app's own spawns would find, or null when
/// there is none it can reach.
///
/// **Probed with [HostEnvironment.path], not the shell's.** What matters is the
/// `PATH` handed to the pty, since that is the environment `hermes --tui` will
/// actually be started in — a Node the user can run in their own terminal but
/// the app cannot see is, from here, no Node at all.
Future<int?> probeNodeMajor() async {
  try {
    final result = await Process.run(
      'node',
      const ['--version'],
      environment: {...Platform.environment, 'PATH': HostEnvironment.path()},
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
      // Without this the bare name is looked up in the *parent's* PATH on some
      // platforms, which is the one thing this probe is trying not to ask.
      runInShell: false,
    );
    if (result.exitCode != 0) return null;
    return _majorOf((result.stdout as String).trim());
  } on Object {
    // A missing binary throws rather than exiting non-zero, and that is the
    // commonest answer here, not an error worth reporting as one.
    return null;
  }
}

/// `v24.13.0` → 24. Null for anything that is not a version at all.
int? _majorOf(String output) {
  final match = RegExp(r'^v?(\d+)\.').firstMatch(output);
  final major = match?.group(1);
  return major == null ? null : int.tryParse(major);
}

/// Whether this computer can run the Hermes TUI at all.
Future<bool> probeHermesTuiReady() async =>
    (await probeNodeMajor() ?? 0) >= kHermesTuiNodeMajor;
