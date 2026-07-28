local Store = require('ai_complete.auth.store')
local curl = require('ai_complete.transport.curl')
local util = require('ai_complete.util')

local Auth = {}
Auth.__index = Auth

local PROVIDER = 'openai-codex'
local CLIENT_ID = 'app_EMoamEEZ73f0CkXaXp7hrann'
local AUTHORIZE_URL = 'https://auth.openai.com/oauth/authorize'
local TOKEN_URL = 'https://auth.openai.com/oauth/token'
local REDIRECT_URI = 'http://localhost:1455/auth/callback'
local JWT_CLAIM = 'https://api.openai.com/auth'

local function notify(message, level)
  vim.notify('ai-complete: ' .. message, level or vim.log.levels.INFO)
end

local function decode_account_id(access_token)
  local payload = access_token:match('^[^.]+%.([^.]+)%.[^.]+$')
  if not payload then
    return nil, 'access token is malformed'
  end
  local decoded = util.base64url_decode(payload)
  if not decoded then
    return nil, 'access token is malformed'
  end
  local ok, claims = pcall(util.json_decode, decoded)
  local auth = ok and type(claims) == 'table' and claims[JWT_CLAIM] or nil
  local account_id = type(auth) == 'table' and auth.chatgpt_account_id or nil
  if type(account_id) ~= 'string' or account_id == '' then
    return nil, 'access token has no ChatGPT account'
  end
  return account_id
end

local function pkce(deps)
  local verifier_bytes, random_error = util.random_bytes(32, deps)
  if not verifier_bytes then
    return nil, random_error
  end
  local state_bytes, state_error = util.random_bytes(32, deps)
  if not state_bytes then
    return nil, state_error
  end

  local verifier = util.base64url_encode(verifier_bytes)
  local digest = util.hex_to_bytes(vim.fn.sha256(verifier))
  if not digest then
    return nil, 'could not derive PKCE challenge'
  end

  return {
    verifier = verifier,
    challenge = util.base64url_encode(digest),
    state = util.base64url_encode(state_bytes),
  }
end

local function authorization_url(flow, deps)
  return (deps.authorize_url or AUTHORIZE_URL) .. '?' .. util.form_encode({
    client_id = CLIENT_ID,
    code_challenge = flow.challenge,
    code_challenge_method = 'S256',
    codex_cli_simplified_flow = 'true',
    id_token_add_organizations = 'true',
    originator = 'vim-ai-complete',
    redirect_uri = REDIRECT_URI,
    response_type = 'code',
    scope = 'openid profile email offline_access',
    state = flow.state,
  })
end

local function parse_redirect(value, expected_state)
  if type(value) ~= 'string' then
    return nil, 'authorization response is missing'
  end
  value = vim.trim(value)
  if value == '' then
    return nil, 'authorization was cancelled'
  end

  if not value:find('://', 1, true) and not value:find('?', 1, true) then
    return value
  end

  local path_and_query = value
  local scheme_end = value:find('://', 1, true)
  if scheme_end then
    local slash = value:find('/', scheme_end + 3, true)
    path_and_query = slash and value:sub(slash) or '/'
  end
  local path, query = path_and_query:match('^([^?]*)%??(.*)$')
  if path ~= '/auth/callback' then
    return nil, 'authorization callback path is invalid'
  end

  local values, query_error = util.parse_query(query)
  if not values then
    return nil, query_error
  end
  if values.error then
    return nil, 'authorization was rejected'
  end
  if values.state ~= nil and values.state ~= expected_state then
    return nil, 'authorization state did not match'
  end
  if type(values.code) ~= 'string' or values.code == '' then
    return nil, 'authorization code is missing'
  end
  return values.code
end

function Auth.new(config, deps)
  config = config or {}
  deps = deps or {}
  return setmetatable({
    config = config,
    deps = deps,
    store = deps.store or Store.new(deps.store_path, deps),
    flow = nil,
  }, Auth)
end

function Auth:_transport(opts)
  local request = self.deps.http_request or curl.request
  return request(opts, self.deps.transport)
