# E2E Test Suite

End-to-end integration tests for all Makai providers. Tests are skipped gracefully when API credentials are not available.

## Running Tests

```bash
cd zig
zig build test-e2e
```

## Credential Configuration

Tests will try to load credentials in the following order:

1. **Environment variables** (e.g., `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`)
2. **~/.makai/auth.json** file:
   ```json
   {
     "providers": {
       "anthropic": { "api_key": "sk-ant-..." },
       "openai": { "api_key": "sk-..." },
       "google": { "api_key": "..." },
       "azure": { "api_key": "..." },
       "ollama": {},
       "google_vertex": { "api_key": "..." }
     }
   }
   ```

For Azure, also set `AZURE_RESOURCE_NAME`.
For Google Vertex, also set `GOOGLE_VERTEX_PROJECT_ID`.
For AWS Bedrock, set `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and optionally `AWS_SESSION_TOKEN`.

## Test Coverage

### Provider-Specific Tests (~300 LOC each)

- **anthropic.zig** (331 LOC): Basic generation, streaming, thinking mode, tool calling, abort, usage tracking
- **openai.zig** (327 LOC): Basic generation, streaming, reasoning mode, tool calling, abort, usage tracking
- **ollama.zig** (250 LOC): Basic generation, streaming, tool calling, abort, usage tracking
- **azure.zig** (363 LOC): Basic generation, streaming, reasoning mode, tool calling, abort, usage tracking
- **google.zig** (336 LOC): Basic generation, streaming, thinking mode, tool calling, abort, usage tracking
- **google_vertex.zig** (374 LOC): Basic generation, streaming, thinking mode, tool calling, abort, usage tracking
- **bedrock.zig** (378 LOC): Basic generation, streaming, thinking mode, tool calling, prompt caching, abort, usage tracking

### Cross-Provider Tests

- **abort.zig** (208 LOC): Cancellation behavior across providers
- **empty_messages.zig** (188 LOC): Edge cases with empty/whitespace content
- **unicode.zig** (249 LOC): Emoji, CJK, mixed scripts, RTL text, control characters

### Test Utilities

- **test_helpers.zig** (237 LOC): Shared utilities for credential loading, test skipping, event accumulation, and assertions

## Total: ~3,241 LOC across 11 files
