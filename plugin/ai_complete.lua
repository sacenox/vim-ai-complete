if vim.g.loaded_ai_complete == 1 then
  return
end

vim.g.loaded_ai_complete = 1

vim.api.nvim_create_user_command('Ai', function(opts)
  require('ai_complete').dispatch(opts)
end, {
  nargs = '*',
  range = true,
})

vim.api.nvim_create_user_command('AiComplete', function()
  require('ai_complete').complete_at_cursor()
end, { desc = 'AI completion at cursor' })
