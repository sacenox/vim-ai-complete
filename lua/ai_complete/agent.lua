local Auth = require('ai_complete.auth.openai_codex')
local Provider = require('ai_complete.providers.openai_codex')
local tools = require('ai_complete.tools')

local M = {}

local function notify(message)
  vim.notify('ai-complete: ' .. message, vim.log.levels.INFO)
  vim.cmd('redraw')
end

function M.run(request, config, deps)
  deps = deps or {}
  if config.provider ~= 'openai-codex' then
    return nil, 'unsupported provider: ' .. tostring(config.provider)
  end

  local auth = deps.auth or Auth.new(config, deps.auth_deps)
  local provider = deps.provider or Provider.new(config, deps.provider_deps)
  local execute_tool = deps.execute_tool or tools.execute

  request.status = 'authenticating'
  local credentials, auth_error = auth:get_valid()
  if not credentials then
    request.status = 'failed'
    return nil, auth_error
  end

  local transcript = provider:initial_input(request)
  request.provider_transcript = transcript
  local tool_rounds = 0

  while true do
    request.current_round = request.current_round + 1
    request.status = 'requesting'
    notify(string.format('provider round %d...', request.current_round))

    local response, provider_error = provider:infer(request, transcript, credentials)
    if not response and provider_error and provider_error.status == 401 then
      credentials, auth_error = auth:refresh(credentials)
      if not credentials then
        request.status = 'failed'
        return nil, auth_error
      end
      response, provider_error = provider:infer(request, transcript, credentials)
    end
    if not response then
      request.status = 'failed'
      return nil, provider_error and provider_error.message or 'provider request failed'
    end

    for _, item in ipairs(response.items) do
      transcript[#transcript + 1] = item
    end

    if #response.calls == 0 then
      if not response.has_message then
        request.status = 'failed'
        return nil, 'Codex completed without an assistant message'
      end
      request.status = 'completed'
      return response.text
    end

    tool_rounds = tool_rounds + 1
    if tool_rounds > config.max_tool_rounds then
      request.status = 'failed'
      return nil, 'maximum tool rounds reached'
    end

    request.status = 'using_tools'
    for _, call in ipairs(response.calls) do
      notify('tool ' .. call.name .. '...')
      local output = execute_tool(request, call, deps.tool_deps)
      transcript[#transcript + 1] = {
        type = 'function_call_output',
        call_id = call.call_id,
        output = output,
      }
    end
  end
end

return M