end

function Auth:_token_request(fields, prior_refresh)
  local response, transport_error = self:_transport({
    url = self.deps.token_url or TOKEN_URL,
    method = 'POST',
    headers = {
      ['Content-Type'] = 'application/x-www-form-urlencoded',
      Accept = 'application/json',
    },
    body = util.form_encode(fields),
    connect_timeout = self.config.connect_timeout,
    timeout = self.config.request_timeout,
    max_retries = self.config.max_retries,
    retry_delay_ms = self.config.retry_delay_ms,
  })
  if not response then
    return nil, transport_error and transport_error.message or 'token request failed'
  end
  if response.status < 200 or response.status >= 300 then
    return nil, 'token endpoint returned HTTP ' .. response.status
  end

  local ok, value = pcall(util.json_decode, response.body)
  if not ok or type(value) ~= 'table' then
    return nil, 'token endpoint returned malformed data'
  end
  if type(value.access_token) ~= 'string' or value.access_token == '' then
    return nil, 'token response is missing an access token'
  end
  local refresh_token = value.refresh_token or prior_refresh
  if type(refresh_token) ~= 'string' or refresh_token == '' then
    return nil, 'token response is missing a refresh token'
  end
  if type(value.expires_in) ~= 'number' or value.expires_in <= 0 then
    return nil, 'token response has an invalid expiry'
  end

  local account_id, account_error = decode_account_id(value.access_token)
  if not account_id then
    return nil, account_error
  end

  return {
    access_token = value.access_token,
    refresh_token = refresh_token,
    account_id = account_id,
    expires_at = util.now_ms(self.deps) + value.expires_in * 1000,
  }
end

function Auth:get_valid()
  local credentials, load_error = self.store:load(PROVIDER)
  if load_error then
    return nil, load_error
  end
  if not credentials then
    return nil, 'run :AiLogin first'
  end

  local refresh_window = (self.config.refresh_window or 60) * 1000
  if credentials.expires_at <= util.now_ms(self.deps) + refresh_window then
    return self:refresh(credentials)
  end
  return credentials
end

function Auth:refresh(credentials)
  credentials = credentials or self.store:load(PROVIDER)
  if not credentials then
    return nil, 'run :AiLogin first'
  end

  local refreshed, refresh_error = self:_token_request({
    client_id = CLIENT_ID,
    grant_type = 'refresh_token',
    refresh_token = credentials.refresh_token,
  }, credentials.refresh_token)
  if not refreshed then
    self.store:remove(PROVIDER)
    return nil, 'session refresh failed; run :AiLogin again'
  end

  local saved, save_error = self.store:save(PROVIDER, refreshed)
  if not saved then
    return nil, save_error
  end
  return refreshed
end

function Auth:logout()
  self:_clear_flow()
  local ok, err = self.store:remove(PROVIDER)
  if not ok then
    notify(err, vim.log.levels.ERROR)
    return
  end
  notify('logged out')
end

function Auth:_exchange(flow, code)
  notify('finishing login...')
  local credentials, exchange_error = self:_token_request({
    client_id = CLIENT_ID,
    code = code,
    code_verifier = flow.verifier,
    grant_type = 'authorization_code',
    redirect_uri = REDIRECT_URI,
  })
  if not credentials then
    notify(exchange_error, vim.log.levels.ERROR)
    return
  end

  local saved, save_error = self.store:save(PROVIDER, credentials)
  if not saved then
    notify(save_error, vim.log.levels.ERROR)
    return
  end
  notify('login complete')
end

function Auth:_clear_flow()
  local flow = self.flow
  self.flow = nil
  if not flow then
    return
  end
  if flow.timer and not flow.timer:is_closing() then
    flow.timer:stop()
    flow.timer:close()
  end
  if flow.server and not flow.server:is_closing() then
    flow.server:close()
  end
end

function Auth:_finish_flow(flow, value)
  if self.flow ~= flow then
    return
  end
  local code, parse_error = parse_redirect(value, flow.state)
  self:_clear_flow()
  if not code then
    notify(parse_error, vim.log.levels.ERROR)
    return
  end
  self:_exchange(flow, code)
