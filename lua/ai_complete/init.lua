local agent = require('ai_complete.agent')
local Auth = require('ai_complete.auth.openai_codex')
local Request = require('ai_complete.request')

local M = {}

local config = {
  provider = 'openai-codex',
  model = 'gpt-5.6-sol',
  reasoning_effort = 'high',
  max_tool_rounds = 8,
  connect_timeout = 10,
  request_timeout = 300,
  auth_timeout = 300,
  refresh_window = 60,
  max_retries = 3,
  retry_delay_ms = 500,
}

local configurable = {
  provider = 'string',
  model = 'string',
  reasoning_effort = 'string',
  max_tool_rounds = 'number',
  connect_timeout = 'number',
  request_timeout = 'number',
  auth_timeout = 'number',
  refresh_window = 'number',
  max_retries = 'number',
  retry_delay_ms = 'number',
}

local dependencies = {}
local auth

M.config = config

function M.setup(opts)
  opts = opts or {}
  for key, expected in pairs(configurable) do
    if opts[key] ~= nil then
      if type(opts[key]) ~= expected then
        error(string.format('ai-complete: %s must be a %s', key, expected))
      end
      config[key] = opts[key]
    end
  end

  if config.provider ~= 'openai-codex' then
    error('ai-complete: only the openai-codex provider is supported')
  end
  if config.model == '' then
    error('ai-complete: model must not be empty')
  end
  local efforts = { none = true, minimal = true, low = true, medium = true, high = true, xhigh = true }
  if not efforts[config.reasoning_effort] then
    error('ai-complete: invalid reasoning_effort')
  end
  for _, key in ipairs({ 'max_tool_rounds', 'connect_timeout', 'request_timeout', 'auth_timeout', 'refresh_window', 'max_retries', 'retry_delay_ms' }) do
    if config[key] < 0 or config[key] ~= math.floor(config[key]) then
      error('ai-complete: ' .. key .. ' must be a non-negative integer')
    end
  end
  auth = nil
end

local function get_auth()
  if not auth then
    auth = dependencies.auth or Auth.new(config, dependencies.auth_deps)
  end
  return auth
end

local function visual_range(opts)
  if type(opts) ~= 'table' or not opts.range or opts.range == 0 then
    return nil, 'select text visually first'
  end

  local selection_type = vim.fn.visualmode()
  if selection_type ~= 'v' and selection_type ~= 'V' and selection_type ~= '\022' then
    return nil, 'select text visually first'
  end

  local first = vim.fn.getpos("'<")
  local last = vim.fn.getpos("'>")
  if first[2] == 0 or last[2] == 0 then
    return nil, 'select text visually first'
  end
  if opts.line1 and opts.line2 then
    local first_line = math.min(first[2], last[2])
    local last_line = math.max(first[2], last[2])
    if opts.line1 ~= first_line or opts.line2 ~= last_line then
      return nil, 'the command range is not the last Visual selection'
    end
  end
  return { first = first, last = last }
end

function M.complete(instruction, opts)
  local range, range_error = visual_range(opts)
  if not range then
    vim.notify('ai-complete: ' .. range_error, vim.log.levels.ERROR)
    return
  end

  local old_z = vim.fn.getreg('z')
  local old_z_type = vim.fn.getregtype('z')
  local applied = false
  local failure

  local ok = xpcall(function()
    vim.cmd([[silent normal! gv"zy]])
    local selected_text = vim.fn.getreg('z')
    local selected_type = vim.fn.getregtype('z')

    local request, request_error = Request.new(
      instruction,
      selected_text,
      selected_type,
      range.first,
      range.last,
      dependencies.request_deps
    )
    if not request then
      failure = request_error
      return
    end

    local run_agent = dependencies.run_agent or agent.run
    local output, agent_error = run_agent(request, config, {
      auth = get_auth(),
      provider = dependencies.provider,
      execute_tool = dependencies.execute_tool,
      tool_deps = dependencies.tool_deps,
      provider_deps = dependencies.provider_deps,
    })
    if output == nil then
      failure = agent_error
      return
    end
    if type(output) ~= 'string' then
      failure = 'provider returned a non-text replacement'
      return
    end

    vim.fn.setreg('z', output, selected_type)
    vim.cmd([[silent normal! gv"zp]])
    applied = true
  end, function()
    return 'internal failure'
  end)

  vim.fn.setreg('z', old_z, old_z_type)

  if not ok and not failure then
    failure = 'internal failure'
  end
  if not applied then
    vim.notify('ai-complete: ' .. tostring(failure or 'edit failed'), vim.log.levels.ERROR)
    return
  end

  vim.notify('ai-complete: done.', vim.log.levels.INFO)
  vim.cmd('redraw')
end

function M.login(manual)
  get_auth():login(manual)
end

function M.logout()
  get_auth():logout()
end

function M._set_dependencies(value)
  dependencies = value or {}
  auth = nil
end

return M
