import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/grid_cli_service.dart';
import '../../../infrastructure/providers.dart';
import 'connector.dart';

/// The connector list, read through the CLI so the app and the agent can never
/// disagree about what is connected.
final connectorsProvider =
    AsyncNotifierProvider<ConnectorsController, List<Connector>>(
      ConnectorsController.new,
    );

/// Which connector is mid-connect, so the row can show progress and the rest of
/// the list can stay interactive. Null when nothing is in flight.
final connectingConnectorProvider =
    NotifierProvider<ConnectingConnector, String?>(ConnectingConnector.new);

class ConnectingConnector extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? code) => state = code;
}

class ConnectorsController extends AsyncNotifier<List<Connector>> {
  GridProcess? _process;
  StreamSubscription<CliLine>? _lineSub;

  @override
  Future<List<Connector>> build() async {
    ref.onDispose(_cleanup);
    return _load();
  }

  Future<List<Connector>> _load() async {
    final service = ref.read(gridCliServiceProvider);
    if (service == null) {
      throw const CliUnavailable();
    }
    final result = await service.run(['connector', 'list', '--json']);
    if (!result.ok) {
      throw CliFailure(result.errorMessage, sessionExpired: result.sessionExpired);
    }
    return Connector.parseList(result.stdout);
  }

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(_load);
  }

  /// Authorize a connector. The CLI opens the browser, waits for the provider
  /// redirect to reach the control plane, then writes `~/.grid/config_mcp.json`.
  ///
  /// Returns null on success, else a line to show — every caller is a button.
  /// Guarded against re-entry: a second connect would orphan the first process.
  Future<String?> connect(String code) async {
    if (ref.read(connectingConnectorProvider) != null) return null;
    final service = ref.read(gridCliServiceProvider);
    if (service == null) return 'grid executable not found.';

    ref.read(connectingConnectorProvider.notifier).set(code);
    final errorLines = <String>[];
    try {
      _process = await service.start(['connector', 'connect', code]);
      _lineSub = _process!.lines.listen((line) {
        if (line.isStderr) errorLines.add(line.text);
      });
      // The CLI's own poll window is 10 minutes; cap slightly above it so a
      // closed browser surfaces as our message rather than hanging the row.
      final exitCode = await _process!.exitCode.timeout(
        const Duration(minutes: 11),
        onTimeout: () {
          _process?.kill();
          return -1;
        },
      );
      if (exitCode != 0) {
        final detail = errorLines.join('\n').trim();
        return detail.isNotEmpty
            ? detail
            : "Couldn't connect $code. Please try again.";
      }
      return null;
    } on Object catch (error) {
      return "Couldn't connect $code: $error";
    } finally {
      await _cleanup();
      ref.read(connectingConnectorProvider.notifier).set(null);
      // Re-read regardless of outcome: a partial failure may still have changed
      // server-side state, and the list is the source of truth.
      state = await AsyncValue.guard(_load);
    }
  }

  Future<String?> disconnect(String code) async {
    final service = ref.read(gridCliServiceProvider);
    if (service == null) return 'grid executable not found.';
    final result = await service.run(['connector', 'disconnect', code]);
    state = await AsyncValue.guard(_load);
    return result.ok ? null : result.errorMessage;
  }

  /// Cancel an in-flight authorization (the user closed the browser or changed
  /// their mind). The CLI process owns the poll loop, so killing it is the cancel.
  Future<void> cancelConnect() async {
    _process?.kill();
    await _cleanup();
  }

  Future<void> _cleanup() async {
    await _lineSub?.cancel();
    _lineSub = null;
    _process = null;
  }
}

/// The `grid` binary is missing — a setup problem, not a connector problem.
class CliUnavailable implements Exception {
  const CliUnavailable();

  @override
  String toString() => 'grid executable not found.';
}

class CliFailure implements Exception {
  const CliFailure(this.message, {this.sessionExpired = false});

  final String message;
  final bool sessionExpired;

  @override
  String toString() => sessionExpired
      ? 'Your Grid session expired. Sign in again to manage connectors.'
      : message;
}
