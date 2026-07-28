local util = require('ai_complete.util')

local M = {}

function M.new(instruction, selection_text, selection_type, start_position, end_position, deps)
  local id, id_error = util.random_id(deps)
  if not id then
    return nil, id_error
  end

  local buffer = vim.api.nvim_get_current_buf()
  return {
    id = id,
    buffer = buffer,
    cwd = vim.fn.getcwd(),
    filename = vim.api.nvim_buf_get_name(buffer),
    filetype = vim.bo[buffer].filetype,
    selection_text = selection_text,
    selection_type = selection_type,
    selection_positions = {
      start_line = start_position[2],
      start_column = start_position[3],
      end_line = end_position[2],
      end_column = end_position[3],
    },
    instruction = instruction,
    provider_transcript = {},
    current_round = 0,
    status = 'captured',
  }
end

return M
