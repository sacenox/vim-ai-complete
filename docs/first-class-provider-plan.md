# First-class provider support plan

## Required outcome

Replace the external coding-agent command with provider support owned by this plugin.

The implementation is complete only when:

- `pi` and the configurable command backend are removed.
- The plugin authenticates a Codex subscription itself.
- The plugin stores, reloads, and refreshes its own credentials.
- The plugin sends inference requests directly with `curl`.
- The plugin runs the full model/tool loop itself.
- The model retains the current read-only project tools: `read`, `find`, `ls`, and `grep`.
- A successful final model response replaces the Visual selection using its original selection type.
- Authentication, transport, protocol, tool, and model failures leave the buffer unchanged.

This is not a text-only HTTP completion. The agent loop and its tools are part of first-class provider support because they replace behavior currently supplied by `pi`.

## 1. Remove the command backend

Delete:

- The default `pi` argv.
- `{prompt}` command templating.
- Command validation and cwd shell wrapper.
- The `command` setup option and function-valued command support.
- README instructions for configuring or installing an external LLM command.

There will be no compatibility path that invokes an external coding agent. The default and only initial provider will be `openai-codex`.

Keep provider selection explicit in the internal design so another first-class provider can implement the same authentication and inference interfaces later. Do not represent a command as a provider.

Proposed user configuration:

```lua
require("ai_complete").setup({
  provider = "openai-codex",
  model = "<verified Codex subscription model>",
  reasoning_effort = "high",
})
```

The shipped model default must be verified with the live Codex subscription endpoint during implementation rather than guessed in this plan. It remains configurable because model availability changes independently of the plugin.

## 2. Model each edit as a request

Create an in-memory request object for each `:Ai` invocation:

```text
id
buffer
cwd
filename
filetype
selection text
selection type
selection positions
user instruction
provider transcript
current round
current status
```

The request owns the complete provider lifecycle:

```text
capture selection
  -> obtain valid credentials
  -> send provider request
  -> parse response items
  -> execute tool calls
  -> append tool results
  -> repeat provider request
  -> validate final replacement
  -> replace selection
```

Generation remains blocking. This preserves the current rule that the selected target cannot change while its request is running. The buffer is not modified during intermediate model or tool rounds.

Use a stable request/session ID for all HTTP rounds belonging to the edit. This gives the provider a consistent prompt-cache and request identity without relying on provider-side conversation storage.

## 3. Own Codex browser authentication

Add provider authentication commands:

- `:AiLogin` starts normal browser authentication with a loopback callback.
- `:AiLogin!` starts manual mode for SSH, containers, or a browser on another machine.
- `:AiLogout` removes the stored Codex credentials.

Implement the Codex OAuth authorization-code flow with PKCE:

1. Generate a cryptographically secure verifier and state using Neovim's libuv API.
2. Derive the SHA-256 PKCE challenge and encode it as base64url.
3. Start a temporary HTTP listener on `localhost:1455` for `/auth/callback`.
4. Build the OpenAI authorization URL with the Codex public client ID, redirect URI, scope, challenge, and state.
5. Open the URL with `vim.ui.open()` and show the URL when opening is unavailable.
6. Parse the callback without logging its query string.
7. Reject missing codes and state mismatches.
8. Exchange the code at the OpenAI token endpoint using `curl`.
9. Decode the returned access-token payload to obtain the ChatGPT account ID.
10. Store the access token, refresh token, account ID, and expiry.
11. Close the listener and clear temporary flow state on success, cancellation, timeout, or failure.

Manual mode accepts either the authorization code or the complete redirect URL and performs the same state validation when a state value is present.

If `:Ai` has no usable credentials, it reports that `:AiLogin` is required and leaves the selection unchanged. Authentication does not occur implicitly in the middle of an edit request.

## 4. Own the credential store and refresh lifecycle

Store credentials in:

```text
stdpath("data")/ai-complete/auth.json
```

Use a versioned format keyed by provider. The store must:

- Create its directory with mode `0700`.
- Write files with mode `0600`.
- Write to a temporary file and atomically rename it.
- Validate decoded JSON and required field types.
- Fail closed on malformed or insecure credential data.
- Never include tokens, authorization codes, or account IDs in notifications or logs.

Reuse these stored credentials across Neovim sessions. Do not depend on the Codex CLI or `pi` credential stores.

Before the first inference round, refresh an access token that is expired or close to expiry. Persist both the new access token and a rotated refresh token. If inference returns `401`, perform one forced refresh and retry that HTTP round once. If refresh fails, require a new login rather than continuing with partial request state.

## 5. Implement a secure `curl` transport

