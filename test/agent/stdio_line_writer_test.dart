import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/cli/stdio_line_writer.dart';

/// An [IOSink] with `dart:io`'s own rule: `flush()` binds the sink until it
/// completes, and anything written while it is bound throws instead of being
/// written. The real one cost a chat turn — Hermes answered two permission
/// requests in one pass, the second answer threw here, and the agent waited on
/// an approval that never came until the idle watchdog cut the turn.
class _BindingSink implements IOSink {
  final written = <String>[];
  Completer<void>? _flushing;

  /// Set to have the next write throw the way a broken pipe does.
  Object? failWith;

  @override
  void write(Object? obj) {
    if (_flushing != null) throw StateError('StreamSink is bound to a stream');
    final fail = failWith;
    if (fail != null) {
      failWith = null;
      throw fail;
    }
    written.add('$obj');
  }

  @override
  Future<void> flush() {
    if (_flushing != null) throw StateError('StreamSink is bound to a stream');
    final pending = Completer<void>();
    _flushing = pending;
    // A real flush lands on a later turn of the event loop — the whole reason a
    // write can arrive while one is still in flight.
    scheduleMicrotask(() {
      _flushing = null;
      pending.complete();
    });
    return pending.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('lines written back to back all reach the process, in order — the '
      'dropped one used to hang the turn until the idle watchdog', () async {
    final sink = _BindingSink();
    final errors = <Object>[];
    final writer = StdioLineWriter(sink, onError: errors.add);

    // The failing shape exactly: several messages queued in one synchronous
    // pass, as two permission answers arriving in a single stdout chunk are.
    writer.write('first\n');
    writer.write('second\n');
    writer.write('third\n');
    await writer.idle;

    expect(sink.written, ['first\n', 'second\n', 'third\n']);
    expect(errors, isEmpty);
  });

  test('a line that never made it is reported, so the caller can end the turn '
      'instead of waiting on an answer that cannot come', () async {
    final sink = _BindingSink()
      ..failWith = const SocketException('broken pipe');
    final errors = <Object>[];
    final writer = StdioLineWriter(sink, onError: errors.add);

    writer.write('lost\n');
    await writer.idle;

    expect(errors, hasLength(1));
    expect(errors.single, isA<SocketException>());
  });

  test('one broken line does not poison the queue: what follows still goes '
      'through', () async {
    final sink = _BindingSink()..failWith = const SocketException('flaky');
    final errors = <Object>[];
    final writer = StdioLineWriter(sink, onError: errors.add);

    writer.write('lost\n');
    writer.write('after\n');
    await writer.idle;

    expect(sink.written, ['after\n']);
    expect(errors, hasLength(1));
  });
}
