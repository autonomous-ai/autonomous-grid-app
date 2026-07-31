/// How an agent is meant to reach one connector.
///
/// The gateway decides this and says so, because only it knows both halves:
/// what scopes the account actually granted, and what the provider's MCP server
/// demands. Gmail is the case that forced the field — Google's MCP server
/// accepts only `gmail.readonly`/`gmail.modify`/`mail.google.com`, an
/// organisation can grant `gmail.send` and nothing more, and no amount of client
/// logic can bridge that. The app must not re-derive the answer; it obeys.
enum ConnectorTransport {
  /// A real MCP server. The entry goes into the agent's config as-is.
  mcp,

  /// No MCP server the grant can use, but the provider's REST API can do
  /// something. The app exposes [RestEntry.tools] to the agent through its own
  /// local MCP bridge — the agent never learns REST is involved.
  rest,

  /// Signed in, and nothing an agent can call. A real, reachable state; the
  /// screen says so rather than writing a config entry that fails at call time.
  none,
}

/// Reads the gateway's `transport`, or null when it did not say.
///
/// **Null and [ConnectorTransport.none] are different answers**, and collapsing
/// them is a bug rather than a tidy-up. Null means "no opinion" and the app
/// infers from what the payload carries; `none` is the gateway stating that this
/// grant reaches nothing, which suppresses inference entirely. Every token
/// already on disk predates the field, so reading absence as `none` would
/// silently unlink `github`, `Achriom MCP` and `Supabase MCP remote` on the
/// first launch after an update.
ConnectorTransport? parseTransport(Object? raw) {
  if (raw is! String) return null;
  return switch (raw.trim().toLowerCase()) {
    'mcp' => ConnectorTransport.mcp,
    'rest' => ConnectorTransport.rest,
    'none' => ConnectorTransport.none,
    _ => null,
  };
}

/// Where the credential goes on a REST call.
///
/// Modelled rather than assumed: providers disagree (`Authorization: Bearer …`
/// for most, `X-Figma-Token: …` for Figma), and the same lesson already applies
/// to `McpEntry.headers` — the server renders the convention, the app carries it.
class RestAuth {
  const RestAuth({
    this.location = 'header',
    this.name = 'Authorization',
    this.format = 'Bearer {access_token}',
  });

  /// Only `header` is honoured today. An unknown location parses, and the
  /// invoker refuses to send — a credential in the wrong place is worse than a
  /// tool that says it cannot run.
  final String location;

  final String name;

  /// A template over `{access_token}` and `{token_type}`.
  final String format;

  static RestAuth fromJson(Object? raw) {
    if (raw is! Map) return const RestAuth();
    String pick(String key, String fallback) {
      final value = raw[key];
      return value is String && value.isNotEmpty ? value : fallback;
    }

    return RestAuth(
      location: pick('in', 'header'),
      name: pick('name', 'Authorization'),
      format: pick('format', 'Bearer {access_token}'),
    );
  }
}

/// One argument of a tool, as the agent will see it.
///
/// This becomes JSON Schema in `tools/list`, so [description] is not
/// decoration: it is the only thing telling the model what to put here. A tool
/// the model fills in wrongly is worse than one it never calls.
class RestParam {
  const RestParam({
    this.type = 'string',
    this.required = false,
    this.description = '',
  });

  final String type;
  final bool required;
  final String description;

  static RestParam fromJson(Object? raw) {
    if (raw is! Map) return const RestParam();
    return RestParam(
      type: raw['type'] is String ? raw['type'] as String : 'string',
      required: raw['required'] == true,
      description: raw['description'] is String
          ? raw['description'] as String
          : '',
    );
  }
}

/// The HTTP call one tool makes.
///
/// [url], [query] and [json] are templates over the tool's own parameters,
/// written `{name}`. A map carrying `$encode` is handed to a named encoder
/// instead of being sent literally — see `rest_encoders.dart`.
class RestRequest {
  const RestRequest({
    required this.method,
    required this.url,
    this.query = const {},
    this.json,
    this.multipart,
  });

  final String method;
  final String url;
  final Map<String, String> query;
  final Object? json;

  /// An upload sent as `multipart/related` — metadata and file bytes in one
  /// request.
  ///
  /// ```jsonc
  /// "multipart": { "metadata": { "name": "{name}" },
  ///                "content": "{content}",
  ///                "content_type": "text/plain" }
  /// ```
  ///
  /// Modelled as its own shape rather than as another `$encode`, because the
  /// boundary string has to appear in both the body *and* the `Content-Type`
  /// header. An encoder returns only a body, so expressing this declaratively
  /// would mean the payload naming a boundary — and a mismatch between the two
  /// is a malformed request that reads as a provider error. The coupling stays
  /// in code, where it can't drift.
  ///
  /// Google Drive is why it exists: `files.create` with content is a multipart
  /// upload, and without it the only creatable thing is an empty file.
  final Map<String, Object?>? multipart;

