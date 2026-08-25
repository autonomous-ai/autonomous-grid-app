import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/provider_node/logic/engine_endpoint.dart';
import 'package:grid_app/features/provider_node/logic/engine_reachability.dart';

/// The base a ready address resolved to, or null when it wasn't ready.
String? baseOf(String raw) => switch (readEngineAddress(raw)) {
  EngineAddressReady(:final base) => base,
  _ => null,
};

/// The message a rejected address carries, or null when it wasn't rejected.
String? rejectionOf(String raw) => switch (readEngineAddress(raw)) {
  EngineAddressRejected(:final message) => message,
  _ => null,
};

void main() {
  group('the endpoint someone pasted is cut back to a base', () {
    test('a full chat endpoint loses its path', () {
      // The line people actually have in hand: every one of these servers
      // documents itself with a `curl` against the full endpoint, so that is
      // what gets pasted.
      expect(
        baseOf('http://localhost:8080/v1/chat/completions'),
        'http://localhost:8080/v1',
      );
    });

    test('/chat/completions is cut before /completions is considered', () {
      // Both suffixes match this address. Cutting the shorter one would leave
      // `…/v1/chat` — an address that still looks plausible and answers
      // nothing, which is the worst of the possible outcomes.
      expect(
        baseOf('http://h:1/v1/chat/completions'),
        isNot(endsWith('/chat')),
      );
    });

    test('the other three OpenAI endpoints are cut too', () {
      expect(baseOf('http://h:1/v1/completions'), 'http://h:1/v1');
      expect(baseOf('http://h:1/v1/responses'), 'http://h:1/v1');
      expect(baseOf('http://h:1/v1/embeddings'), 'http://h:1/v1');
    });

    test('trailing slashes go, before and after the cut', () {
      expect(baseOf('http://h:1/v1/'), 'http://h:1/v1');
      expect(baseOf('http://h:1/v1/chat/completions/'), 'http://h:1/v1');
      expect(baseOf('http://h:1/v1///'), 'http://h:1/v1');
    });

    test('an endpoint in the middle of the path is left alone', () {
      // Only a *trailing* endpoint is a paste artefact. One in the middle is
      // somebody's real routing, and cutting it would break a working address.
      expect(
        baseOf('http://h:1/chat/completions/v1'),
        'http://h:1/chat/completions/v1',
      );
    });

    test('the surviving path keeps the exact case it was typed in', () {
      // Matched case-insensitively so a pasted `/V1/Chat/Completions` is still
      // recognised, but cut by length — the far side may well be
      // case-sensitive, and rewriting someone's path is not this function's
      // job.
      expect(baseOf('http://h:1/V1/Chat/Completions'), 'http://h:1/V1');
    });
  });

  group('nothing is ever added', () {
    test('a missing /v1 is left missing', () {
      // The whole design turns on this. Repairing it here would mean the
      // address that gets checked is not the address that gets joined — so the
      // check would pass against a URL the join never uses, and the join would
      // fail exactly as it does today, now wearing a green tick.
      expect(baseOf('http://localhost:8000'), 'http://localhost:8000');
    });

    test('a path that is already a base is untouched', () {
      expect(baseOf('http://localhost:8080/v1'), 'http://localhost:8080/v1');
      expect(
        baseOf('https://api.example.test/openai/v1'),
        'https://api.example.test/openai/v1',
      );
    });
  });

  group('what the field refuses', () {
    test('a bare host:port is refused rather than quietly repaired', () {
      // `Uri.parse` does not fail on this — it reads `localhost` as the SCHEME,
      // and the request then dies as an unnamed transport error instead of
      // anything a person could act on. Catching it here is the only place it
      // reads as a sentence.
      final message = rejectionOf('localhost:8080/v1');
      expect(message, isNotNull);
      expect(message, contains('http://'));
    });

    test('https is as welcome as http', () {
      expect(baseOf('https://h:1/v1'), 'https://h:1/v1');
    });

    test('the scheme is recognised in any casing', () {
      expect(baseOf('HTTP://h:1/v1'), 'HTTP://h:1/v1');
    });

    test('a query or fragment is refused, not stapled over', () {
      // `<base>/models` cannot be built from an address carrying a query — the
      // result is nonsense — and it is always a paste that took too much.
      expect(rejectionOf('http://h:1/v1?key=abc'), isNotNull);
      expect(rejectionOf('http://h:1/v1#frag'), isNotNull);
    });

    test('an address with no server name in it is refused', () {
      expect(rejectionOf('http://'), isNotNull);
    });

    test('a blank field is not an error', () {
      // Red before the first keystroke reads as the app being broken.
      expect(readEngineAddress(''), isA<EngineAddressEmpty>());
      expect(readEngineAddress('   '), isA<EngineAddressEmpty>());
    });
  });

  group('the two URLs a ready address answers for', () {
    test('the check calls /models on the base that will be joined', () {
      // The invariant this whole path exists to hold: one base, both uses.
      const address = EngineAddressReady('http://h:1/v1');
      expect(address.modelsUrl, 'http://h:1/v1/models');
      expect(address.chatUrl, 'http://h:1/v1/chat/completions');
    });

    test('a base missing /v1 builds the URL that will 404', () {
      // Written down because it is the case this feature was built for: the
      // check fails at exactly the address the engine would have been called
      // on.
      const address = EngineAddressReady('http://h:8000');
      expect(address.modelsUrl, 'http://h:8000/models');
    });
  });

  group('reading what a server says it serves', () {
    test('the OpenAI shape every one of them serves', () {
      const body =
          '{"object":"list","data":[{"id":"Qwen3.8-27B"},{"id":"gemma"}]}';
      expect(modelIdsFrom(body), ['Qwen3.8-27B', 'gemma']);
    });

    test('ids keep their exact case', () {
      // The relay routes case-SENSITIVELY: `Qwen/Qwen3.8-27B` answers where
      // `qwen/qwen3.8-27b` returns 503. Folding a name on the way into the
      // picker would hand the join a model id the grid cannot route.
      const body = '{"data":[{"id":"Qwen/Qwen3.8-27B"}]}';
      expect(modelIdsFrom(body), ['Qwen/Qwen3.8-27B']);
    });

    test('a duplicate id is listed once', () {
      const body = '{"data":[{"id":"a"},{"id":"a"},{"id":"b"}]}';
      expect(modelIdsFrom(body), ['a', 'b']);
    });

    test('a body it cannot read yields no names rather than throwing', () {
      // The server answered, so the address is good. A parse quibble must not
      // become a reason to refuse the join — it just means typing the name.
      expect(modelIdsFrom('not json'), isEmpty);
      expect(modelIdsFrom('{"data":"nope"}'), isEmpty);
      expect(modelIdsFrom('[]'), isEmpty);
      expect(modelIdsFrom(''), isEmpty);
    });

    test('an entry with no usable name is skipped, not counted', () {
      const body = '{"data":[{"id":""},{"nope":1},{"id":"real"}]}';
      expect(modelIdsFrom(body), ['real']);
    });
  });

  group('which engine answered', () {
    test('vLLM is known by max_model_len', () {
      const body =
          '{"data":[{"id":"Qwen/Qwen3.8-27B","owned_by":"vllm",'
          '"max_model_len":40960}]}';
      expect(engineKindFrom(body), EngineKind.vllm);
    });

    test('llama.cpp is known by its meta block', () {
      const body = '{"data":[{"id":"m","meta":{"n_ctx_train":32768}}]}';
      expect(engineKindFrom(body), EngineKind.llamaCpp);
    });

    test('Ollama is known by owned_by', () {
      const body = '{"data":[{"id":"llama3:latest","owned_by":"library"}]}';
      expect(engineKindFrom(body), EngineKind.ollama);
    });

    test('a structural marker beats an owned_by string', () {
      // A field somebody had a reason to add is harder to coincide with than a
      // string, so it decides first.
      const body =
          '{"data":[{"id":"m","owned_by":"library",'
          '"max_model_len":8192}]}';
      expect(engineKindFrom(body), EngineKind.vllm);
    });

    test('any other OpenAI-compatible server is unknown, not an error', () {
      // SGLang, LiteLLM, a hand-written shim — all reachable, all usable, none
      // recognised. Unknown is a normal answer here.
      const body = '{"object":"list","data":[{"id":"m","object":"model"}]}';
      expect(engineKindFrom(body), EngineKind.unknown);
      expect(engineKindFrom('not json'), EngineKind.unknown);
    });
  });

  group('the context window a server states outright', () {
    test('vLLM says what it was launched with, and that is taken', () {
      // `max_model_len` is a fact about the RUNNING server, which is the only
      // kind of context number worth advertising.
      const body = '{"data":[{"id":"m","max_model_len":40960}]}';
      expect(servedContextFrom(body), 40960);
    });

    test("llama.cpp's trained window is deliberately NOT taken", () {
      // `n_ctx_train` sits right there in the same payload and is the window
      // the MODEL was trained at, not the one llama-server was started with. A
      // 128k model served at --ctx-size 8192 would advertise 128k, and the
      // router picks nodes on that number — so the node wins work it cannot do.
      // Blank is the honest answer.
      const body = '{"data":[{"id":"m","meta":{"n_ctx_train":131072}}]}';
      expect(servedContextFrom(body), isNull);
    });

    test('a server that says nothing leaves it unknown', () {
      // Unknown is a state the grid handles: with no --ctx-size the CLI omits
      // `context_window` entirely and the relay records "unknown" rather than a
      // fabricated number.
      expect(servedContextFrom('{"data":[{"id":"m"}]}'), isNull);
      expect(servedContextFrom('not json'), isNull);
    });

    test('a nonsense window is ignored rather than passed on', () {
      expect(servedContextFrom('{"data":[{"max_model_len":0}]}'), isNull);
      expect(servedContextFrom('{"data":[{"max_model_len":"lots"}]}'), isNull);
    });

    test('a window sent as a string is still read', () {
      expect(servedContextFrom('{"data":[{"max_model_len":"8192"}]}'), 8192);
    });
  });

  group('when the Model field may offer a list', () {
    test('a recognised engine with names offers them', () {
      const reach = EngineReachable(['a', 'b'], EngineKind.vllm);
      expect(reach.canOfferModels, isTrue);
    });

    test('an unrecognised engine keeps the text field', () {
      // Its `data[].id` list may well be right, but a picker built from a body
      // nobody recognised might be listing the wrong thing — and a wrong pick
      // is harder to notice than a name typed by hand.
      const reach = EngineReachable(['a', 'b'], EngineKind.unknown);
      expect(reach.canOfferModels, isFalse);
    });

    test('a recognised engine that listed nothing keeps the text field', () {
      // An empty dropdown is a control with nothing to do.
      const reach = EngineReachable([], EngineKind.ollama);
      expect(reach.canOfferModels, isFalse);
    });
  });
}
