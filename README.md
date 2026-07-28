# vim-ai-complete

A small Neovim plugin for applying a Codex subscription edit to selected text.

The plugin owns authentication, inference, and its read-only agent loop. It sends requests directly to the Codex Responses endpoint with `curl`; it does not invoke `pi` or another coding agent.

## Requirements

- Neovim 0.10 or newer
- `curl` on `$PATH`
- A ChatGPT account with Codex subscription access

`rg` is used to speed up `find` and `grep` when available. It is optional; both tools have libuv/Neovim fallbacks.

## Usage

Log in first:

```vim
:AiLogin
```

This opens the OpenAI authorization page and listens for its callback on `localhost:1455`. For SSH sessions, containers, or a browser on another machine, use manual mode and paste either the authorization code or complete redirect URL:

```vim
:AiLogin!
```

Then:

1. Select text in Visual mode.
2. Run `:Ai <instruction>`.
3. The selection is replaced when the complete agent request succeeds.

For example:

```vim
:Ai extract this into a well-named local function
```

Characterwise, linewise, and blockwise selections preserve their selection type. An empty successful response deletes the selection. A completed replacement is one normal Neovim edit and can be reverted with `u`.

Generation is blocking. Authentication, refresh, HTTP, protocol, tool, and model failures leave the buffer unchanged. The temporary `z` register is restored on every path.

Remove this plugin's stored credentials with:

```vim
:AiLogout
```

## Configuration

```lua
require("ai_complete").setup({
  provider = "openai-codex",
  model = "gpt-5.6-sol",
  reasoning_effort = "high",
  max_tool_rounds = 8,
  connect_timeout = 10,
  request_timeout = 300,
  auth_timeout = 300,
  refresh_window = 60,
  max_retries = 3,
  retry_delay_ms = 500,
})
```

`openai-codex` is currently the only provider. The default model was verified against the live Codex subscription catalog during implementation, but model availability changes; set `model` when your account exposes a different model.

Timeout and refresh-window values are seconds. `retry_delay_ms` is milliseconds. `max_tool_rounds` bounds the number of request rounds that can invoke tools.

## Local tools and credentials

The model can call four read-only tools:

- `read` reads files and uses unsaved content from loaded Neovim buffers.
- `ls` lists directories, including dotfiles.
- `find` recursively matches file globs without descending into `.git` internals.
- `grep` searches text files with literal or regular-expression matching and optional context.

Relative paths resolve from the Neovim working directory captured when `:Ai` starts. Absolute paths are accepted. Tool results, file counts, scanned bytes, and line lengths are bounded. No tool can write files or run a model-provided command. Using the plugin therefore gives the selected Codex model read access to local files reachable through these tools.

Credentials are stored independently of Codex CLI and other agent credentials at:

```text
stdpath("data")/ai-complete/auth.json
```

The directory uses mode `0700`; the file and temporary HTTP header files use mode `0600`. Credential writes use an atomic replacement. Access tokens are refreshed before expiry and once after an inference `401`. Tokens, authorization codes, and account IDs are not placed in process arguments or notifications.

## Installation

This plugin uses the standard Neovim plugin layout and works with any plugin manager.

### lazy.nvim / LazyVim

```lua
-- ~/.config/nvim/lua/plugins/ai-complete.lua
return {
  "sacenox/vim-ai-complete",
  cmd = { "Ai", "AiLogin", "AiLogout" },
  opts = {},
}
```

For local development, use `dir`:

```lua
return {
  dir = "~/src/vim-ai-complete",
  cmd = { "Ai", "AiLogin", "AiLogout" },
  opts = {},
}
```

The lowercase `:ai` abbreviation becomes available after the plugin loads. Use `:Ai` to trigger lazy loading.

### Native packages

```bash
cd ~/.config/nvim/pack/local/start
git clone https://github.com/sacenox/vim-ai-complete.git
```

Then restart Neovim and run `:AiLogin`.

## Tests

Run the deterministic headless suite with:

```bash
nvim --headless -u tests/minimal_init.lua -l tests/run.lua
```

`tests/live_smoke.lua` is the explicit live-endpoint harness. It expects temporary plugin-format credentials through `AI_COMPLETE_SMOKE_AUTH` and does not read another application's credential store itself.
