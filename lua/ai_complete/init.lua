local M = {}

-- Constants and module state

local PROMPT_PLACEHOLDER = '{prompt}'
local REPLACEMENT_INSTRUCTION =
  'Generate an exact replacement for the selected text using the user prompt and surrounding file context. Return only the replacement text exactly as it should appear in the file. Do not add commentary, formatting wrappers, or surrounding code fences.'
local COMPLETION_INSTRUCTION =
  'Complete the text at the cursor based on the surrounding context. Decide what and how much to insert, and read additional context as needed. Return only the text to insert, without repeating existing text, commentary, formatting wrappers, or surrounding code fences.'

---@class AiCompletePromptState
---@field changedtick integer
---@field closed boolean
---@field opts { range: integer, line1: integer, line2: integer }
---@field prompt_buf integer
---@field prompt_win integer
---@field source_buf integer
---@field source_win integer

---@type AiCompletePromptState?
local active_prompt

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

-- Shared feedback, file context, and LLM execution

local function notify_error(message)
  vim.notify('ai-complete: ' .. message, vim.log.levels.ERROR)
end

local function notify_done()
  vim.notify('ai-complete: done.', vim.log.levels.INFO)
  vim.cmd('redraw')
end

local function file_context()
  return 'filename: ' .. vim.fn.expand('%:t') .. '\npath: ' .. vim.fn.expand('%:p')
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

local function command_failure(code, output)
  local details = vim.trim(output or '')
  return 'LLM command failed (exit ' .. code .. ')' .. (details ~= '' and ': ' .. details or '')
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
      return nil, command_failure(result.code, result.stderr)
    end

    return result.stdout or ''
  end

  -- Neovim < 0.10 does not have vim.system(); this fallback may include stderr.
  local ok, output = pcall(vim.fn.system, command)

  if not ok then
    return nil, 'LLM command failed: ' .. tostring(output)
  end

  if vim.v.shell_error ~= 0 then
    return nil, command_failure(vim.v.shell_error, output)
  end

  return output
end

local function generate(prompt)
  local command, command_error = command_for_prompt(prompt)

  if not command then
    error(command_error, 0)
  end

  vim.notify('ai-complete: Generating...', vim.log.levels.INFO)
  vim.cmd('redraw')

  local output, output_error = run_llm_command(command)

  if output == nil then
    error(output_error, 0)
  end

  return output
end

-- Feature: replace a visual selection

local function prompt_for_selection(user_prompt, selected_text)
  return table.concat({
    file_context(),
    'prompt: ' .. user_prompt,
    'selection:',
    selected_text,
    REPLACEMENT_INSTRUCTION,
  }, '\n')
end

