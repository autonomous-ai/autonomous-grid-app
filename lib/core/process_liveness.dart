/// Asking whether a process is still there, without touching it.
///
/// In `core/` rather than beside the engine list that first needed it: a paired
/// phone is now told which engines this computer is really serving, and
/// `infrastructure/` cannot reach up into a feature to ask (§1).
library;

import 'dart:io';

/// True if [pid] names a live process.
///
/// POSIX `kill -0` probes existence **without signalling** — the `-0` is the
/// whole point, and the reason this is a shelled-out `kill` rather than
/// `Process.killPid`: Dart's version always sends a real signal, so the obvious
/// "just call killPid" would stop the very engine it was asking about.
///
/// Where the probe is unavailable we cannot tell, so assume alive: every stop
/// path runs `grid leave` regardless, and reporting a live engine as dead is
/// the answer that makes somebody go and restart something already running.
bool pidIsAlive(int? pid) {
  if (pid == null) return false;
  if (Platform.isWindows) return true;
  try {
    return Process.runSync('kill', ['-0', '$pid']).exitCode == 0;
  } on ProcessException {
    return true;
  }
}
