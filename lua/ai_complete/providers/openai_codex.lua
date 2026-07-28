local curl = require('ai_complete.transport.curl')
local tools = require('ai_complete.tools')
local util = require('ai_complete.util')

local Provider = {}
Provider.__index = Provider

local RESPONSES_URL = 'https://chatgpt.com/backend-api/codex/responses'

local SYSTEM_INSTRUCTIONS = [[You are a code-editing agent operating inside Neovim. Produce an exact replacement for selected text. You have read-only project inspection tools. Inspect the current file and relevant project files instead of guessing. The target path and cwd in the request are authoritative for context and path resolution. Tools cannot edit files; Neovim applies only your final response. On the final turn, return replacement text only, with no commentary or Markdown fences.]]

local DEVELOPER_INSTRUCTIONS = [[Use read, find, ls, and grep when project context is relevant. The read tool sees unsaved loaded-buffer content. Do not claim to have edited files. A final empty output message means delete the selection.]]

local function message(role, text)
  return {
    type = 'message',
    role = role,
    content = {
      { type = 'input_text', text = text },
    },
  }
end

local function sse_events(body)
  body = body:gsub('\r\n', '\n'):gsub('\r', '\n')
  local events = {}
  local terminal = false
  local done_marker = false

  for block in (body .. '\n\n'):gmatch('(.-)\n\n') do
    local data = {}
    local event_name
    for line in (block .. '\n'):gmatch('(.-)\n') do
      if line:sub(1, 1) ~= ':' then
        local field, value = line:match('^([^:]+):%s?(.*)$')
        if field == 'data' then
          data[#data + 1] = value
        elseif field == 'event' then
          event_name = value
        end
      end
    end

    if #data > 0 then
      local encoded = table.concat(data, '\n')
      if encoded == '[DONE]' then
        done_marker = true
      else
        local ok, event = pcall(util.json_decode, encoded)
        if not ok or type(event) ~= 'table' then
          return nil, 'Codex returned a malformed SSE event'
        end
        if event_name == 'error' and event.type == nil then
          event.type = 'error'
        end
        if type(event.type) ~= 'string' then
          return nil, 'Codex returned an event without a type'
        end
        events[#events + 1] = event
        if event.type == 'response.completed' or event.type == 'response.done' then
          terminal = true
        end
      end
    end
  end

  if not terminal then
    return nil, done_marker and 'Codex stream ended without a terminal response' or 'Codex stream was incomplete'
  end
  return events
end

local function parse_events(events)
  local items = {}
  local terminal = false

  for _, event in ipairs(events) do
    if event.type == 'error' then
      return nil, 'Codex returned an explicit error event'
    end
    if event.type == 'response.failed' or event.type == 'response.incomplete' then
      return nil, 'Codex response failed'
    end
    if event.type == 'response.output_item.done' then
      if type(event.item) ~= 'table' or type(event.item.type) ~= 'string' then
        return nil, 'Codex returned a malformed output item'
      end
      items[#items + 1] = event.item
    elseif event.type == 'response.completed' or event.type == 'response.done' then
      local status = type(event.response) == 'table' and event.response.status or nil
      if status and status ~= 'completed' then
        return nil, 'Codex response did not complete successfully'
      end
      terminal = true
    end
  end

  if not terminal then
    return nil, 'Codex response had no terminal event'
  end

  local calls = {}
  local has_message = false
  local text = {}
  for _, item in ipairs(items) do
    if item.type == 'function_call' then
      if type(item.id) ~= 'string' or type(item.call_id) ~= 'string' or type(item.name) ~= 'string' or type(item.arguments) ~= 'string' then
        return nil, 'Codex returned a malformed function call'
      end
      calls[#calls + 1] = {
        id = item.id,
        call_id = item.call_id,
        name = item.name,
        arguments = item.arguments,
      }
    elseif item.type == 'message' and item.role == 'assistant' then
      has_message = true
      if type(item.content) ~= 'table' then
        return nil, 'Codex returned a malformed assistant message'
      end
      for _, part in ipairs(item.content) do
        if part.type == 'output_text' and type(part.text) == 'string' then
          text[#text + 1] = part.text
        elseif part.type == 'refusal' then
          return nil, 'Codex refused the edit request'
        else
          return nil, 'Codex returned an unsupported assistant content part'
        end
      end
    end
  end

  return {
    items = items,
    calls = calls,
    has_message = has_message,
    text = table.concat(text),
  }
end

function Provider.new(config, deps)
  return setmetatable({ config = config or {}, deps = deps or {} }, Provider)
end

function Provider:initial_input(request)
  local selection = table.concat({
    'Instruction: ' .. request.instruction,
    'Captured cwd: ' .. request.cwd,
    'Target path: ' .. (request.filename ~= '' and request.filename or '[unnamed buffer]'),
    'Filetype: ' .. (request.filetype ~= '' and request.filetype or '[unknown]'),
    string.format(
      'Selection: start line %d column %d; end line %d column %d; type %q',
      request.selection_positions.start_line,
      request.selection_positions.start_column,
      request.selection_positions.end_line,
      request.selection_positions.end_column,
      request.selection_type
    ),
    'Exact selected text:',
    request.selection_text,
  }, '\n')

  return {
    message('developer', DEVELOPER_INSTRUCTIONS),
    message('user', selection),
  }
end

function Provider:request_body(request, transcript)
  return {
    model = self.config.model,
    instructions = SYSTEM_INSTRUCTIONS,
    input = transcript,
    tools = tools.definitions(),
    tool_choice = 'auto',
    parallel_tool_calls = true,
    store = false,
    stream = true,
    reasoning = {
      effort = self.config.reasoning_effort,
      summary = 'auto',
    },
    text = { verbosity = 'low' },
    include = { 'reasoning.encrypted_content' },
    prompt_cache_key = request.id,
  }
end

function Provider:infer(request, transcript, credentials)
  local body_ok, body = pcall(util.json_encode, self:request_body(request, transcript))
  if not body_ok then
    return nil, { kind = 'protocol', message = 'could not encode Codex request' }
  end

  local transport = self.deps.http_request or curl.request
  local response, transport_error = transport({
    url = self.deps.responses_url or RESPONSES_URL,
    method = 'POST',
    headers = {
      Authorization = 'Bearer ' .. credentials.access_token,
      ['chatgpt-account-id'] = credentials.account_id,
      ['OpenAI-Beta'] = 'responses=experimental',
      originator = 'vim-ai-complete',
      session_id = request.id,
      conversation_id = request.id,
      Accept = 'text/event-stream',
      ['Content-Type'] = 'application/json',
      ['User-Agent'] = 'vim-ai-complete/1',
    },
    body = body,
    connect_timeout = self.config.connect_timeout,
    timeout = self.config.request_timeout,
    max_retries = self.config.max_retries,
    retry_delay_ms = self.config.retry_delay_ms,
  }, self.deps.transport)
  if not response then
    return nil, transport_error or { kind = 'transport', message = 'Codex request failed' }
  end
  if response.status == 401 then
    return nil, { kind = 'authentication', status = 401, message = 'Codex authentication expired' }
  end
  if response.status < 200 or response.status >= 300 then
    return nil, { kind = 'http', status = response.status, message = 'Codex returned HTTP ' .. response.status }
  end

  local events, sse_error = sse_events(response.body)
  if not events then
    return nil, { kind = 'protocol', message = sse_error }
  end
  local parsed, protocol_error = parse_events(events)
  if not parsed then
    return nil, { kind = 'protocol', message = protocol_error }
  end
  return parsed
end

Provider._sse_events = sse_events
Provider._parse_events = parse_events
Provider.SYSTEM_INSTRUCTIONS = SYSTEM_INSTRUCTIONS

return Provider
