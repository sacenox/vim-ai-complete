if vim.g.loaded_ai_complete == 1 then
  return
end

vim.g.loaded_ai_complete = 1

vim.api.nvim_create_user_command('Ai', function(opts)
  require('ai_complete').complete(opts.args, opts)
end, {
  nargs = '*',
  range = true,
  desc = 'Replace the Visual selection with a Codex-generated edit',
})

vim.api.nvim_create_user_command('AiLogin', function(opts)
  require('ai_complete').login(opts.bang)
end, {
  bang = true,
  desc = 'Log in to a Codex subscription (! uses manual callback mode)',
})

vim.api.nvim_create_user_command('AiLogout', function()
  require('ai_complete').logout()
end, {
  desc = 'Remove stored Codex credentials',
})

-- User commands must start uppercase; support :ai as an abbreviation.
vim.cmd([[cabbrev ai Ai]])
