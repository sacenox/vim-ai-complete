# AGENTS.md

Repository notes for coding agents working on `vim-ai-complete`.

## Project overview

This is a Neovim plugin that exposes `:Ai <instruction>` for Codex-assisted edits. The user visually selects text, runs `:Ai`, and the plugin replaces the selection only after its complete provider/tool loop succeeds.

The plugin owns its Codex subscription integration:

- OAuth authorization-code login with PKCE through `:AiLogin` / `:AiLogin!`
- private, persistent credentials and refresh handling
- direct Codex Responses requests through argv-form `curl`
- a blocking model/tool loop
- local read-only `read`, `find`, `ls`, and `grep` tools

It does not invoke an external coding agent or expose a configurable command backend.

## Repository layout

- `plugin/ai_complete.lua`
  - Neovim runtime entrypoint and public commands.

- `lua/ai_complete/init.lua`
  - Configuration, authentication commands, and protected Visual replacement.

- `lua/ai_complete/request.lua`
  - Per-edit request metadata.

- `lua/ai_complete/agent.lua`
  - Credential, provider, tool-call, and transcript loop.

- `lua/ai_complete/auth/`
  - Secure credential store and Codex OAuth/refresh lifecycle.

- `lua/ai_complete/transport/curl.lua`
  - Secret-safe blocking HTTP transport and retries.

- `lua/ai_complete/providers/openai_codex.lua`
  - Codex request construction and SSE Responses parsing.

- `lua/ai_complete/tools/`
  - Definitions and implementations of the four read-only tools.

- `tests/`
  - Headless deterministic suite and explicit live smoke harness.

## Important behavior to preserve

- `:Ai` is selection-oriented and relies on `gv` to restore the prior Visual selection.
- Register `z` is temporary scratch space. Always save and restore its contents and type.
- Failed auth, transport, protocol, tool, loop, and model operations leave the buffer unchanged.
- Generated text uses the original characterwise, linewise, or blockwise selection type.
- Empty successful output deletes the selection.
- A successful replacement remains one normal Neovim undo step.
- No model-provided tool input may write a file or execute an arbitrary command.
- Credentials, authorization codes, account IDs, request headers, and tool output must not appear in notifications.

## Development notes

- Keep authentication, provider protocol, agent state, tools, and buffer mutation as separate responsibilities.
- Keep provider endpoints, browser opening, randomness, time, and HTTP execution injectable for tests.
- Use argv-form process execution; never shell-join model or credential data.
- If changing provider behavior or configuration, update `README.md`.
- Run deterministic tests with:

  ```bash
  nvim --headless -u tests/minimal_init.lua -l tests/run.lua
  ```

- The live smoke harness is `tests/live_smoke.lua`; it requires a temporary plugin-format credential path in `AI_COMPLETE_SMOKE_AUTH`.
