/// The app's behavioural-event sink.
///
/// Every call site talks to this, never to the transport underneath, so
/// tracking can be muted (opt-out, a test run, a build with no key) by handing
/// out a [NoopAnalytics] instead of by checking a flag at each call site.
///
/// Nothing here throws and nothing here is awaited by the UI: an analytics
/// problem must never be something the user finds out about.
abstract interface class Analytics {
  /// Queue one event. [name] must be `snake_case`
  /// (`analyticsEventNamePattern`) or it is dropped with a warning in the app
  /// log — the backend would accept it silently and leave the stream
  /// unqueryable.
  ///
  /// [params] is free-form, but it is a *product* record, not a debug dump:
  /// never put message text, prompts, file contents or absolute paths in it.
  void track(String name, {Map<String, Object?> params});

  /// Send whatever is queued now, instead of waiting on the retry timer.
  Future<void> flush();

  /// Final, time-boxed drain, then release the connection. Called when the app
  /// quits; the instance is spent afterwards.
  Future<void> close();
}

/// Does nothing, for a muted app and for tests.
class NoopAnalytics implements Analytics {
  const NoopAnalytics();

  @override
  void track(String name, {Map<String, Object?> params = const {}}) {}

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {}
}
