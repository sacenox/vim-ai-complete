# vim-ai-complete

A simple Neovim plugin that mimics Cursor's selection prompt and Zed's editor assist feature using a configurable LLM CLI (`pi` by default).

## LLM command

By default, the plugin uses `pi` with the original read-only tools and minimal thinking level:

```lua
{ "pi", "-t", "read,find,ls,grep", "--thinking", "minimal", "-p", "{prompt}" }
```

The generated prompt replaces `{prompt}`. On Neovim 0.10+, stdout becomes the replacement text; older versions fall back to Neovim's legacy `system()` output, which may include stderr.

To use another CLI, call `setup()` from your Neovim config:

```lua
require("ai_complete").setup({
  command = { "my-llm", "--prompt", "{prompt}" },
})
```

If `{prompt}` is omitted, the prompt is appended as the final argument. For advanced cases, `command` may be a function that receives the prompt and returns the full argv list.

## How to use

Select a visual block, line, or selection, and then type `:Ai <your prompt here>`. The selection will be replaced with the model's output.
You can give any kind of prompt. The plugin uses the configured command's output as the replacement, and the default prompt instructs it to return only that replacement.
There is no visual feedback on submit, but if an error occurs, you will see it.

Just select, prompt, and send. Then hope for the best. Each prompt is its own individual session; there is no continuation unless your configured CLI provides one.

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
