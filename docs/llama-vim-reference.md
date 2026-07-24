# `llama.vim` implementation reference

This document records the design of [`ggml-org/llama.vim`](https://github.com/ggml-org/llama.vim) for future roadmap work on `vim-ai-complete`. It describes the competitor; it is not a proposed design for this plugin.

Source reviewed: commit [`77db2afe488a7f700a2027527f17ab771988e358`](https://github.com/ggml-org/llama.vim/tree/77db2afe488a7f700a2027527f17ab771988e358), dated June 5, 2026.

## Origin and scope

`llama.vim` began as [`llama.cpp/examples/llama.vim`](https://github.com/ggml-org/llama.cpp/blob/master/examples/llama.vim). Its first standalone commit is named `llama.vim : init from llama.cpp`.

It now provides two related features:

1. Fill-in-the-middle (FIM) completion while typing.
2. Instruction-based replacement of a selected line range.

The second feature is relevant to the possible conversational direction of `vim-ai-complete`.

The plugin does not manage a model or server. The user runs one or more `llama-server` instances. `llama.vim` sends HTTP requests to configurable endpoints using asynchronous `curl` jobs. The defaults are:

```text
FIM:         http://127.0.0.1:8012/infill
Instruction: http://127.0.0.1:8012/v1/chat/completions
```

The instruction endpoint uses the OpenAI-compatible chat-completions protocol. Models and a Bearer API key can be configured, so the transport is not inherently limited to a local server, although the plugin is designed and documented around local inference.

## Repository structure

The implementation is small in file count but concentrated in one large module:

```text
plugin/llama.vim          Runtime entrypoint; calls llama#init()
autoload/llama.vim        Configuration, FIM, instruction edits, commands, and state
autoload/llama_debug.vim  In-memory debug log and scratch-buffer viewer
doc/llama.txt             Vim help
README.md                 Setup and usage
```

At the reviewed commit, `autoload/llama.vim` is about 2,100 lines. There are no automated tests or CI workflows.

## Startup and configuration

Loading `plugin/llama.vim` calls `llama#init()`. Initialization:

1. Verifies that `curl` is executable.
2. Merges `g:llama_config` with defaults.
3. Registers commands.
4. Initializes FIM caches, context queues, timers, and instruction-request state.
5. Detects Neovim extmarks or classic Vim text properties.
6. Enables the plugin unless `enable_at_startup` is false.

Commands include:

```text
:LlamaEnable
:LlamaDisable
:LlamaToggle
:LlamaToggleAutoFim
:LlamaStatus
:LlamaInstruct
:LlamaDebugToggle
:LlamaDebugClear
```

The plugin defines configurable mappings for FIM and instruction operations. Instruction editing defaults to:

```text
Visual selection + <leader>lli  Start an instructed edit
<leader>llr                     Rerun the current instruction
<leader>llc                     Continue/refine the current edit
Tab                             Accept a ready result
Escape                          Cancel the edit
```

## Overall data flow

```text
                         ┌───────────────────────┐
Editor events ──────────▶│ FIM context and cache │──────┐
                         └───────────────────────┘      │
                                                        ▼
Visual selection ───────▶ instruction request ───▶ curl job ───▶ llama-server
          │                       ▲                            │
          │                       │                            ▼
          └── extmark target      └── message history ◀── streamed response
                    │                                      │
                    └──────── virtual status/preview ◀─────┘
                                          │
                                 accept / cancel / rerun /
                                         continue
```

FIM and instruction editing share configuration and extra context, but maintain separate request state and endpoints.

## FIM completion internals

### Local context

For a completion, the plugin constructs:

- `input_prefix`: lines before the cursor.
- `prompt`: text on the current line before the cursor.
- `input_suffix`: text after the cursor and following lines.
- `input_extra`: chunks accumulated by the ring-context system.
- Indentation and sampling parameters.
- Prompt and generation time limits.

The default local context is 256 lines before and 64 lines after the cursor.

### Ring context

The plugin gradually collects additional chunks from:

- Yanked text.
- The current area on buffer entry and exit.
- The current area after writing a file.
- Areas near completion requests after substantial cursor movement.

Chunks enter a queue and are later moved into a fixed-size ring. Similar chunks are rejected or evicted using token-overlap similarity. The queue is processed while Neovim is in Normal mode or the cursor has been idle long enough.

When a chunk enters the ring, the plugin sends a zero-generation request containing the current extra context. `cache_prompt` lets `llama-server` prepare that context before a real completion is needed. This is a latency optimization built around llama.cpp's server-side prompt cache.

### Completion cache

Responses are stored in an LRU cache keyed by a SHA-256 hash of the local prefix, cursor-line prefix, and suffix. Each key can retain multiple completions.

When the cursor moves, the plugin first looks for an exact cached completion. It then searches nearby cache keys to determine whether newly typed text matches the beginning of a previous completion. If so, it displays the untyped remainder immediately.

This separates generation from rendering:

```text
request finishes → response enters cache
cursor moves     → cache lookup → render matching remainder
```

A first FIM request uses a short generation budget. Once its result is displayed, a speculative follow-up request treats the first result as already inserted and asks for a continuation. This makes longer completion chains available without delaying the first visible result.

### FIM presentation

Neovim uses extmarks with `virt_text` and `virt_lines`; classic Vim uses text properties. The plugin can show:

- Inline completion text.
- Additional generated lines.
- Cache and ring-buffer sizes.
- Prompt and generation timings.
- The selected completion number when alternatives exist.

The user can accept the full result, one line, or one word, or cycle through cached alternatives.

## Instruction-edit lifecycle

Instruction editing is an in-memory state machine associated with a selected line range.

```text
prompting → processing → generating → ready
                ▲                         │
                └──────── rerun ──────────┤
                                          ├── continue → generating
                                          ├── accept
                                          └── cancel
```

### 1. Selection and warm-up

`:LlamaInstruct` receives a line range, normally from Visual mode. Before asking for the instruction, the plugin builds the model context and sends a zero-token warm-up request.

It then reads the instruction with:

```vim
input('Instruction: ')
```

The warm-up request allows a local server to process and cache the selected code while the user types the instruction.

### 2. Prompt construction

For a new edit, the message history starts with a system message containing:

- A text-editing instruction that requires replacement text only.
- Ring-buffer context.
- Lines before the selection.
- The selected lines.
- Lines after the selection.

The user's instruction is appended as a `user` message.

Conceptually:

```text
system:
  editing rules
  CONTEXT
  PREFIX
  SELECTION
  SUFFIX

user:
  requested change
```

This is similar to the current `vim-ai-complete` prompt, but the structured messages remain available for later turns.

### 3. Per-edit request state

Every edit receives a numeric request ID and an entry in `s:inst_reqs`. Each entry contains approximately:

```text
id                 Request/session identifier
bufnr              Target buffer
range              Current target line range
status             proc, gen, or ready
inst               Current instruction
inst_prev          Conversation message history
result             Accumulated replacement text
job                Active curl job
n_gen              Streaming progress counter
extmark             Highlight anchor for the source range
extmark_virt        Virtual preview/status anchor
```

Because requests are stored by ID, multiple edits can exist at the same time. Commands such as accept, cancel, rerun, and continue choose an edit by finding a request whose range contains the cursor.

### 4. Target highlighting

The selected range is highlighted immediately. In Neovim, an extmark anchors the range as surrounding lines move. A second extmark displays status and preview lines below the target.

The target buffer itself remains unchanged during generation.

### 5. Streaming generation

The request is sent to `/v1/chat/completions` with streaming enabled. `curl` output is parsed as server-sent JSON lines. Assistant deltas are appended to the request's `result`.

The display progresses through three states:

- `proc`: endpoint, model, instruction, and “Processing”.
- `gen`: a generation counter and the latest generated line.
- `ready`: the complete proposed replacement as virtual lines.

The status is co-located with the selected code rather than shown in a global modal or notification.

### 6. Accept and cancel

Accepting a ready request:

1. Locates the active request under the cursor.
2. Removes its highlight and preview extmarks.
3. Deletes the currently tracked line range.
4. Inserts the generated result.
5. Removes the request from memory.

Canceling stops the job, removes its UI, and drops the request without changing the buffer.

### 7. Rerun

After a result is ready, rerun:

1. Clears the current result.
2. Removes the previous assistant response from message history.
3. Sends the same context and instruction again.

This produces an alternative answer without adding another conversational turn.

### 8. Continue/refine

Continue prompts with:

```vim
input('Next instruction: ')
```

It retains the earlier messages, appends the new user instruction, and generates another assistant response. After each completed request, the assistant result is added to history.

The conversation therefore has this form:

```text
system     Original selection and surrounding context
user       Initial instruction
assistant  First proposed replacement
user       Refinement
assistant  Refined replacement
...
```

Only the latest assistant response is offered as the replacement. The conversation exists only while the request remains active and is not persisted across Neovim sessions.

## Range tracking and concurrent edits

The implementation uses an extmark to follow the start of the selected range when text moves. It does not perform conflict reconciliation.

Notably, it does not:

- Store and validate the original selected text before applying.
- Reject application based on `changedtick`.
- Detect edits made inside the highlighted target.
- Rebase the generated result onto newer text.
- Merge concurrent user and model changes.

The tracked end is updated by preserving the original range's line count relative to the extmark's current start. If the user changes the target's shape while generation is active, accepting can replace newer text with a response generated from older text.

The practical interaction rule is that the highlighted range is reserved until the user accepts or cancels. This is visible but not enforced.

## Debugging and status

`LlamaStatus` queries `/v1/models` and reports whether the configured FIM and instruction models are available.

The debug module keeps an in-memory bounded log and renders it in a scratch split. It records request and completion information without introducing a file or logging dependency.

## Strengths relevant to future roadmap work

- A conversation is scoped to one requested edit.
- The edit has explicit state independent of the target buffer's contents.
- The original text remains unchanged until acceptance.
- Selection highlighting makes the active target visible.
- Progress and the generated result are displayed next to the target.
- Retry and refinement have distinct semantics.
- Refinement reuses structured message history.
- Multiple edit requests can be represented independently.
- Transport and model endpoints are configurable.
- The model server and plugin remain separate processes.

## Limitations and open questions

- It is a conversational text transformer, not a tool-using agent.
- Prompt input has the same long-command-line limitation currently tracked for `vim-ai-complete`.
- Conversation history is not displayed to the user.
- Sessions are neither named nor persisted.
- There is no way to return to an accepted or canceled conversation.
- Concurrent edits to the target are not made safe.
- Request and UI state are embedded in a large Vimscript module.
- Streaming parsing assumes convenient `curl` callback boundaries.
- Default global and buffer mappings can conflict with existing configuration.
- The source acknowledges problems removing mappings during disable.
- There are no automated tests for the state machine or editing behavior.

## Comparison with current `vim-ai-complete`

| Concern | `vim-ai-complete` now | `llama.vim` instruction edits |
|---|---|---|
| Model process | Configurable CLI, `pi` by default | Configurable HTTP endpoint, usually `llama-server` |
| Execution | Blocking, one process per request | Asynchronous `curl` job |
| Target | Previous Visual selection | Line range anchored by extmark |
| Result | Applied immediately on success | Previewed as virtual lines |
| Undo | Normal Neovim undo | Accept is required before mutation |
| Iteration | None | Rerun and continue |
| Conversation | None | Message list attached to edit request |
| Progress | Global notifications | Virtual status next to target |
| Concurrent target edits | Prevented by blocking | Allowed but not reconciled safely |
| Context | Prompt plus CLI access to files | Prefix, selection, suffix, and ring chunks |

## Questions to revisit when defining a roadmap

These are questions exposed by the reference implementation, not decisions:

- What constitutes a session: one selection, one buffer, or a broader conversation?
- Should the configured CLI own session persistence, or should the plugin own message history?
- How is a session identified and resumed?
- Should a response be applied immediately, previewed, or configurable?
- How should the UI show earlier prompts and responses?
- What should happen if the target changes while a request is active?
- Can multiple sessions run concurrently, and how does the user select one?
- What cancellation and retry primitives can a configurable hosted-model CLI expose?
- Which context belongs in the plugin prompt, and which context should the external agent discover itself?
- Does preparing a hosted session while the user enters a prompt provide enough latency benefit to justify the lifecycle complexity?
