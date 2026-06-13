# AGENTS.md

Repository notes for coding agents working on `vim-ai-complete`.

## Project overview

This is a minimal Neovim plugin that exposes `:Ai <prompt>` for AI-assisted edits. The user visually selects text, runs `:Ai`, and the plugin replaces the selection with stdout from the `pi` coding agent.

The plugin intentionally invokes `pi` in a constrained way:

- read-only tools only: `read,find,ls,grep`
- `--thinking minimal` for speed
- no edit/write tools; Neovim performs the actual replacement
- prompt asks for replacement text only

## Repository layout

- `plugin/ai_complete.lua`
  - Neovim runtime entrypoint.
  - Guards against double loading with `vim.g.loaded_ai_complete`.
  - Defines the public `:Ai` command.
  - Adds a lowercase `:ai` command-line abbreviation.

- `lua/ai_complete/init.lua`
  - Main implementation module.
  - Builds the prompt sent to `pi`.
  - Captures the visual selection using register `z`.
  - Calls the external `pi` executable with `vim.fn.system`.
  - Replaces the selected text with the command output.
  - Restores register `z` afterward.

- `README.md`
  - User-facing description, usage, and installation notes.

- `LICENSE`
  - MIT license.

## Important behavior to preserve

- `:Ai` is selection-oriented. The current implementation relies on `gv` to restore the previous visual selection.
- Register `z` is temporary scratch space. Always save and restore its contents and type.
- Failed `pi` calls should leave the buffer unchanged.
- The generated text should be pasted using the original selection type: characterwise, linewise, or blockwise.
- Keep the implementation dependency-free and compatible with standard Neovim Lua APIs.

## Development notes

- There is currently no package metadata, test suite, formatter config, or CI.
- Keep changes small and plugin-style: simple Lua files under `plugin/` and `lua/`.
- Prefer clear behavior over clever abstractions; this project is intentionally tiny.
- If changing the `pi` invocation, update `README.md` so documented behavior stays accurate.
- If adding real line-range support, do not assume `opts.range` alone is enough; the current replacement path still uses `gv`.
- If adding async execution, preserve the current safety properties: no register clobbering, failed calls do not edit the buffer, and user feedback is visible.
