import '../../../core/context_length.dart';

/// The context sizes a picker offers for an external server, largest last.
///
/// The design gives the endpoint form a dropdown where the local engine gets a
/// slider, and the reason holds: a server's window is a number it was *launched
/// with*, so the question here is "which of these did you start it on", not
/// "how much would you like". A ladder answers that in one press.
///
/// Two rules keep it honest. Nothing above [max] is offered, because the server
/// cannot serve it. And a value already in force that is not on the ladder —
/// `--ctx-size 40960`, or whatever the server reported about itself — is kept
/// as its own rung, so opening the picker can never quietly round somebody's
/// setting to the nearest familiar number.
///
/// Pure, so the rounding rule is a tested one rather than a chain of ifs in a
/// `build()`.
List<int> contextLadder({required int max, required int current}) {
  const rungs = [
    4 * 1024,
    8 * 1024,
    16 * 1024,
    32 * 1024,
    64 * 1024,
    128 * 1024,
    200 * 1024,
    256 * 1024,
    512 * 1024,
    1024 * 1024,
  ];
  final ceiling = max < minContextTokens ? minContextTokens : max;
  final offered = {
    for (final rung in rungs)
      if (rung <= ceiling) rung,
    // The ceiling itself, so a server that tops out at an odd number can still
    // be run flat out.
    ceiling,
    // Never drop what is already set.
    current.clamp(minContextTokens, ceiling),
  }.toList()..sort();
  return offered;
}
