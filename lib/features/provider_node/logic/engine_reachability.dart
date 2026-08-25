import 'dart:convert';
import 'dart:io';

import 'engine_endpoint.dart';

/// Which of the engines the app knows how to read answered.
///
/// Only ever used to decide whether the Model field can offer a list: a
/// recognised engine means its `/models` body was understood, so the names in
/// it can be trusted enough to put in a picker. [unknown] is not a failure —
/// it is every other OpenAI-compatible server, and it gets the plain text field
/// that everyone typing a name by hand already uses.
enum EngineKind { ollama, llamaCpp, vllm, unknown }

/// What one look at the engine's `/models` found.
sealed class EngineReach {
  const EngineReach();
}

/// The server answered and named what it serves. [models] may be empty — a
/// server is allowed to answer without listing anything, and that is still a
/// reachable server.
class EngineReachable extends EngineReach {
  const EngineReachable(this.models, this.kind, {this.contextLength});

  final List<String> models;

  /// The context window this server actually serves, when it says so, else
  /// null. Null is a real answer and means "ask the person" — see
  /// [servedContextFrom] for why so few engines qualify.
  final int? contextLength;

  /// Which engine this looked like. [EngineKind.unknown] means the body parsed
  /// but carried none of the markers below.
  final EngineKind kind;

  /// Whether the Model field can offer a list instead of a text box.
  ///
  /// Both halves are needed. An unrecognised engine may still have handed over
  /// a list of ids — the `data[].id` shape is common to all of them — but a
  /// picker built from a body nobody recognised is a picker that might be
  /// listing the wrong thing, and picking a wrong name is harder to notice than
  /// typing a right one.
  bool get canOfferModels => kind != EngineKind.unknown && models.isNotEmpty;
}

/// The server did not answer usefully. [message] is written for the person and
/// **names the URL that was actually called**.
class EngineUnreachable extends EngineReach {
  const EngineUnreachable(this.message);

  final String message;
}

/// How long to wait before calling an address unreachable. Short on purpose:
/// this runs between pressing Start and the engine coming up, with someone
/// watching it.
const Duration _timeout = Duration(seconds: 8);

/// Ask [address] what it serves, so a wrong address fails here rather than two
/// minutes later inside a chat.
///
/// This is the guard the CLI does not have. Its own servability check treats an
/// unreachable list as fine — *"An empty/unreachable list is non-breaking
/// (advertise as today)"* — so a node whose address answers nothing still joins,
/// still turns green, and still appears to serve a model. Everything after that
/// fails, and by then the person has left the screen that could have told them.
///
/// Never throws: every outcome is one of the two states above.
Future<EngineReach> probeEngine(EngineAddressReady address) async {
  final url = address.modelsUrl;
  final client = HttpClient()..connectionTimeout = _timeout;
  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close().timeout(_timeout);
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode != HttpStatus.ok) {
      return EngineUnreachable(_answeredWrong(url, response.statusCode));
    }
    return EngineReachable(
      modelIdsFrom(body),
      engineKindFrom(body),
      contextLength: servedContextFrom(body),
    );
  } on Object {
    // Refused, DNS, TLS, timeout — all the same thing to the person reading it:
    // nothing picked up. The distinction belongs in a log, not under a field.
    return EngineUnreachable(
      "Couldn't reach $url — check the address, and that the server is "
      'running.',
    );
  } finally {
    client.close(force: true);
  }
}

/// The line for a server that answered with something other than 200.
///
/// It names the URL and then *suggests* rather than asserts. A 404 here is
/// usually a missing `/v1`, but not always — some servers do sit at the root,
/// and telling one of those users to add `/v1` sends them to fix a thing that
/// was never wrong.
String _answeredWrong(String url, int status) =>
    '$url answered $status. Many servers need /v1 at the end of the address.';

