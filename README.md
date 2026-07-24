# vim-ai-complete

A small Neovim plugin for applying an LLM instruction to selected text.

## Usage

1. Select text in Visual mode.
2. Run `:Ai <prompt>`.
3. The selected text is replaced when generation succeeds.

Characterwise, linewise, and blockwise selections are supported. If generation fails, the buffer is left unchanged. A completed replacement is a normal Neovim edit and can be reverted with `u`.

## LLM command

The plugin uses `pi` by default. Make sure it is available on Neovim's `$PATH`, or configure another command:

```lua
require("ai_complete").setup({
  command = { "my-llm", "--prompt", "{prompt}" },
})
```

The configured command receives the generated prompt and writes replacement text to standard output. `{prompt}` may appear anywhere in the argument list; if omitted, the prompt is appended. For advanced integrations, `command` may be a function that receives the prompt and returns an argument list.

## How to install

This plugin uses the standard Neovim plugin layout, so it should work with any plugin manager. Make sure `pi` is installed and available on Neovim's `$PATH`, or configure another LLM command.

### lazy.nvim / LazyVim

Add a plugin spec like this:

```lua
-- ~/.config/nvim/lua/plugins/ai-complete.lua
return {
  "sacenox/vim-ai-complete",
  cmd = { "Ai" },
}
```

For local development, use `dir` instead:

```lua
return {
  dir = "~/src/vim-ai-complete",
  cmd = { "Ai" },
}
```

Note: when lazy-loading with `cmd = { "Ai" }`, the lowercase `:ai` abbreviation is only available after the plugin has loaded. Use `:Ai` to trigger loading, or define the abbreviation in `init`:

```lua
return {
  "sacenox/vim-ai-complete",
  cmd = { "Ai" },
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

Then restart Neovim.
