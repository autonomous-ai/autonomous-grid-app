import 'analytics.dart';

/// The events this app sends, one method each.
///
/// An extension rather than a set of loose helpers, so every [Analytics]
/// implementation gets them for free — and so the name and the params of an
/// event are written down **once**. Two call sites that name the same action
/// differently is the failure mode this exists to prevent; it is the same rule
/// the app already follows for user-facing copy (conventions §5).
///
/// Adding an event: add a method here, keep the name `snake_case`, and keep the
/// params to product facts — never message text, prompts, file contents or
/// paths. This stream describes what someone did, not what they wrote.
extension AnalyticsEvents on Analytics {
  /// The app came up. [signedIn] separates a returning user from someone who
  /// is about to meet the login screen.
  void appOpened({required bool signedIn}) =>
      track('app_opened', params: {'signed_in': signedIn});

  /// The app is quitting, after [open]. Sent on the way out, so it is the last
  /// thing the queue drains.
  void appClosed({required Duration open}) =>
      track('app_closed', params: {'open_seconds': open.inSeconds});

  /// A screen was opened. [screen] is the section's stable name, never its
  /// label — labels are rewritten weekly and a renamed label would read as a
  /// new screen.
  void screenView(String screen) =>
      track('screen_view', params: {'screen': screen});

  /// Sign-in completed.
  void signedIn() => track('signed_in');

  /// Sign-in didn't complete. [reason] is a short code — `timeout`,
  /// `cli_missing`, `failed` — never the error text, which can carry a path or
  /// a host name.
  void signInFailed(String reason) =>
      track('sign_in_failed', params: {'reason': reason});

  /// The user signed out.
  void signedOut() => track('signed_out');

  // --- Activation funnel ---
  //
  // One person's path from signing in to sharing a model and using it. Every
  // event carries the same device and user id, so the funnel is built by
  // counting the distinct people who reach each step — no event needs to know
  // about the one before it. Params are product facts only (which option, which
  // model, a short reason code), never anything the user typed.

  /// Which grid the user picked on the first screen after sign-in.
  /// [choice] = `existing` (a grid already on the account), `new` (they made
  /// one), or `later` (skipped the question).
  void gridChoice(String choice) =>
      track('grid_choice', params: {'choice': choice});

  /// The user opened the engines surface, meaning to start one. [source] =
  /// `start_engine_btn` (the empty-chat call to action) or `model_engines_btn`
  /// (the node dashboard button) — the two doors, kept apart so the funnel sees
  /// which one people take.
  void enginesOpened(String source) =>
      track('engines_opened', params: {'source': source});

  /// The user expanded one way to add an engine. [option] = `local` |
  /// `api_key` | `own_server`. Fired on open only, never when the row folds
  /// shut again.
  void addEngineOption(String option) =>
      track('add_engine_option', params: {'option': option});

  /// The user pressed the button that actually brings up an engine via one
  /// path — the attempt, paired with [engineStarted] / [engineStartFailed] for
  /// the outcome. [option] = `built_in` | `api_key` | `own_server`.
  void engineSetupSubmitted(String option, {String? model}) =>
      track('engine_setup_submitted', params: {'option': option, 'model': model});

  /// A model download began. [model] is the spec when known.
  void modelDownloadStarted({String? model}) =>
      track('model_download_started', params: {'model': model});

  /// A model download finished and the file is on disk.
  void modelDownloadCompleted({String? model}) =>
      track('model_download_completed', params: {'model': model});

  /// A model download stopped. [reason] is a short code, never the error text.
  void modelDownloadFailed(String reason, {String? model}) =>
      track('model_download_failed', params: {'reason': reason, 'model': model});

  /// The user pressed Cancel on an in-progress download — a deliberate give-up,
  /// kept apart from [modelDownloadFailed] (which is an error).
  void modelDownloadCancelled({String? model}) =>
      track('model_download_cancelled', params: {'model': model});

  /// A model went live on the grid from this computer — the north-star "shared
  /// a model" moment (for this product, starting an engine *is* the node
  /// joining). [engine] = `built_in` | `own_server` | `api:<kind>`.
  void engineStarted({required String model, required String engine}) =>
      track('engine_started', params: {'model': model, 'engine': engine});

  /// Bringing an engine up failed. [reason] is a short code — never the raw
  /// `grid join` output, which can carry a host name or a path.
  void engineStartFailed(String reason) =>
      track('engine_start_failed', params: {'reason': reason});

  /// A request was sent to a model — the consumer side of usage. [isLocal] is
  /// true when it went to an engine on this computer rather than the relay.
  void chatMessageSent({required String model, required bool isLocal}) =>
      track('chat_message_sent', params: {'model': model, 'is_local': isLocal});
}