function M.complete(user_prompt, has_range)
  if has_range == 0 then
    notify_error('select text visually first')
    return
  end

  -- Restore scratch register z even if yanking, generation, or replacement fails.
  local old_z = vim.fn.getreg('z', 1, true)
  local old_z_type = vim.fn.getregtype('z')

  local ok, err = pcall(function()
    -- `gv` restores the last Visual selection before yanking it into register z.
    vim.cmd([[silent normal! gv"zy]])

    local selected_text = vim.fn.getreg('z')
    local selected_type = vim.fn.getregtype('z')

    local output = generate(prompt_for_selection(user_prompt, selected_text))

    -- Preserve characterwise, linewise, or blockwise paste behavior.
    vim.fn.setreg('z', output, selected_type)
    vim.cmd([[silent normal! gv"zp]])
  end)

  vim.fn.setreg('z', old_z, old_z_type)

  if not ok then
    notify_error(tostring(err))
    return
  end

  notify_done()
end

local function has_visual_range(opts)
  if opts.range ~= 2 then
    return false
  end

  local start_mark = vim.fn.getpos("'<")
  local end_mark = vim.fn.getpos("'>")

  return start_mark[2] > 0 and end_mark[2] > 0 and opts.line1 == start_mark[2] and opts.line2 == end_mark[2]
end

local function close_prompt(state, restore_focus)
  if state.closed then
    return
  end

  state.closed = true

  if active_prompt == state then
    active_prompt = nil
  end

  if vim.api.nvim_get_current_win() == state.prompt_win then
    pcall(function()
      vim.cmd('stopinsert')
    end)
  end

  if vim.api.nvim_win_is_valid(state.prompt_win) then
    pcall(vim.api.nvim_win_close, state.prompt_win, true)
  end

  if vim.api.nvim_buf_is_valid(state.prompt_buf) then
    pcall(vim.api.nvim_buf_delete, state.prompt_buf, { force = true })
  end

  if restore_focus and vim.api.nvim_win_is_valid(state.source_win) then
    pcall(vim.api.nvim_set_current_win, state.source_win)
  end
end

local function source_is_valid(state)
  return vim.api.nvim_win_is_valid(state.source_win)
    and vim.api.nvim_buf_is_valid(state.source_buf)
    and vim.api.nvim_win_get_buf(state.source_win) == state.source_buf
    and vim.api.nvim_buf_get_changedtick(state.source_buf) == state.changedtick
    and has_visual_range(state.opts)
end

function M.prompt(opts)
  if not has_visual_range(opts) then
    notify_error('select text visually first')
    return
  end

  if active_prompt then
    close_prompt(active_prompt, false)
  end

  local source_win = vim.api.nvim_get_current_win()
  local source_buf = vim.api.nvim_get_current_buf()
  local selection_end = vim.fn.getpos("'>")
  local source_width = vim.api.nvim_win_get_width(source_win)
  local source_height = vim.api.nvim_win_get_height(source_win)
  local available_width = math.max(1, source_width - 2)
  local available_height = math.max(1, source_height - 2)
  local prompt_width = math.min(80, math.max(20, math.floor(source_width * 0.7)), available_width)
  local prompt_height = math.min(5, available_height)
  local prompt_buf = vim.api.nvim_create_buf(false, true)

  vim.bo[prompt_buf].bufhidden = 'wipe'
  vim.bo[prompt_buf].filetype = 'ai-complete-prompt'

  local prompt_win = vim.api.nvim_open_win(prompt_buf, true, {
    relative = 'win',
    win = source_win,
    bufpos = { selection_end[2] - 1, math.max(0, selection_end[3] - 1) },
    row = 1,
    col = 0,
    anchor = 'NW',
    width = prompt_width,
    height = prompt_height,
    border = 'single',
    style = 'minimal',
  })

  ---@type AiCompletePromptState
  local state = {
    changedtick = vim.api.nvim_buf_get_changedtick(source_buf),
    closed = false,
    opts = opts,
    prompt_buf = prompt_buf,
    prompt_win = prompt_win,
    source_buf = source_buf,
    source_win = source_win,
  }

  active_prompt = state

  local function cancel(restore_focus)
    close_prompt(state, restore_focus)
  end

  local function submit()
    if state.closed then
      return
    end

    local prompt = table.concat(vim.api.nvim_buf_get_lines(prompt_buf, 0, -1, false), '\n')
    close_prompt(state, true)

    -- Let the submit mapping finish so Neovim can leave Insert mode and redraw
    -- before the blocking LLM command starts.
    vim.schedule(function()
      if not source_is_valid(state) then
        notify_error('the selected text changed while entering the prompt')
        return
      end

      M.complete(prompt, opts.range)
    end)
  end

  vim.keymap.set({ 'i', 'n' }, '<S-CR>', submit, { buffer = prompt_buf, nowait = true })
  vim.keymap.set({ 'i', 'n' }, '<Esc>', function()
    cancel(true)
  end, { buffer = prompt_buf, nowait = true })
  vim.keymap.set({ 'i', 'n' }, '<C-c>', function()
    cancel(true)
  end, { buffer = prompt_buf, nowait = true })

  vim.api.nvim_create_autocmd('WinLeave', {
    buffer = prompt_buf,
    once = true,
    callback = function()
      cancel(false)
    end,
  })

  vim.cmd('startinsert')
end

function M.dispatch(opts)
  if not has_visual_range(opts) then
    notify_error('select text visually first')
    return
  end

  if opts.args == '' then
    M.prompt(opts)
    return
  end

  M.complete(opts.args, opts.range)
end

-- Feature: complete at the cursor

function M.complete_at_cursor()
  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row, col = cursor[1] - 1, cursor[2]

  local ok, err = pcall(function()
    local prompt = table.concat({
      file_context(),
      COMPLETION_INSTRUCTION,
      'Insertion is immediately before line ' .. cursor[1] .. ', byte column ' .. (col + 1) .. ' (1-based).',
      'Current buffer (including unsaved changes):',
      table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n'),
    }, '\n')
    local output = generate(prompt)

    -- Close the previous undo block so rejecting this completion preserves earlier edits.
    vim.bo[buf].undolevels = vim.bo[buf].undolevels
    vim.api.nvim_buf_set_text(buf, row, col, row, col, vim.split(output, '\n', { plain = true }))
  end)

  if not ok then
    notify_error(tostring(err))
    return
  end

  notify_done()
end

return M