All OpenAI token and inference HTTP traffic goes through argv-form `curl` execution. Never shell-join arguments.

For inference, call the Codex Responses endpoint:

```text
https://chatgpt.com/backend-api/codex/responses
```

The transport must:

- Send request JSON through standard input.
- Put bearer and account headers in a temporary mode-`0600` header file so secrets do not appear in process arguments.
- Remove temporary files on every return path.
- Capture the HTTP status, response headers, response body, and stderr separately.
- Set connection and total-request timeouts.
- Retry transient `408`, `429`, and `5xx` responses with bounded backoff and `Retry-After` support.
- Avoid retrying authentication and request-validation failures blindly.
- Return structured errors without leaking request headers or credentials.

Inference requests use `store = false` and SSE streaming at the protocol level. The Neovim workflow remains blocking: SSE is parsed to drive the agent loop, not to edit the buffer incrementally.

The SSE parser must support CRLF, multiple `data:` lines, comments, `[DONE]`, and final buffered data. It must reject malformed JSON events, explicit error events, failed responses, and streams that end without a terminal response event.

## 6. Implement the Codex Responses protocol

Build each request with:

- The configured model and reasoning effort.
- A stable system/developer instruction for edit behavior and tool use.
- The user's instruction, target path, selection metadata, and exact selected text.
- `read`, `find`, `ls`, and `grep` function definitions.
- `include = { "reasoning.encrypted_content" }` so reasoning items can be replayed during tool rounds.
- The stable edit request ID as the prompt-cache/session key.

Parse complete output items from `response.output_item.done`, including:

- Reasoning items and their encrypted content.
- Assistant message items and output text.
- Function-call items with their item ID, call ID, name, and JSON arguments.

Keep provider output items intact. Do not reconstruct IDs or discard reasoning items required by the next request.

For a tool round, append to the next request input in order:

1. All completed output items returned by the provider.
2. One `function_call_output` item for every function call, paired by `call_id`.

Then issue the next response request with the complete transcript. This continues until the provider returns a completed response with an assistant output message and no function calls.

If a response contains both text and function calls, preserve that text in the transcript but do not treat it as the replacement. Only the final no-tool response becomes the replacement.

An empty final output message is a valid deletion. A completed response with no assistant message is a protocol failure.

Use a configurable, bounded maximum number of tool rounds to prevent a malformed or uncooperative model from looping forever. Reaching the bound fails the edit without applying partial text.

## 7. Implement the read-only tools

The tools are owned by this plugin and execute locally. They must never edit files or run model-provided shell commands.

General behavior:

- Resolve relative paths against the request's captured Neovim cwd.
- Continue accepting absolute paths, matching the current agent behavior.
- Validate argument JSON and types before execution.
- Return tool errors as `function_call_output` so the model can recover.
- Bound result counts and bytes, and include continuation instructions when truncated.
- Use stable text output suitable for another model round.
- Execute every function call returned in a round, preserving response order.

### `read`

Schema:

```text
path: string
optional offset: 1-indexed line number
optional limit: line count
```

Behavior:

- If the path belongs to a loaded Neovim buffer, read its in-memory lines so unsaved edits are visible.
- Otherwise read the file through libuv/Neovim APIs.
- Return numbered range information and explicit continuation offsets when truncated.
- Reject directories, unreadable files, and unsupported binary content with a tool error.

### `ls`

Schema:

```text
optional path: directory, default cwd
optional limit: maximum entries
```

Behavior:

- List dotfiles.
- Sort entries deterministically.
- Add `/` to directories.
- Report empty directories and truncation explicitly.

### `find`

Schema:

```text
pattern: glob
optional path: search root, default cwd
optional limit: maximum results
```

Behavior:

- Recursively walk the requested root.
- Match the supplied glob against relative paths.
- Return normalized relative paths in deterministic order.
- Avoid descending into `.git` internals.
- Stop at result, byte, and traversal limits and report which limit was reached.

Use `rg --files` as an optional optimized implementation when available, with direct argv execution. Provide the Neovim/libuv walker as the functional fallback so `rg` is not a required dependency.

### `grep`

Schema:

```text
pattern: string
optional path: directory or file, default cwd
optional glob: file filter
optional ignoreCase: boolean
optional literal: boolean
optional context: surrounding line count
optional limit: maximum matches
```

Behavior:

- Return file paths, line numbers, and matching lines.
- Support literal and regular-expression searches.
- Skip binary files.
- Bound scanned files, output bytes, line length, and match count.
- Include surrounding lines when requested.

Use `rg` as an optional optimized implementation. Provide a Neovim regex/libuv fallback with the same result format and limits.

