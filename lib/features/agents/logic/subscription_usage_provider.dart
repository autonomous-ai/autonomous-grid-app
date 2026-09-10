import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/subscription_model.dart';
import '../../../infrastructure/cli/agent_usage_credentials.dart';
import '../../../infrastructure/logging/app_log.dart';
import '../../chat/logic/chat_sessions_controller.dart';
import 'active_chat_agent.dart';
import 'agent_catalog.dart';
import 'subscription_usage.dart';

/// How much of the assistant's own account this chat is spending, while it
/// answers off the grid.
///
/// Only ever asked while the open chat is on [kSubscriptionModelId]: on a grid
/// model the account behind the CLI is not paying for anything, and a rail
/// reporting somebody's Claude limits under a grid's answer would be reporting
/// a bill nobody is running up. Null when the question does not apply, which is
/// what keeps the rail on the grid's own figures.
final subscriptionUsageAgentProvider = Provider<AgentTool?>((ref) {
  final onSubscription = isSubscriptionModelId(
    ref.watch(chatSessionsProvider.select((s) => s.active?.model)),
  );
  if (!onSubscription) return null;
  final agent = ref.watch(activeChatAgentProvider);
  // Hermes has no account of its own — it cannot be on this row at all (see
  // `agentSupportsModel`), so there is nothing to read for it.
  return agent == AgentTool.hermes ? null : agent;
});

/// The reading itself, refreshed while anything is watching it.
///
/// `retry: null` because Riverpod 3 otherwise retries a failed provider ten
/// times over: against an endpoint that is down (or a token that is refused)
/// that is ten requests carrying a bearer token to say the same thing once.
///
/// Five minutes, not seconds: these are rate-limit windows measured in hours,
/// and the CLI itself does not poll them. A figure a few minutes old is the
/// honest resolution of the thing being reported.
final subscriptionUsageProvider = FutureProvider.family<AgentUsage, AgentTool>((
  ref,
  agent,
) async {
  final timer = Timer(const Duration(minutes: 5), () => ref.invalidateSelf());
  ref.onDispose(timer.cancel);
  return readAgentUsage(agent, log: ref.read(appLogProvider));
}, retry: null);

/// The endpoint each CLI asks when it prints its own usage.
///
/// ⚠️ Both are **undocumented** and answer only to the token their own CLI
/// signed in with — hence Claude's beta header and CLI user agent, which are
/// what make an OAuth token issued to Claude Code acceptable there. They can
/// change without notice; a change lands here as a failed state, never as a
/// crash and never as an invented number.
const String kClaudeUsageUrl = 'https://api.anthropic.com/api/oauth/usage';
const String kCodexUsageUrl = 'https://chatgpt.com/backend-api/wham/usage';

/// Read [agent]'s account limits. Never throws: every failure is a state with a
/// sentence a person can act on.
///
/// [log] takes the raw failure — the humanised sentence below is what the user
/// reads, and a log that only repeated it would diagnose nothing (§6).
Future<AgentUsage> readAgentUsage(
  AgentTool agent, {
  AppLog? log,
  AgentUsageCredentials credentials = const AgentUsageCredentials(),
}) async {
  final token = await switch (agent) {
    AgentTool.claude => credentials.claude(),
    AgentTool.codex => credentials.codex(),
    AgentTool.hermes => Future<AgentToken?>.value(),
  };
  if (token == null) {
    return AgentUsage(
      agent: agent,
      status: AgentUsageStatus.signedOut,
      message: 'Sign in with ${agent.name} to see what it has left',
    );
  }
  // An expired token is spent as a sign-in rather than as a round trip: this
  // app does not refresh what the CLI owns, so the request could only fail.
  if (token.isExpired) {
    return AgentUsage(
      agent: agent,
      status: AgentUsageStatus.signedOut,
      message: '${agent.name} needs signing in again',
    );
  }
  try {
    final (statusCode, body) = await _get(
      agent == AgentTool.claude ? kClaudeUsageUrl : kCodexUsageUrl,
      headers: {
        'Authorization': 'Bearer ${token.accessToken}',
        if (agent == AgentTool.claude) ...{
          'anthropic-beta': 'oauth-2025-04-20',
          'User-Agent': 'claude-code/2.1.0',
        },
        'ChatGPT-Account-Id': ?token.accountId,
      },
    );
    if (statusCode == 401 || statusCode == 403) {
      log?.info('agent', '${agent.id} usage: refused with $statusCode');
      return AgentUsage(
        agent: agent,
        status: AgentUsageStatus.signedOut,
        message: '${agent.name} needs signing in again',
      );
    }
    if (statusCode != 200) {
      log?.info('agent', '${agent.id} usage: HTTP $statusCode');
      return AgentUsage(
        agent: agent,
        status: AgentUsageStatus.failed,
        message: "Couldn't read ${agent.name}'s limits",
      );
    }
    final decoded = jsonDecode(body);
    if (decoded is! Map) {
      log?.info('agent', '${agent.id} usage: answered with a non-object body');
      return AgentUsage(
        agent: agent,
        status: AgentUsageStatus.failed,
        message: '${agent.name} answered in a shape this build cannot read',
      );
    }
    final windows = agent == AgentTool.claude
        ? claudeUsageWindows(decoded)
        : codexUsageWindows(decoded);
    if (windows.isEmpty) {
      log?.info('agent', '${agent.id} usage: no window in the payload');
      return AgentUsage(
        agent: agent,
        status: AgentUsageStatus.failed,
        message: '${agent.name} reported no limits',
      );
    }
    return AgentUsage(
      agent: agent,
      status: AgentUsageStatus.ok,
      windows: windows,
      fetchedAt: DateTime.now(),
    );
  } on Object catch (error) {
    // The token is in the request, never in the record: what is logged is the
    // failure, and this catch is what keeps a stack trace carrying a header out
    // of the transcript.
    log?.info('agent', '${agent.id} usage: ${error.runtimeType}');
    return AgentUsage(
      agent: agent,
      status: AgentUsageStatus.failed,
      message: "Couldn't reach ${agent.name}'s account",
    );
  }
}

/// One GET, with the app's own client rather than a package — the same
/// `dart:io` HTTP every other call in this app is made with.
Future<(int, String)> _get(
  String url, {
  required Map<String, String> headers,
}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  try {
    final request = await client.getUrl(Uri.parse(url));
    headers.forEach(request.headers.set);
    final response = await request.close().timeout(const Duration(seconds: 10));
    final body = await response.transform(utf8.decoder).join();
    return (response.statusCode, body);
  } finally {
    client.close(force: true);
  }
}
