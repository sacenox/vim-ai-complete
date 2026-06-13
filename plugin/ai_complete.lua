-- Guard against loading this plugin more than once in a Neovim session.
if vim.g.loaded_ai_complete == 1 then
  return
end

-- Mark the plugin as loaded so re-sourcing the runtime files is a no-op.
vim.g.loaded_ai_complete = 1

-- Define :Ai as the public entry point for invoking ai_complete.
-- Forward any command arguments and range information to the Lua module.
vim.api.nvim_create_user_command('Ai', function(opts)
  require('ai_complete').complete(opts.args, opts.range)
end, {
  -- Accept zero or more arguments after :Ai.
  nargs = '*',
  -- Allow :Ai to be called with a line range.
  range = true,
})

-- Neovim user commands must start with uppercase, so :ai is a tiny alias.
vim.cmd([[cabbrev ai Ai]])
