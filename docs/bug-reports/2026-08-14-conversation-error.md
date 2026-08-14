# Bug: Conversation encounters error during Codex agent execution

## Summary
The Grid app shows "The conversation encountered an error" when Codex agent turns fail due to model provider issues. The error occurs mid-conversation when using remote models through the relay API.

## Steps to Reproduce
1. Start a Codex agent session in the Grid app
2. Run a multi-turn conversation that involves tool usage
3. Observe the error appearing after a model provider failure

## Expected Behavior
The app should gracefully handle model provider failures and allow the user to retry with a different model or agent.

## Actual Behavior
The conversation halts with "The conversation encountered an error" message, requiring a full restart.

## Error Details from Logs

### Error 1 - Stream Disconnection
```
[2026-08-14 11:43:12] ERROR agent   codex turn failed: stream disconnected before completion: DeepSeek-V4-Flash-0731 is not a multimodal model
[2026-08-14 11:43:12] ERROR cli     codex exec -m DeepSeek-V4-Flash-0731 (agent) → FAILED (1m54s): Codex couldn't finish: stream disconnected before completion: DeepSeek-V4-Flash-0731 is not a multimodal model
```

### Error 2 - 503 Service Unavailable
```
[2026-08-14 12:02:11] ERROR agent   codex turn failed: unexpected status 503 Service Unavailable: {"detail":"No providers available for this model"}, url: https://grid.autonomous.ai/.../relay/v1/responses
[2026-08-14 12:02:11] ERROR cli     codex exec -m minimax/minimax-m3 (agent) → FAILED (32s): No machine on this grid is serving a model Codex can use right now.
```

### Error 3 - 400 Image Content Not Supported
```
[2026-08-14 11:32:05] ERROR api     POST https://grid.autonomous.ai/grid-3378218621364f16/relay/v1/chat/completions → FAILED status=400 (0s): No active provider for this model supports image content
```

## Environment
- **App Version**: 0.3.19 (CLI), Sparkle updates to 0.3.39 and 0.3.40 installed during session
- **OS**: macOS (Apple Silicon)
- **Grid CLI**: grid 0.3.19
- **Local Model**: Qwen3.5-2B-UD-IQ2_M.gguf (0.94 GB)
- **Remote Models Tried**: DeepSeek-V4-Flash-0731, minimax/minimax-m3, Laguna-S-2.1
- **Timezone**: Asia/Ho_Chi_Minh
- **Date**: 2026-08-14

## Additional Context
- API health checks (/relay/v1/grid/overview) continued returning 200 OK after the errors
- This suggests model/provider-level failures rather than infrastructure downtime
- The error appears to be a relay/API layer issue where:
  1. DeepSeek model stream disconnects mid-response claiming it's not multimodal
  2. minimax model returns 503 with no available providers
  3. Some models return 400 for image content
- After these errors, the UI shows a generic error screen requiring restart
