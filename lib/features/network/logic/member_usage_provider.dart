import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/models/member_usage.dart';
import '../../../infrastructure/api/relay_api_client.dart';
import '../../../infrastructure/cli/command_log.dart';
import '../../auth/logic/session_controller.dart';
import 'node_metrics.dart' show answeredWindowLabel, formatCount;

/// A grid's member usage, keyed by email, and the span it covers.
///
/// The window rides along rather than being assumed: it is an operator knob on
/// the relay (`node_answered_window_seconds`), and a heading that said "24h"
/// while the master counted six would be wrong in the one way a figure must
/// never be.
typedef GridMemberUsage = ({
  int windowSeconds,
  Map<String, MemberUsage> byEmail,
});

/// What each person on the selected grid ran in the relay's answered window.
///
/// **`autoDispose`, and fetched only while something watches it.** The panel it
/// feeds opens on hover, so this asks the relay when that panel appears and
/// stops when it closes — unlike the overview, which polls continuously because
/// the pill's figures are always on screen. A per-person usage table is not
/// worth a standing request.
///
/// **Null is "this grid can't tell us"** — no rollup has landed yet, the master
/// predates the endpoint, or this caller may not ask. An empty `byEmail` is the
/// opposite: the rollup landed and nobody used the grid today. The panel must
/// say those differently, because printing zeros for the first would report a
/// whole grid as idle on the strength of a master still warming up.
final gridMemberUsageProvider = FutureProvider.autoDispose<GridMemberUsage?>((
  ref,
) async {
  final grid = ref.watch(selectedNetworkProvider);
  if (grid == null) return null;
  final log = ref.read(commandLogProvider.notifier);
  final client = ref.read(relayApiClientProvider);
  final id = log.begin(
    CliCallKind.http,
    'GET ${grid.relayBaseUrl}/grid/members/usage',
    detail: CommandDetail(authorized: grid.relayApiKey.isNotEmpty),
  );
  try {
    final result = await client.memberUsage(
      baseUrl: grid.relayBaseUrl,
      apiKey: grid.relayApiKey,
    );
    log.finish(id, exitCode: 200);
    if (result == null) return null;
    return (
      windowSeconds: result.windowSeconds,
      // Keyed by email, so a consumer the relay could not name is not in the
      // map — the roster is keyed by address and has nowhere to show them.
      // They are still counted by the grid's own token figure on the pill,
      // which is why that one can read higher than this list's total.
      byEmail: {
        for (final row in result.members)
          if (row.email case final email? when email.isNotEmpty)
            email.toLowerCase(): row,
      },
    );
  } on RelayUnavailable catch (e) {
    log.finish(
      id,
      exitCode: e.statusCode,
      error: e.statusCode == null ? '${e.cause ?? 'unreachable'}' : null,
    );
    // Every failure reads as "this grid can't tell us", never as zeros. A 404 is
    // a master too old for the endpoint and is the common case mid-rollout; a
    // 401/403 is a caller who may not ask. Neither is a fact about how much
    // anyone used, so neither may render as a figure.
    return null;
  }
});

/// One member's usage out of the map, or null when the grid reported none.
///
/// Keyed case-insensitively because the roster and the relay's identity table
/// are filled by different systems — the control plane stores what the user
/// typed, the relay what the token carried — and an address differing only in
/// case would silently show a busy person as having done nothing.
MemberUsage? memberUsageFor(Map<String, MemberUsage>? byEmail, String email) =>
    byEmail?[email.trim().toLowerCase()];