## 8. Define the agent instructions

The provider's system/developer instructions must tell the model:

- It is producing an exact replacement for the selected text.
- It has read-only project inspection tools.
- It should inspect the current file and relevant project files rather than guessing.
- The target buffer path and cwd are authoritative for resolving context.
- It cannot edit through tools; Neovim applies only its final response.
- Its final response must contain replacement text only, without commentary or Markdown fences.

The initial user input contains the exact selected text and selection coordinates. File context is obtained through `read`, including the in-memory current buffer, rather than using an arbitrary fixed surrounding-line window.

## 9. Preserve Neovim editing safety

Refactor completion into a protected cleanup path:

1. Validate that the command came from a Visual range.
2. Save register `z` and its type.
3. Restore the prior Visual selection and yank it into `z`.
4. Capture request metadata and start the blocking agent loop.
5. On final success, put output in `z` using the original selection type and replace with `gv"zp`.
6. Restore register `z` and its type regardless of success or failure.

Required invariants:

- No intermediate response changes the buffer.
- Failed login, refresh, HTTP, SSE, tool, loop, and model responses leave the buffer unchanged.
- Characterwise, linewise, and blockwise selections retain their existing paste behavior.
- Empty successful output deletes the selection.
- The replacement remains one normal Neovim undo step.

Show concise status notifications for authentication, provider rounds, and tool calls. Never include tool result contents or credential data in notifications.

## 10. Test the complete replacement

Add a headless Neovim test harness. Provider endpoints, browser opening, random bytes, time, and `curl` execution must be injectable in tests without changing production defaults.

Cover:

### Authentication and storage

- PKCE challenge and state generation.
- Callback parsing and state rejection.
- Manual redirect parsing.
- Token exchange and JWT account-ID extraction.
- Store creation, permissions, atomic replacement, malformed data, logout, and reuse.
- Proactive refresh, rotated refresh tokens, forced refresh after `401`, and refresh failure.
- Verification that secrets never appear in argv or user-facing errors.

### HTTP and SSE

- Successful SSE parsing with different line endings and event framing.
- Reasoning, message, and function-call output items.
- HTTP error parsing, transient retries, `Retry-After`, timeout, malformed events, explicit failure, and incomplete streams.

### Tools

- Argument validation and unknown tools.
- Relative and absolute paths.
- Loaded-buffer reads for unsaved content.
- Offset, limits, truncation, deterministic ordering, glob matching, regex and literal grep, binary skipping, and tool errors.
- `find` and `grep` with and without `rg` available.
- Confirmation that no tool can write or execute arbitrary commands.

### Agent loop

- A single final-response round.
- Multiple rounds containing `read`, `find`, `ls`, and `grep` calls.
- Multiple function calls in one response.
- Exact replay of reasoning and function-call items.
- Tool errors returned to the model followed by recovery.
- Text emitted before a tool call not being applied as the replacement.
- Empty final replacement.
- Tool-round limit failure with no partial edit.

### Neovim integration

- Characterwise, linewise, and blockwise replacements.
- Register restoration on every success and failure path.
- Failed requests leaving the buffer unchanged.
- One-step undo after success.
- No invocation or runtime requirement for `pi` or another coding-agent command.

Finally, run a live Codex subscription smoke test that logs in, performs an edit requiring at least one project tool call, applies the replacement, and refreshes credentials on a later Neovim process.

## 11. Documentation and cleanup

Update `README.md` to document:

- `curl` as the required external executable.
- Codex subscription login and logout.
- Credential location and permissions.
- Provider, model, reasoning, timeout, and agent-loop configuration.
- The four read-only tools and their local data-access implications.
- Blocking behavior and unchanged-buffer failure semantics.
- Removal of the `pi` and configurable command integrations.

Update installation examples so lazy loading includes the authentication commands.

After tests and the live smoke test pass, remove the completed first item from `TODO.md`.

## Proposed module layout

```text
plugin/ai_complete.lua
lua/ai_complete/init.lua
lua/ai_complete/request.lua
lua/ai_complete/agent.lua
lua/ai_complete/auth/store.lua
lua/ai_complete/auth/openai_codex.lua
lua/ai_complete/transport/curl.lua
lua/ai_complete/providers/openai_codex.lua
lua/ai_complete/tools/init.lua
lua/ai_complete/tools/read.lua
lua/ai_complete/tools/ls.lua
lua/ai_complete/tools/find.lua
lua/ai_complete/tools/grep.lua
tests/
```

The exact split can remain small where modules do not justify separate files, but authentication, provider protocol, agent-loop state, tool execution, and Neovim buffer mutation must remain separate responsibilities.
