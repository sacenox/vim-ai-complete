local auth_path = assert(vim.env.AI_COMPLETE_SMOKE_AUTH, 'AI_COMPLETE_SMOKE_AUTH is required')
local sample_path = assert(vim.env.AI_COMPLETE_SMOKE_SAMPLE, 'AI_COMPLETE_SMOKE_SAMPLE is required')

local plugin = require('ai_complete')
local tools = require('ai_complete.tools')
local calls = {}

plugin.setup({
  provider = 'openai-codex',
  model = 'gpt-5.6-sol',
  reasoning_effort = 'high',
  max_tool_rounds = 4,
  request_timeout = 300,
})
plugin._set_dependencies({
  auth_deps = { store_path = auth_path },
  execute_tool = function(request, call, deps)
    calls[#calls + 1] = call.name
    return tools.execute(request, call, deps)
  end,
})

vim.cmd('enew!')
vim.api.nvim_buf_set_name(0, sample_path)
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  'local function add(a, b)',
  '  return a - b',
  'end',
})
vim.bo.filetype = 'lua'
vim.cmd('normal! 2GVy')
local first = vim.fn.getpos("'<")
local last = vim.fn.getpos("'>")
plugin.complete('Use the read tool to inspect README.md, then fix this function so it adds its arguments.', {
  range = 2,
  line1 = math.min(first[2], last[2]),
  line2 = math.max(first[2], last[2]),
})

local result = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
print('live tool calls: ' .. table.concat(calls, ','))
print('live result: ' .. result:gsub('\n', '\\n'))
assert(#calls > 0, 'the live model did not call a project tool')
assert(result:find('return a + b', 1, true), 'the live edit did not produce the expected replacement')