  static RestRequest? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final url = raw['url'];
    if (url is! String || url.isEmpty) return null;
    // https only. A connector's credential rides on this request, and the
    // gateway is not a trusted enough source to be allowed to downgrade it.
    final parsed = Uri.tryParse(url);
    if (parsed == null || parsed.scheme != 'https' || parsed.host.isEmpty) {
      return null;
    }
    final method = raw['method'];
    final query = <String, String>{};
    final rawQuery = raw['query'];
    if (rawQuery is Map) {
      for (final entry in rawQuery.entries) {
        if (entry.key is String && entry.value is String) {
          query[entry.key as String] = entry.value as String;
        }
      }
    }
    return RestRequest(
      method: method is String && method.isNotEmpty
          ? method.toUpperCase()
          : 'GET',
      url: url,
      query: query,
      json: raw['json'],
      multipart: raw['multipart'] is Map
          ? (raw['multipart'] as Map).cast<String, Object?>()
          : null,
    );
  }
}

/// One callable the agent sees in `tools/list`.
class RestTool {
  const RestTool({
    required this.name,
    required this.description,
    required this.params,
    required this.request,
  });

  final String name;
  final String description;
  final Map<String, RestParam> params;
  final RestRequest request;

  /// The JSON Schema the agent is given for this tool's arguments.
  Map<String, Object?> get inputSchema => {
    'type': 'object',
    'properties': {
      for (final entry in params.entries)
        entry.key: {
          'type': entry.value.type,
          if (entry.value.description.isNotEmpty)
            'description': entry.value.description,
        },
    },
    'required': [
      for (final entry in params.entries)
        if (entry.value.required) entry.key,
    ],
  };

  static RestTool? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final name = raw['name'];
    if (name is! String || name.isEmpty) return null;
    final request = RestRequest.fromJson(raw['request']);
    if (request == null) return null;

    final params = <String, RestParam>{};
    final rawParams = raw['params'];
    if (rawParams is Map) {
      for (final entry in rawParams.entries) {
        if (entry.key is String) {
          params[entry.key as String] = RestParam.fromJson(entry.value);
        }
      }
    }
    return RestTool(
      name: name,
      description: raw['description'] is String
          ? raw['description'] as String
          : '',
      params: params,
      request: request,
    );
  }
}

/// Everything needed to serve one connector's REST surface as MCP tools.
///
/// Parsing is deliberately lenient, the same policy as `McpEntry.fromJson` and
/// `ConnectorTokenStore.read`: a tool the app cannot understand drops itself and
/// the others still work. A provider adding a field, or one malformed row,
/// must never blank a connector that was working yesterday.
class RestEntry {
  const RestEntry({required this.auth, required this.tools});

  final RestAuth auth;
  final List<RestTool> tools;

  bool get isEmpty => tools.isEmpty;

  static RestEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final rawTools = raw['tools'];
    if (rawTools is! List) return null;

    final tools = <RestTool>[];
    for (final entry in rawTools) {
      final tool = RestTool.fromJson(entry);
      if (tool != null) tools.add(tool);
    }
    // An entry with no usable tool is not an entry. Returning it would put a
    // server in the agent's config that answers `tools/list` with nothing.
    if (tools.isEmpty) return null;
    return RestEntry(auth: RestAuth.fromJson(raw['auth']), tools: tools);
  }

  Map<String, dynamic> toJson() => {
    'auth': {'in': auth.location, 'name': auth.name, 'format': auth.format},
    'tools': [
      for (final tool in tools)
        {
          'name': tool.name,
          if (tool.description.isNotEmpty) 'description': tool.description,
          'params': {
            for (final entry in tool.params.entries)
              entry.key: {
                'type': entry.value.type,
                if (entry.value.required) 'required': true,
                if (entry.value.description.isNotEmpty)
                  'description': entry.value.description,
              },
          },
          'request': {
            'method': tool.request.method,
            'url': tool.request.url,
            if (tool.request.query.isNotEmpty) 'query': tool.request.query,
            if (tool.request.json != null) 'json': tool.request.json,
            if (tool.request.multipart != null)
              'multipart': tool.request.multipart,
          },
        },
    ],
  };
}