/// The roster ordered for the panel: biggest reader first, then everyone the
/// grid has no figure for, alphabetically.
///
/// **The roster decides who is listed, the usage only decides the order.** A
/// consumer the relay knows but the roster has since dropped is not a member any
/// more and must not reappear here; a member who has never sent a request is
/// still a member and keeps their row.
///
/// Ties break on the address so the order is total and stable — the panel polls,
/// and two people who read the same amount must not swap places while somebody
/// is reading the list. With no usage at all (an older master, or a grid nobody
/// used) this degrades to plain alphabetical, which is what the list showed
/// before it could rank anything.
/// [emailOf] rather than a concrete member type: this orders a roster, and the
/// roster's shape belongs to whoever fetched it. Required, not optional with a
/// `dynamic` fallback — §3 rules that out, and a reflective read would fail at
/// runtime on the one caller that passed the wrong list.
List<T> sortMembersByUsage<T>(
  List<T> members,
  Map<String, MemberUsage>? usage, {
  required String Function(T) emailOf,
}) {
  final sorted = [...members];
  sorted.sort((a, b) {
    // The **fresh** leg, which is the figure the row prints. Ranking on
    // `tokensIn` instead ordered the list by a number nobody could see — a
    // heavy cache user outranked someone who had read twice as much new work,
    // and the column looked simply unsorted.
    //
    // −1 for "no figure", which sorts every unmeasured member below a measured
    // zero. Someone the grid counted and found idle is a different fact from
    // someone it never heard from, and the order keeps them apart.
    final ta = memberUsageFor(usage, emailOf(a))?.freshInputTokens ?? -1;
    final tb = memberUsageFor(usage, emailOf(b))?.freshInputTokens ?? -1;
    if (ta != tb) return tb.compareTo(ta);
    return emailOf(a).toLowerCase().compareTo(emailOf(b).toLowerCase());
  });
  return sorted;
}

/// The members panel's heading figure: what the people listed under it read in
/// the window, e.g. "174M input · 24h".
///
/// Sums the **fresh** input leg, the same measure each row prints, so the column
/// adds up to its own header. Cached prefill is a share of input, not a fourth
/// kind — totalling `tokensIn` raw would give a header larger than its column.
///
/// Rows the grid has no figure for contribute nothing rather than being skipped
/// as an error: a member who has never sent a request genuinely adds zero.
String memberInputTotalLabel(Iterable<MemberUsage?> rows, int windowSeconds) {
  final total = rows.fold<int>(0, (sum, m) => sum + (m?.freshInputTokens ?? 0));
  final window = answeredWindowLabel(windowSeconds);
  // The span is named, or the figure isn't shown at all. A cumulative count with
  // no window reads as all-time, which this is not — and a relay that reported
  // no span leaves us nothing honest to write beside the number.
  return window.isEmpty
      ? '${formatCount(total)} input'
      : '${formatCount(total)} input · $window';
}

/// One member's whole 24h split, as the two lines the panel prints for the row
/// under the pointer.
///
/// **Two, not one.** All four figures on a line ran past a 340px panel and were
/// ellipsized from the right, which cost the two at the end — cache and output —
/// exactly the ones a reader cannot infer from the row above. Two is also the
/// natural split: what was asked, then what came back.
///
/// **Two, not four.** The panel draws these *inside* itself rather than in a
/// tooltip, and it must hold the same height hovered or not — a list that grew
/// and shrank under the pointer would push its own rows around as you read
/// them. Two lines is what the idle hint can match without padding.
///
/// A tooltip is not an option here at all: this panel lives inside a
/// `CompositedTransformFollower` (it hangs off the pill), and Flutter's
/// `Tooltip` positions itself with `localToGlobal`, which through a follower
/// layer throws "the paint transform cannot be reliably computed" during layout.
///
/// Input is the **fresh** leg — cached prefill is a share of input, not a fourth
/// kind — so the three token figures sum to what actually passed through. Naming
/// them raw would show a person three numbers adding up to more than they used,
/// and the error grows with how well their cache works.
List<String> memberUsageLines(MemberUsage usage) => [
  '${formatCount(usage.requests)} requests · '
      '${formatCount(usage.freshInputTokens)} input tokens',
  '${formatCount(usage.tokensCached)} from cache · '
      '${formatCount(usage.tokensOut)} output tokens',
];
