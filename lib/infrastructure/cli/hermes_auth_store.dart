import '../../core/agent_homes.dart';
import 'dart:convert';
import 'dart:io';

import '../../core/grid_paths.dart';
import '../../core/relay_identity.dart';

/// Clears grids the app is no longer pointing at out of Hermes's own credential
/// store (`~/.hermes/auth.json`).
///
/// Hermes doesn't read a key straight out of its config each turn. It files
/// credentials into a **pool** keyed by the provider's name, remembers each
/// one's `base_url`, and rotates between them on failure —
/// `run_agent.py:_swap_credential` takes the key from the pooled entry and the
/// URL from `entry.base_url or self.base_url`, so a pooled row that outlived
/// the grid it was minted for can pair an old key with the current endpoint.
/// The relay answers that with `401 Invalid Grid token: Audience doesn't match`
/// (see [relayCredentialMismatch]), inside the assistant's turn, where the user
/// reads it as the assistant failing.
///
/// The app can't ask a user to hand-edit JSON in a hidden directory, and there
/// is no way to reach the machines this has already happened on — so the repair
/// has to be something the app does to itself, on the way to the next message.
/// Every point-at-a-grid runs this, and it is a no-op once the store is clean.
///
/// Only rows the app itself could have written are touched: a pooled credential
/// whose `base_url` is a grid relay ([isGridRelayBase]) for some *other* grid.
/// A provider the user set up — Ollama, an Anthropic key, a Codex sign-in —
/// never matches and is never read out of the file.
class HermesAuthStore {
  HermesAuthStore({String? home}) : _home = home ?? GridPaths.userHome;

  final String _home;

  File get _file => File('${AgentHomes.hermesProfile(_home)}/auth.json');

  /// Drop every pooled credential minted for a grid other than the one at
  /// [keepBase], and any pool left empty by that. Returns how many rows went —
  /// 0 when there was nothing to do, which is the normal case.
  ///
  /// Best-effort by design: a store we can't read or write is not a reason to
  /// fail the message the user is trying to send, and the config write is what
  /// actually points Hermes at the grid. The caller logs the count.
  Future<int> pruneForeignGrids(String keepBase) async {
    final Map<String, dynamic> root;
    try {
      if (!await _file.exists()) return 0;
      final text = (await _file.readAsString()).trim();
      if (text.isEmpty) return 0;
      final decoded = jsonDecode(text);
      if (decoded is! Map) return 0;
      root = Map<String, dynamic>.from(decoded);
    } on Object {
      return 0;
    }

    final pools = root['credential_pool'];
    if (pools is! Map) return 0;

    var dropped = 0;
    final kept = <String, dynamic>{};
    pools.forEach((poolKey, entries) {
      if (entries is! List) {
        kept['$poolKey'] = entries;
        return;
      }
      final survivors = entries.where((entry) {
        if (entry is! Map) return true;
        final base = '${entry['base_url'] ?? ''}';
        if (!isGridRelayBase(base)) return true;
        return sameRelayBase(base, keepBase);
      }).toList();
      dropped += entries.length - survivors.length;
      // A pool emptied by the prune was ours alone (every row named a grid), so
      // the key goes with it — leaving `custom:<old name>: []` behind would keep
      // Hermes's stale provider identity alive with nothing in it.
      if (survivors.isNotEmpty) kept['$poolKey'] = survivors;
    });
    if (dropped == 0) return 0;

    root['credential_pool'] = kept;
    try {
      await _file.copy('${_file.path}.bak');
      await _file.writeAsString(
        '${const JsonEncoder.withIndent('  ').convert(root)}\n',
      );
    } on Object {
      return 0;
    }
    return dropped;
  }
}
