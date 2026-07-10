local M = {}

local PROMPT_PLACEHOLDER = '{prompt}'

local config = {
  command = {
    'pi',
    '-t',
    'read,find,ls,grep',
    '--thinking',
    'high',
    '-p',
    PROMPT_PLACEHOLDER,
  },
}

M.config = config

function M.setup(opts)
  opts = opts or {}

  if opts.command ~= nil then
    config.command = opts.command
  end
end

local function validate_command(command)
  if type(command) ~= 'table' or #command == 0 then
    return nil, 'LLM command must be a non-empty argv list'
  end

  local argv = {}

  for i, arg in ipairs(command) do
    if type(arg) ~= 'string' then
      return nil, 'LLM command argument ' .. i .. ' must be a string'
    end

    argv[i] = arg
  end

  return argv
end

local function command_for_prompt(prompt)
  local configured_command = config.command

  if type(configured_command) == 'function' then
    local ok, command = pcall(function()
      return configured_command(prompt)
    end)

    if not ok then
      return nil, 'LLM command failed to build: ' .. tostring(command)
    end

    return validate_command(command)
  end

  if type(configured_command) ~= 'table' then
    return nil, 'LLM command must be an argv list or function'
  end

  local argv = {}
  local inserted_prompt = false

  for i, arg in ipairs(configured_command) do
    if type(arg) ~= 'string' then
      return nil, 'LLM command argument ' .. i .. ' must be a string'
    end

    local replaced, count = arg:gsub(PROMPT_PLACEHOLDER, function()
      return prompt
    end)

    if count > 0 then
      inserted_prompt = true
    end

    argv[i] = replaced
  end

  if #argv == 0 then
    return nil, 'LLM command must be a non-empty argv list'
  end

  -- If the template omits {prompt}, append it as the final argv item.
  if not inserted_prompt then
    table.insert(argv, prompt)
  end

  return argv
end

local function command_with_cwd(argv)
  -- Keep execution in Neovim's cwd without shell-joining user-provided args.
  local command = {
    'sh',
    '-c',
    'cd "$1" && shift && exec "$@"',
    'sh',
    vim.fn.getcwd(),
  }

  return vim.list_extend(command, argv)
end

local function run_llm_command(argv)
  local command = command_with_cwd(argv)

  if type(vim.system) == 'function' then
    local ok, result = pcall(function()
      return vim.system(command, { text = true }):wait()
    end)

    if not ok then
      return nil, 'LLM command failed: ' .. tostring(result)
    end

    if result.code ~= 0 then
      return nil, 'LLM command failed'
    end

    return result.stdout or ''
  end

  -- Neovim < 0.10 does not have vim.system(); this fallback may include stderr.
  local ok, output = pcall(vim.fn.system, command)

  if not ok then
    return nil, 'LLM command failed: ' .. tostring(output)
  end

  if vim.v.shell_error ~= 0 then
    return nil, 'LLM command failed'
  end

  return output
end

local function prompt_for_llm(user_prompt, selected_text)
  return table.concat({
    'filename: ' .. vim.fn.expand('%:t'),
    'path: ' .. vim.fn.expand('%:p'),
    'prompt: ' .. user_prompt,
    'selection:',
    selected_text,
    'Generate an exact replacement for the selected text using the user prompt and surrounding file context. Return only the replacement text.',
  }, '\n')
end

function M.complete(user_prompt, has_range)
  if has_range == 0 then
    vim.notify('ai-complete: select text visually first', vim.log.levels.ERROR)
    return
  end

  -- Use register z as scratch space, then restore it before returning.
  local old_z = vim.fn.getreg('z')
  local old_z_type = vim.fn.getregtype('z')

  -- `gv` restores the last Visual selection before yanking it into register z.
  vim.cmd([[silent normal! gv"zy]])

  local selected_text = vim.fn.getreg('z')
  local selected_type = vim.fn.getregtype('z')

  local llm_prompt = prompt_for_llm(user_prompt, selected_text)
  local command, command_error = command_for_prompt(llm_prompt)

  if not command then
    vim.fn.setreg('z', old_z, old_z_type)
    vim.notify('ai-complete: ' .. command_error, vim.log.levels.ERROR)
    return
  end

  vim.notify('ai-complete: generating...', vim.log.levels.INFO)
  vim.cmd('redraw')

  local output, output_error = run_llm_command(command)

  if output == nil then
    vim.fn.setreg('z', old_z, old_z_type)
    vim.notify('ai-complete: ' .. output_error, vim.log.levels.ERROR)
    return
  end

  -- Preserve characterwise, linewise, or blockwise paste behavior.
  vim.fn.setreg('z', output, selected_type)
  vim.cmd([[silent normal! gv"zp]])

  vim.fn.setreg('z', old_z, old_z_type)

  vim.notify('ai-complete: done.', vim.log.levels.INFO)
  vim.cmd('redraw')
end

return M