/// Which engine wrote this `/models` body, as far as the shape gives it away.
///
/// Every one of these serves the same OpenAI envelope, so the engine is only
/// visible in the extra keys each adds to an entry:
///
/// | engine    | marker                                       |
/// |-----------|----------------------------------------------|
/// | vLLM      | `max_model_len` on the entry                 |
/// | llama.cpp | a `meta` object (`n_ctx_train`, `n_params`)  |
/// | Ollama    | `owned_by: "library"`                        |
///
/// Structural markers are checked before `owned_by`, because a field somebody
/// had a reason to add is harder to coincide with than a string.
///
/// TODO(BE): **these markers are read from documentation and memory, not from
/// a live server** — nothing in either repo records the shape of a `/models`
/// body, and no fixture exists to check them against. A wrong marker is not
/// dangerous (it falls to [EngineKind.unknown], which is exactly today's
/// behaviour — a text field), but it does silently withhold a working picker.
/// Verify with `curl <base>/models` against one of each and pin the bodies as
/// fixtures beside this test.
EngineKind engineKindFrom(String body) {
  for (final entry in _entries(body)) {
    if (entry.containsKey('max_model_len')) return EngineKind.vllm;
    if (entry['meta'] is Map) return EngineKind.llamaCpp;
    final owner = entry['owned_by'];
    if (owner is! String) continue;
    final kind = switch (owner.toLowerCase()) {
      'vllm' => EngineKind.vllm,
      'llamacpp' || 'llama.cpp' => EngineKind.llamaCpp,
      'library' => EngineKind.ollama,
      _ => EngineKind.unknown,
    };
    if (kind != EngineKind.unknown) return kind;
  }
  return EngineKind.unknown;
}

/// The context window this server **serves**, if the body states it outright.
///
/// Deliberately narrow. Only `max_model_len` qualifies — vLLM writes there what
/// it was actually launched with, so it is a fact about the running server.
///
/// llama.cpp's `meta.n_ctx_train` is *not* read, though it sits in the same
/// payload and would be easy to take. It is the window the **model** was
/// trained at, not the one `llama-server` was started with, and those part
/// routinely: a 128k model served at `--ctx-size 8192` would advertise 128k
/// here. Over-advertising is the failure this whole path exists to avoid — the
/// router picks nodes on this number, so an inflated one wins work it then
/// cannot do. Blank is the honest answer, and the person filling the form knows
/// what they launched.
///
/// Ollama and LM Studio both report a window too, but on their own native paths
/// rather than in `/models`. Reading them would mean a second request per
/// engine kind; the field is there to be typed into meanwhile.
int? servedContextFrom(String body) {
  for (final entry in _entries(body)) {
    final value = entry['max_model_len'];
    if (value is int && value > 0) return value;
    if (value is String) {
      final parsed = int.tryParse(value);
      if (parsed != null && parsed > 0) return parsed;
    }
  }
  return null;
}

/// The model ids in an OpenAI-shaped `/models` body, in the order given.
///
/// Lenient by design: this is read from whatever engine the person happens to
/// run, and the only thing riding on it is which names to offer in a dropdown.
/// A body it cannot make sense of yields an empty list, which shows the plain
/// text field — the same place someone typing a name by hand already ends up.
/// It must never throw: the server answered, so the address is good, and a
/// parse quibble is not a reason to refuse the join.
List<String> modelIdsFrom(String body) {
  final ids = <String>[];
  for (final entry in _entries(body)) {
    // `id`, `name`, `model` — the same three keys the CLI's own `_probe_models`
    // reads (`autonomous-grid/remote/probe.py`). The two are hand-duplicated
    // rather than shared, so they are kept spelled the same on purpose: a
    // picker offering a name the CLI would not have matched is a name the join
    // then fails on.
    final id = entry['id'] ?? entry['name'] ?? entry['model'];
    if (id is String && id.isNotEmpty && !ids.contains(id)) ids.add(id);
  }
  return List.unmodifiable(ids);
}

/// Every object entry in a `/models` body, or empty for anything unreadable.
///
/// `data` is the OpenAI envelope all three serve; `models` is what a couple
/// answer with on their own native path, and costs one line to accept.
List<Map<Object?, Object?>> _entries(String body) {
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on Object {
    return const [];
  }
  if (decoded is! Map) return const [];
  final entries = decoded['data'] ?? decoded['models'];
  if (entries is! List) return const [];
  return [
    for (final entry in entries)
      if (entry is Map) entry,
  ];
}
