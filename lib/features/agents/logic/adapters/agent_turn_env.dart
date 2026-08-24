import 'package:grid_app/features/network/logic/app_guide_snippets.dart'
    show kCodexAppProviderId, kGridConversationHeader;

/// The chat a turn is answering, handed to the agent as an environment
/// variable.
///
/// An agent that schedules something has no way to say where the answer should
/// come back to: it knows it is in a conversation, but not which one the app
/// calls it. So a task set up mid-chat delivered into a thread of its own, and
/// the chat that asked for it never heard back — which reads exactly like the
/// task not having run.
///
/// An environment variable rather than a line in the prompt: it costs no
/// context, it cannot be paraphrased or "helpfully" corrected by the model, and
/// a shell command can use it directly (`--deliver grid:chat:$GRID_CHAT_ID`).
const String kGridChatIdEnv = 'GRID_CHAT_ID';

/// The Grid-specific environment for one turn in [conversationId].
///
/// Empty when the turn has no conversation yet — a chat that hasn't been saved
/// has no id to deliver into, and an empty variable would have the agent write
/// `grid:chat:` into a job nothing could route.
Map<String, String> gridTurnEnv(String? conversationId) =>
    conversationId == null || conversationId.isEmpty
    ? const {}
    : {kGridChatIdEnv: conversationId};

/// `ANTHROPIC_CUSTOM_HEADERS` for a turn — a real Claude Code CLI env var
/// (verified against the installed binary) that lets every relay call the
/// process makes for its lifetime carry this chat's [kGridConversationHeader],
/// so `/usage?conversation=` can attribute it exactly.
///
/// **The value is a literal `Name: Value` header line, never JSON.** Claude
/// Code parses this variable the way an HTTP message frames a header: it splits
/// on the first `:` and takes everything before it as the name. Handed
/// `{"X-Grid-Conversation": "…"}` it reads the name as `{"X-Grid-Conversation"`,
/// rejects it as an illegal header name and aborts the run *before* sending a
/// single request — so a JSON value doesn't lose the attribution, it loses the
/// whole turn. Verified against the installed binary (2.1.235) against a local
/// listener: the line form arrives intact on the outbound request.
///
/// Empty for the same reason [gridTurnEnv] is: a chat with no id yet has
/// nothing to attribute a call to.
Map<String, String> claudeConversationHeaderEnv(String? conversationId) =>
    conversationId == null || conversationId.isEmpty
    ? const {}
    : {'ANTHROPIC_CUSTOM_HEADERS': '$kGridConversationHeader: $conversationId'};

/// Codex's equivalent of [claudeConversationHeaderEnv] — a `-c` TOML
/// override on `model_providers.<id>.http_headers`, merged into the
/// OpenAI-SDK client's default headers the same way Claude Code's env var
/// does. Uses [kCodexAppProviderId], the same provider id
/// `codexGridOverrides` configures — a header on a different provider table
/// would never reach a relay call Codex actually makes.
List<String> codexConversationHeaderOverrides(String? conversationId) =>
    conversationId == null || conversationId.isEmpty
    ? const []
    : [
        'model_providers.$kCodexAppProviderId.http_headers'
            '.$kGridConversationHeader="$conversationId"',
      ];