end

function Auth:_open(url)
  local opener = self.deps.open_url
  if not opener and vim.ui and type(vim.ui.open) == 'function' then
    opener = vim.ui.open
  end

  local opened = false
  if opener then
    local ok, result = pcall(opener, url)
    opened = ok and result ~= false
  end
  if not opened then
    notify('open this URL: ' .. url)
  end
end

function Auth:_start_listener(flow)
  local server = vim.uv.new_tcp()
  flow.server = server
  local bound, bind_error = server:bind('127.0.0.1', 1455)
  if not bound then
    server:close()
    flow.server = nil
    return nil, 'could not listen on localhost:1455: ' .. tostring(bind_error)
  end

  local listened, listen_error = server:listen(16, function(error)
    if error or self.flow ~= flow then
      return
    end
    local client = vim.uv.new_tcp()
    if not server:accept(client) then
      client:close()
      return
    end

    local input = ''
    client:read_start(function(read_error, chunk)
      if read_error then
        client:read_stop()
        client:close()
        return
      end
      if not chunk then
        client:close()
        return
      end
      input = input .. chunk
      if #input > 16384 then
        client:read_stop()
        client:write('HTTP/1.1 413 Payload Too Large\r\nConnection: close\r\n\r\n', function()
          client:close()
        end)
        return
      end
      if not input:find('\r\n\r\n', 1, true) and not input:find('\n\n', 1, true) then
        return
      end

      client:read_stop()
      local target = input:match('^GET%s+([^%s]+)%s+HTTP/')
      local code, callback_error
      if target then
        code, callback_error = parse_redirect(target, flow.state)
      else
        callback_error = 'authorization callback is invalid'
      end
      local status = code and '200 OK' or '400 Bad Request'
      local body = code and 'Login complete. You can return to Neovim.' or 'Login failed. Return to Neovim.'
      local response = table.concat({
        'HTTP/1.1 ' .. status,
        'Content-Type: text/plain; charset=utf-8',
        'Content-Length: ' .. #body,
        'Connection: close',
        '',
        body,
      }, '\r\n')
      client:write(response, function()
        client:close()
      end)

      vim.schedule(function()
        if code then
          self:_finish_flow(flow, code)
        elseif self.flow == flow then
          self:_clear_flow()
          notify(callback_error, vim.log.levels.ERROR)
        end
      end)
    end)
  end)
  if not listened then
    server:close()
    flow.server = nil
    return nil, 'could not listen for login callback: ' .. tostring(listen_error)
  end
  return true
end

function Auth:login(manual)
  self:_clear_flow()

  local flow, flow_error = pkce(self.deps)
  if not flow then
    notify(flow_error, vim.log.levels.ERROR)
    return
  end
  self.flow = flow

  local timeout = self.config.auth_timeout or 300
  flow.timer = vim.uv.new_timer()
  flow.timer:start(timeout * 1000, 0, vim.schedule_wrap(function()
    if self.flow == flow then
      self:_clear_flow()
      notify('login timed out', vim.log.levels.ERROR)
    end
  end))

  if not manual then
    local listening, listener_error = self:_start_listener(flow)
    if not listening then
      self:_clear_flow()
      notify(listener_error, vim.log.levels.ERROR)
      return
    end
  end

  local url = authorization_url(flow, self.deps)
  self:_open(url)

  if manual then
    if self.deps.input then
      self.deps.input({ prompt = 'Paste authorization code or redirect URL: ', secret = true }, function(value)
        self:_finish_flow(flow, value)
      end)
    else
      local value = vim.fn.inputsecret('Paste authorization code or redirect URL: ')
      self:_finish_flow(flow, value)
    end
  else
    notify('waiting for browser login...')
  end
end

Auth._pkce = pkce
Auth._parse_redirect = parse_redirect
Auth._decode_account_id = decode_account_id
Auth._authorization_url = authorization_url
Auth.PROVIDER = PROVIDER

return Auth
