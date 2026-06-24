import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/grid_cli_service.dart';
import '../../../infrastructure/providers.dart';
import '../../auth/logic/session_controller.dart';

final enableProviderControllerProvider =
    NotifierProvider<EnableProviderController, EnableProviderState>(
        EnableProviderController.new);

sealed class EnableProviderState {
  const EnableProviderState();
}

class EnableIdle extends EnableProviderState {
  const EnableIdle();
}

/// The flow is running for [networkId]; [log] holds the step trace.
class EnableRunning extends EnableProviderState {
  const EnableRunning(this.networkId, this.log);
  final String networkId;
  final List<String> log;
}

class EnableDone extends EnableProviderState {
  const EnableDone();
}

class EnableFailed extends EnableProviderState {
  const EnableFailed(this.networkId, this.message);
  final String networkId;
  final String message;
}

/// One-click "become a provider on a network you administer".
///
/// Grants the current user the `provider` role (keeping `admin`) via the
/// allowlist, then re-fetches the network token so it carries the
/// `provider:poll` scope, and refreshes the session so [NetworkCredential.
/// isProvider] flips true and the run form unlocks. Mirrors the manual flow:
/// `network allowlist add <id> <self> --role admin --role provider` →
/// `network join <id>`.
class EnableProviderController extends Notifier<EnableProviderState> {
  @override
  EnableProviderState build() => const EnableIdle();

  Future<void> enable({
    required String networkId,
    required String email,
  }) async {
    final service = ref.read(gridCliServiceProvider);
    if (service == null) {
      state = EnableFailed(networkId, 'grid executable not found.');
      return;
    }

    final log = <String>[];
    void step(String line) {
      log.add(line);
      state = EnableRunning(networkId, List.unmodifiable(log));
    }

    step('Granting the provider role to $email…');
    final add = await service.run([
      'network', 'allowlist', 'add', networkId, email,
      '--role', 'admin', '--role', 'provider',
    ]);
    step(_lastLine(add));
    if (!add.ok) {
      state = EnableFailed(networkId, add.errorMessage);
      return;
    }

    step('Refreshing the grid token…');
    final join = await service.run(['network', 'join', networkId]);
    step(_lastLine(join));
    if (!join.ok) {
      state = EnableFailed(networkId, join.errorMessage);
      return;
    }

    // The fresh token (with provider:poll) is now in credentials.toml.
    ref.invalidate(sessionProvider);
    state = const EnableDone();
  }

  void reset() => state = const EnableIdle();

  String _lastLine(CliResult r) {
    final out = r.stdout.trim();
    if (out.isNotEmpty) return out.split('\n').last;
    final err = r.stderr.trim();
    if (err.isNotEmpty) return err.split('\n').last;
    return 'exit ${r.exitCode}';
  }
}
