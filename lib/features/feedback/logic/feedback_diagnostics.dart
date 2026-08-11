import 'dart:io' show Platform;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_environment.dart';
import '../../../infrastructure/logging/app_log_tail.dart';
import '../../../shared/app_info.dart';
import '../../agents/logic/active_chat_agent.dart';
import '../../auth/logic/session_controller.dart';

/// What the app knows about itself, attached to every feedback message.
///
/// A bug report without a version and an OS costs a round trip before anyone
/// can even start looking, so this rides along with the message. It is machine
/// metadata only — the fields below and nothing more.
///
/// What is deliberately **not** here, and must stay that way: chat transcripts,
/// project paths, model prompts, tokens, and the durable CLI/HTTP logs under
/// `~/.grid/logs` (command output and request bodies — user content, not
/// metadata). The error lines are the one-line summaries `FileAppLog` writes,
/// clipped — not the stack traces under them, which carry paths from this
/// machine. Widening this to log *contents* is a different decision with a
/// different privacy weight; don't reach for it here.
class FeedbackDiagnostics {
  const FeedbackDiagnostics({
    required this.appVersion,
    required this.platform,
    required this.osVersion,
    required this.locale,
    required this.agent,
    required this.grid,
    required this.buildChannel,
    required this.recentErrors,
  });

  /// The app's semantic version, or `unknown` if the bundle hadn't answered yet.
  final String appVersion;

  /// Friendly OS name — `macOS`, not `macos`.
  final String platform;

  /// The OS's own version string (`Version 15.5 (Build 24F74)`).
  final String osVersion;

  /// The locale the UI is running in — enough to explain a layout that only
  /// breaks in one language.
  final String locale;

  /// The assistant that answers chat here, by display name.
  final String agent;

  /// The grid the user is on, or null when they're on none.
  final String? grid;

  /// `release` or `developer` — a developer build can reach staging, so a report
  /// from one is about a different backend than the same version shipped.
  final String buildChannel;

  /// The last few error lines from today's app log, newest last. Empty when the
  /// app hasn't logged an error today, which is itself worth knowing.
  final List<String> recentErrors;

  Map<String, dynamic> toJson() => {
    'app_version': appVersion,
    'platform': platform,
    'os_version': osVersion,
    'locale': locale,
    'agent': agent,
    if (grid != null) 'grid': grid,
    'build': buildChannel,
    if (recentErrors.isNotEmpty) 'recent_errors': recentErrors,
  };
}

/// `macos` → `macOS`. Pure, so the label doesn't depend on the machine reading
/// it.
String platformLabel(String operatingSystem) => switch (operatingSystem) {
  'macos' => 'macOS',
  'windows' => 'Windows',
  'linux' => 'Linux',
  _ => operatingSystem,
};

/// The snapshot for the feedback form, gathered fresh each time the dialog
/// opens (the log tail moves, and so does the agent the user is on).
///
/// A [FutureProvider] because reading the log tail is IO. It never fails: an
/// unreadable log yields no error lines rather than an error state, so the
/// dialog is never blocked from sending by its own optional attachment.
final feedbackDiagnosticsProvider = FutureProvider<FeedbackDiagnostics>((
  ref,
) async {
  final errors = await readRecentAppErrors();
  return FeedbackDiagnostics(
    appVersion: ref.read(appVersionProvider).asData?.value ?? 'unknown',
    platform: platformLabel(Platform.operatingSystem),
    osVersion: Platform.operatingSystemVersion,
    locale: Platform.localeName,
    agent: ref.read(chatAgentForProjectProvider(null)).name,
    grid: ref.read(selectedNetworkProvider)?.name,
    buildChannel: AppEnvironment.isDeveloperMode ? 'developer' : 'release',
    recentErrors: errors,
  );
});
