import 'dart:async';
import 'dart:io';

/// Writes newline-delimited lines to a child process's stdin, one at a time.
///
/// Every line has to be flushed: the agent on the other end reads
/// newline-delimited JSON-RPC, so an unflushed buffer leaves it waiting while we
/// wait for its output — a deadlock. But `IOSink.flush()` *binds* the sink until
/// it completes, and a write that lands mid-flush throws `StreamSink is bound to
/// a stream` and is lost. That is not a corner case: two permission requests
/// arriving in one stdout chunk are answered back to back, in the same
/// synchronous pass, and the dropped answer left Hermes waiting on an approval
/// that never came until the idle watchdog cut the turn nearly six minutes
/// later. So lines queue — each waits for the previous flush.
class StdioLineWriter {
  StdioLineWriter(this._sink, {required this.onError});

  final IOSink _sink;

  /// A line that never made it. Whatever the process was waiting on it will now
  /// wait for forever, so the caller ends the turn instead of hanging on it.
  /// Called once per failed line, with the raw error to log (§6).
  final void Function(Object error) onError;

  Future<void> _queue = Future.value();

  /// Queue [line] behind everything already in flight. Returns at once — order
  /// is what's guaranteed, not delivery.
  void write(String line) {
    _queue = _queue
        .then<void>((_) async {
          _sink.write(line);
          await _sink.flush();
        })
        // Swallowed on purpose: a broken pipe is reported through [onError] and
        // must not poison the queue, or one failure silently drops every line
        // after it.
        .catchError(onError);
  }

  /// Completes when every queued line has been written and flushed. For tests
  /// and for a caller that needs the pipe drained before it moves on.
  Future<void> get idle => _queue;
}
