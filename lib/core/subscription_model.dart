import 'app_environment.dart';

/// The model choice that means **no grid at all**: the assistant answers on the
/// sign-in it already has — the Claude Code or Codex subscription the person
/// pays for — instead of on a model this grid serves.
///
/// Developer-only, like Auto (`autoAgentIsOffered`) and the Grids and Debug
/// screens (`ShellSection.devOnly`). Two reasons, and the second is the load
/// bearing one:
///
///  - it answers off the grid, so none of what this app exists for applies to
///    the turn — no grid model, no relay, nothing shared with anybody;
///  - **the cost lands on the user's own subscription**, quietly. A row in the
///    model picker that spends somebody's Claude or ChatGPT quota is not a
///    choice to put in front of an end user beside the models their grid serves.
///
/// Gating it here rather than only hiding the row is what keeps a *stored*
/// choice from routing this way in a shipped build — see
/// [subscriptionModelChosen], and `_syncModelField`, which drops a stored model
/// the picker no longer offers.
bool get subscriptionModelIsOffered => AppEnvironment.isDeveloperMode;

/// The sentinel id stored as a chat's model when the user picks
/// **[kSubscriptionModelLabel]** — never a model any grid serves.
///
/// A string sentinel rather than a real id on purpose, mirroring `kAutoModelId`
/// and `kAutoAgentId`: it is not a model, it is a *choice about where the answer
/// comes from*. Nothing ever puts it on the wire — the lanes that see it drop
/// the grid's credentials and pass the CLI no `--model` at all, which is what
/// leaves the assistant on its own default and its own account.
const String kSubscriptionModelId = 'subscription';

/// What the picker row, the composer pill and the transcript call it.
///
/// Says whose subscription, because that is the whole question a person has
/// about this row: the answer is billed to the account they signed the
/// assistant in with, not to the grid.
const String kSubscriptionModelLabel = 'Your subscription';

/// Whether [id] is the subscription choice — the stored `model` string, which is
/// a real model id in every other case.
bool isSubscriptionModelId(String? id) => id?.trim() == kSubscriptionModelId;

/// Whether a stored choice actually runs off the grid: it names the
/// subscription **and** this build offers it at all.
///
/// Both bars in one place, so a shipped build that hid the row can't go on
/// answering through a choice left on disk — see [subscriptionModelIsOffered].
bool subscriptionModelChosen(String? model) =>
    subscriptionModelIsOffered && isSubscriptionModelId(model);
