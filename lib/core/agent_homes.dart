import 'dart:io';

/// Where Grid keeps the agent configuration it owns, kept out of the folders the
/// user's own copies of those agents read.
///
/// **Why this file exists.** Grid used to write straight into `~/.hermes`,
/// `~/.codex/skills` and `~/.claude/skills`. Those are the user's homes, shared
/// with every terminal on the machine: a colleague ran `ls ~/.claude/skills`
/// inside an unrelated repo on 2026-08-21 and found nine `grid-*` cards, and the
/// app had also rewritten `~/.hermes/config.yaml` — which pins their model,
/// narrows `toolsets:` to an allowlist and sets `approvals.mode`. Installing one
/// desktop app is not permission to change how somebody's CLI behaves.
///
/// Each agent gives a different lever, so this holds the one answer per agent
/// rather than letting twenty call sites each guess:
///
/// * **Hermes** — profile mode. `HERMES_HOME=<root>/profiles/grid` is
///   first-class: `hermes_constants.py` resolves profile-scoped data (config,
///   skills, memories, provider config) from it while `get_default_hermes_root`
///   still returns `~/.hermes`, so `hermes profile list` keeps seeing it. Grid's
///   Hermes becomes a profile beside the user's, not a rewrite of it.
/// * **Codex** — no lever for skills at all (`$CODEX_HOME/skills` is the only
///   path it reads, and `CODEX_HOME` takes auth with it), so Grid's cards reach
///   it as MCP tools instead, injected per process with `-c`.
/// * **Claude Code** — same: `--mcp-config` + `--strict-mcp-config` are already
///   per-session, so nothing needs to land in `~/.claude` either.
class AgentHomes {
  const AgentHomes._();

  /// The user's own Hermes root — `~/.hermes`. Never written by the app any
  /// more, but still read: it is where the install lives, and where the files
  /// below are physically kept.
  static String hermesRoot(String userHome) => '$userHome/.hermes';

  /// Grid's Hermes profile — `~/.hermes/profiles/grid`.
  ///
  /// The value of `HERMES_HOME` for every Hermes process the app starts, and the
  /// directory every app-owned Hermes file resolves under.
  static String hermesProfile(String userHome) =>
      '${hermesRoot(userHome)}/profiles/$kGridHermesProfile';

  /// What the app's Hermes profile is called, in `hermes profile list` and on
  /// disk. Named after the product, because the user will meet it there and
  /// "grid" is the only word that explains what put it on their machine.
  static const String kGridHermesProfile = 'grid';

  /// The files that stay in [hermesRoot] and are reached from the profile by a
  /// symlink, because a **long-running daemon already holds them** under the
  /// root home.
  ///
  /// `hermes cron` and the messaging gateway are started once and outlive the
  /// app. Give the profile its own copies and the same job exists twice — the
  /// root daemon still firing the old one, the profile daemon firing the new —
  /// which is worse than the leak this whole file is closing. One physical copy
  /// under two homes cannot double-fire, and the user's scheduled tasks survive
  /// the move without being migrated at all.
  ///
  /// `.env` and `auth.json` are here for the same reason from the other end:
  /// they hold credentials the user set up, and a profile that could not read
  /// them would look like being logged out.
  static const List<String> kSharedWithRoot = [
    '.env',
    'auth.json',
    'cron',
    'gateway_state.json',
  ];
}

/// Creates Grid's Hermes profile and the links back to the shared root files.
///
/// Idempotent, and deliberately re-run on every launch rather than once: a
/// symlink is only as good as the writer at the other end, and a tool that
/// replaces a file by writing a temp and renaming it over the top leaves a real
/// file where the link was. Re-establishing them each launch turns that from a
/// silent divergence into a line in the log.
///
/// Returns the profile path so the caller can hand it to `HERMES_HOME`.
Future<String> ensureGridHermesProfile(
  String userHome, {
  void Function(String message)? log,
}) async {
  final root = AgentHomes.hermesRoot(userHome);
  final profile = AgentHomes.hermesProfile(userHome);
  await Directory(profile).create(recursive: true);

  for (final name in AgentHomes.kSharedWithRoot) {
    final target = '$root/$name';
    final link = '$profile/$name';
    // Nothing to point at yet — a machine where the gateway has never run has
    // no gateway_state.json, and linking to a missing file would only make the
    // first write land somewhere nobody reads.
    if (!await _exists(target)) continue;
    final type = await FileSystemEntity.type(link, followLinks: false);
    if (type == FileSystemEntityType.link) continue;
    if (type != FileSystemEntityType.notFound) {
      // A real file where the link should be: something wrote through and
      // replaced it. Say so — the profile has been diverging from the root ever
      // since, and which of the two is right is not this function's call.
      log?.call('hermes profile: $name is a real file, not a link to $target');
      continue;
    }
    await Link(link).create(target);
  }
  await _seedConfig(root, profile, log);
  return profile;
}

/// Copies the root's `config.yaml` into a brand-new profile, once.
///
/// Without it, the first launch after this change hands Hermes an empty home:
/// no provider, no model, no toolsets — and the app only repoints it on the
/// next chat turn or task creation, so anything that ran before that would fail
/// with "no model configured" against a machine that had been working for
/// months. Copying the settings the app itself wrote makes the move invisible,
/// and from here the app edits the profile and leaves the root alone forever.
///
/// **Only when the profile has none.** A second copy would overwrite whatever
/// the app has since written to the profile with a root file nothing maintains.
Future<void> _seedConfig(
  String root,
  String profile,
  void Function(String message)? log,
) async {
  final source = File('$root/config.yaml');
  final destination = File('$profile/config.yaml');
  if (await destination.exists() || !await source.exists()) return;
  await source.copy(destination.path);
  log?.call('hermes profile: seeded config.yaml from $root');
}

Future<bool> _exists(String path) async =>
    await FileSystemEntity.type(path, followLinks: false) !=
    FileSystemEntityType.notFound;
