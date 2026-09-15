import 'dart:io';

/// Make [file] readable and writable by its owner only (`chmod 600`).
///
/// Best-effort by design: on Windows there is no `chmod` and the file's ACL
/// already follows the user profile, and a sandbox may refuse to spawn a
/// process at all. Failing the write over this would be worse than the weaker
/// mode — the secret is already in a single-user home directory, and losing it
/// means whatever it unlocks silently stops working.
///
/// One copy for every store that keeps a secret on disk: connector tokens, a
/// connector's client registration, a manual server's key, the token Hermes is
/// handed, and the Telegram bot's token.
Future<void> restrictToOwner(File file) async {
  if (Platform.isWindows) return;
  try {
    await Process.run('chmod', ['600', file.path]);
  } on Object {
    // Nothing to do and nothing to say: see above.
  }
}
