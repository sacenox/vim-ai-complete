if vim.g.loaded_ai_complete == 1 then
  return
end

vim.g.loaded_ai_complete = 1

vim.api.nvim_create_user_command('Ai', function(opts)
  require('ai_complete').complete(opts.args, opts.range)
end, {
  nargs = '*',
  range = true,
})

-- User commands must start uppercase; support :ai as an abbreviation.
vim.cmd([[cabbrev ai Ai]])
