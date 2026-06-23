import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/grid_cli_service.dart';
import '../../../infrastructure/providers.dart';
import 'auth_state.dart';
import 'device_login_parser.dart';
import 'session_controller.dart';

final authControllerProvider =
    NotifierProvider<AuthController, AuthState>(AuthController.new);

/// Drives `grid auth login --no-browser`: spawns it, surfaces the URL + code as
/// they stream in, and resolves on the process exit code (cli.py:357/381).
class AuthController extends Notifier<AuthState> {
  GridProcess? _process;

  @override
  AuthState build() {
    ref.onDispose(() => _process?.kill());
    return const AuthIdle();
  }

  Future<void> login() async {
    final service = ref.read(gridCliServiceProvider);
    if (service == null) {
      state = const AuthFailure('grid executable not found.');
      return;
    }

    state = const AuthStarting();
    final parser = DeviceLoginParser();
    final errorLines = <String>[];

    final apiUrl = ref.read(gridApiUrlProvider);
    _process = await service.start([
      'auth', 'login', '--no-browser',
      if (apiUrl.isNotEmpty) ...['--api-url', apiUrl],
    ]);
    _process!.lines.listen((line) {
      if (line.isStderr) errorLines.add(line.text);
      parser.feed(line.text);
      final login = parser.result;
      if (login != null && state is! AuthAwaitingApproval) {
        state = AuthAwaitingApproval(url: login.url, userCode: login.userCode);
      }
    });

    final exitCode = await _process!.exitCode;
    if (exitCode == 0) {
      ref.invalidate(sessionProvider);
      state = const AuthSuccess();
      return;
    }
    state = AuthFailure(
      errorLines.isNotEmpty
          ? errorLines.join('\n')
          : 'Login failed (exit $exitCode).',
    );
  }

  void cancel() {
    _process?.kill();
    state = const AuthIdle();
  }

  /// Sign out: best-effort `grid auth logout` (if the CLI supports it), then
  /// clear the local credentials so the app drops back to the login screen.
  Future<void> logout() async {
    final service = ref.read(gridCliServiceProvider);
    await service?.run(['auth', 'logout']);
    ref.read(gridHomeStoreProvider).clearCredentials();
    ref.invalidate(sessionProvider);
    state = const AuthIdle();
  }
}
