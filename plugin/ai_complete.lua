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

if vim.fn.mapcheck('<leader>a', 'n') == '' then
  vim.keymap.set('n', '<leader>a', function()
    require('ai_complete').complete_at_cursor()
  end, { silent = true, desc = 'AI completion at cursor' })
end

-- User commands must start uppercase; support :ai as an abbreviation.
vim.cmd([[cabbrev ai Ai]])
