# vim-ai-complete

A small Neovim plugin for applying an LLM instruction to selected text.

## How to install

This plugin uses the standard Neovim plugin layout, so it should work with any plugin manager. Make sure `pi` is installed and available on Neovim's `$PATH`, or configure another LLM command.

### lazy.nvim / LazyVim

Add a plugin spec like this:

```lua
-- ~/.config/nvim/lua/plugins/ai-complete.lua
return {
  "sacenox/vim-ai-complete",
  cmd = { "Ai", "AiComplete" },
}
```

For local development, use `dir` instead:

```lua
return {
  dir = "~/src/vim-ai-complete",
  cmd = { "Ai", "AiComplete" },
}
```

Note: when lazy-loading with `cmd = { "Ai", "AiComplete" }`, the lowercase `:ai` abbreviation is only available after the plugin has loaded. Use `:Ai` to trigger loading, or define the abbreviation in `init`:

```lua
return {
  "sacenox/vim-ai-complete",
  cmd = { "Ai", "AiComplete" },
  init = function()
    vim.cmd([[cabbrev ai Ai]])
  end,
}
```

### Native packages

Without a plugin manager:

```bash
cd ~/.config/nvim/pack/local/start
git clone https://github.com/sacenox/vim-ai-complete.git
```

## Usage

### Replace visual selection

1. Select text in Visual mode.
2. Run `:Ai <prompt>`.
3. The selected text is replaced when generation succeeds.

Run `:Ai` without a prompt to open a multiline input window below the last selected line. Press `<Enter>` to add a line and `<S-Enter>` to submit, including when the prompt is empty. Press `<Esc>` or `<C-c>` to cancel. The status area shows `Generating...` while the blocking LLM command runs.

Characterwise, linewise, and blockwise selections are supported. If generation fails, the buffer is left unchanged. A completed replacement is a normal Neovim edit and can be reverted with `u`.

### Completion at the cursor

Run `:AiComplete` to insert a completion at the cursor, before the current character, without selecting text or entering a prompt. The agent receives the current buffer (including unsaved changes) and cursor position, and decides what to insert and whether to read additional context. Generation is blocking, just like `:Ai`.

The insertion is a single undoable edit: press `u` to discard it. Failed generation leaves the buffer unchanged.

### Optional key mappings

The plugin does not bind keys automatically. For example, add these mappings to your Neovim configuration to use `<leader>a` for completion in Normal mode and the prompt window in Visual mode:

```lua
vim.keymap.set("n", "<leader>a", "<cmd>AiComplete<CR>", { desc = "AI completion at cursor" })
vim.keymap.set("x", "<leader>a", ":Ai<CR>", { desc = "AI replace selection" })
```

The Visual-mode mapping uses `:` to preserve the selected range. Both mappings also work with the command-based lazy-loading examples above.

## LLM command

The plugin uses `pi` by default. Make sure it is available on Neovim's `$PATH`, or configure another command:

```lua
require("ai_complete").setup({
  command = { "my-llm", "--prompt", "{prompt}" },
})
```

The configured command receives the generated prompt and writes replacement text to standard output. `{prompt}` may appear anywhere in the argument list; if omitted, the prompt is appended. For advanced integrations, `command` may be a function that receives the prompt and returns an argument list.

### Claude Code, Codex, or Cursor

Choose one configuration below. Install and authenticate the corresponding CLI first, and make sure its executable is on Neovim's `$PATH`. These examples work for both `:Ai` and cursor completion. Use Neovim 0.10+ so stderr (such as CLI progress messages) stays separate from the text inserted into your buffer; the older fallback may mix it into stdout.

#### Claude Code

```lua
require("ai_complete").setup({
  command = {
    "claude", "-p", "--output-format", "text",
    "--tools", "Read,Glob,Grep",
    "--strict-mcp-config",
    "{prompt}",
  },
})
```

Uses print mode with text output, restricts built-in tools to reading/searching, and disables configured MCP servers. See the [Claude Code CLI reference](https://code.claude.com/docs/en/cli-reference).

#### Codex CLI

```lua
require("ai_complete").setup({
  command = {
    "codex", "exec", "--sandbox", "read-only",
    "--color", "never", "{prompt}",
  },
})
```

`codex exec` sends progress to stderr and only the final answer to stdout. The explicit read-only sandbox keeps workspace files from being edited by the agent. Run Neovim with its working directory inside a Git repository; to work outside one, add `"--skip-git-repo-check"` before `"{prompt}"`. See [non-interactive mode](https://developers.openai.com/codex/non-interactive-mode) and the [CLI reference](https://developers.openai.com/codex/cli/reference).

#### Cursor CLI

```lua
require("ai_complete").setup({
  command = {
    "agent", "--mode=ask", "-p",
    "--output-format", "text", "{prompt}",
  },
})
```

Cursor's CLI executable is `agent`. Ask mode explores code without editing files; print mode with text output returns only the final assistant message. See [CLI modes](https://cursor.com/docs/cli/using) and [output formats](https://cursor.com/docs/cli/reference/output-format).
