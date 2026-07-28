local tests = {}
local failures = 0

local function test(name, fn)
  tests[#tests + 1] = { name = name, fn = fn }
end

local function eq(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error((message or 'values differ') .. '\nactual: ' .. vim.inspect(actual) .. '\nexpected: ' .. vim.inspect(expected), 2)
  end
end

local function ok(value, message)
  if not value then
    error(message or 'expected a truthy value', 2)
  end
  return value
end

local function tempdir()
  local path = vim.fn.tempname()
  assert(vim.fn.mkdir(path, 'p') == 1)
  return path
end

local function write(path, contents, mode)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  local fd = assert(vim.uv.fs_open(path, 'w', mode or 384))
  assert(vim.uv.fs_write(fd, contents, 0))
  vim.uv.fs_close(fd)
  assert(vim.uv.fs_chmod(path, mode or 384))
end

local function jwt(account)
  local util = require('ai_complete.util')
  return table.concat({
    util.base64url_encode('{}'),
    util.base64url_encode(util.json_encode({
      ['https://api.openai.com/auth'] = { chatgpt_account_id = account },
    })),
    util.base64url_encode('signature'),
  }, '.')
end

local function credentials(overrides)
  return vim.tbl_extend('force', {
    access_token = jwt('account-1'),
    refresh_token = 'refresh-1',
    account_id = 'account-1',
    expires_at = 200000,
  }, overrides or {})
end

local function sse(items, terminal)
  local util = require('ai_complete.util')
  local output = {}
  for _, item in ipairs(items) do
    output[#output + 1] = 'data: ' .. util.json_encode({ type = 'response.output_item.done', item = item }) .. '\n\n'
  end
  output[#output + 1] = 'data: '
    .. util.json_encode({ type = terminal or 'response.completed', response = { status = 'completed' } })
  return table.concat(output)
end

test('base64url, URL forms, and PKCE are deterministic under injected randomness', function()
  local util = require('ai_complete.util')
  local Auth = require('ai_complete.auth.openai_codex')
  eq(util.base64url_decode(util.base64url_encode('\0abc\255')), '\0abc\255')
  eq(util.parse_query('a=x%20y&b=%2F'), { a = 'x y', b = '/' })
  eq(util.form_encode({ b = '/', a = 'x y' }), 'a=x%20y&b=%2F')

  local calls = 0
  local flow = ok(Auth._pkce({
    random = function(length)
      calls = calls + 1
      return string.rep(calls == 1 and 'a' or 'b', length)
    end,
  }))
  eq(#flow.verifier, 43)
  eq(#flow.challenge, 43)
  eq(#flow.state, 43)
  eq(Auth._parse_redirect('/auth/callback?code=the-code&state=' .. flow.state, flow.state), 'the-code')
  local value, err = Auth._parse_redirect('/auth/callback?code=the-code&state=wrong', flow.state)
  eq(value, nil)
  ok(err:find('state', 1, true))
end)

test('credential store creates secure files, reloads, replaces atomically, and logs out', function()
  local Store = require('ai_complete.auth.store')
  local root = tempdir()
  local path = root .. '/data/ai-complete/auth.json'
  local store = Store.new(path, { random = function(n) return string.rep('r', n) end })
  local first = credentials()
  ok(store:save('openai-codex', first))
  eq(require('bit').band(assert(vim.uv.fs_stat(vim.fs.dirname(path))).mode, 511), 448)
  eq(require('bit').band(assert(vim.uv.fs_stat(path)).mode, 511), 384)
  eq(ok(store:load('openai-codex')).refresh_token, 'refresh-1')

  local second = credentials({ refresh_token = 'rotated' })
  ok(store:save('openai-codex', second))
  eq(ok(store:load('openai-codex')).refresh_token, 'rotated')
  eq(#vim.fn.glob(path .. '.tmp.*', false, true), 0)
  ok(store:remove('openai-codex'))
  eq(vim.uv.fs_stat(path), nil)
  vim.fn.delete(root, 'rf')
end)

test('credential store fails closed on malformed or insecure data', function()
  local Store = require('ai_complete.auth.store')
  local root = tempdir()
  local directory = root .. '/ai-complete'
  vim.fn.mkdir(directory, 'p', 448)
  vim.uv.fs_chmod(directory, 448)
  local path = directory .. '/auth.json'
  write(path, '{}', 384)
  local store = Store.new(path)
  local value, err = store:load('openai-codex')
  eq(value, nil)
  ok(err:find('malformed', 1, true))

  write(path, '{"version":1,"providers":{}}', 420)
  value, err = store:load('openai-codex')
  eq(value, nil)
  ok(err:find('permissions', 1, true))
  vim.fn.delete(root, 'rf')
end)

test('manual OAuth exchanges a code, extracts the account, and stores credentials', function()
  local Auth = require('ai_complete.auth.openai_codex')
  local saved
  local opened
  local store = {
    save = function(_, provider, value)
      eq(provider, 'openai-codex')
      saved = value
      return true
    end,
    load = function() return nil end,
    remove = function() return true end,
  }
  local auth = Auth.new({ auth_timeout = 1 }, {
    store = store,
    random = function(n) return string.rep('q', n) end,
    now_ms = function() return 1000 end,
    open_url = function(url) opened = url return true end,
    input = function(_, callback) callback('manual-code') end,
    http_request = function(opts)
      ok(opts.body:find('code=manual-code', 1, true))
      ok(not vim.inspect(opts):find('account-1', 1, true))
      return {
        status = 200,
        body = vim.json.encode({
          access_token = jwt('account-1'),
          refresh_token = 'refresh-1',
          expires_in = 60,
        }),
      }
    end,
  })
  auth:login(true)
  ok(opened:find('code_challenge=', 1, true))
  eq(saved.account_id, 'account-1')
  eq(saved.expires_at, 61000)
end)

test('loopback OAuth validates state and completes through localhost callback', function()
  local Auth = require('ai_complete.auth.openai_codex')
  local saved
  local opened
  local auth = Auth.new({ auth_timeout = 2 }, {
    store = {
      save = function(_, _, value) saved = value return true end,
      load = function() return nil end,
      remove = function() return true end,
    },
    random = function(n) return string.rep('w', n) end,
    open_url = function(url) opened = url return true end,
    http_request = function()
      return {
        status = 200,
        body = vim.json.encode({
          access_token = jwt('loopback-account'),
          refresh_token = 'loopback-refresh',
          expires_in = 60,
        }),
      }
    end,
  })
  auth:login(false)
  local state = ok(opened:match('[?&]state=([^&]+)'))
  local client = vim.uv.new_tcp()
  local connection_error
  client:connect('127.0.0.1', 1455, function(err)
    connection_error = err
    if err then return end
    client:write('GET /auth/callback?code=loopback-code&state=' .. state .. ' HTTP/1.1\r\nHost: localhost\r\n\r\n')
    client:read_start(function(_, chunk)
      if chunk and chunk:find('Login complete', 1, true) then
        client:read_stop()
        client:close()
      end
    end)
  end)
  ok(vim.wait(1500, function() return saved ~= nil or connection_error ~= nil end, 10))
  eq(connection_error, nil)
  eq(saved.account_id, 'loopback-account')
  if not client:is_closing() then client:close() end
end)

test('proactive refresh stores a rotated token and refresh failure removes credentials', function()
  local Auth = require('ai_complete.auth.openai_codex')
  local current = credentials({ expires_at = 1050 })
  local removed = 0
  local store = {
    load = function() return current end,
    save = function(_, _, value) current = value return true end,
    remove = function() removed = removed + 1 current = nil return true end,
  }
  local responses = 0
  local auth = Auth.new({ refresh_window = 60 }, {
    store = store,
    now_ms = function() return 1000 end,
    http_request = function()
      responses = responses + 1
      return {
        status = 200,
        body = vim.json.encode({
          access_token = jwt('account-2'),
          refresh_token = 'refresh-2',
          expires_in = 100,
        }),
      }
    end,
  })
  eq(ok(auth:get_valid()).refresh_token, 'refresh-2')
  eq(current.account_id, 'account-2')
  eq(responses, 1)

  auth.deps.http_request = function() return { status = 400, body = '{}' } end
  local value, err = auth:refresh(current)
  eq(value, nil)
  ok(err:find(':AiLogin', 1, true))
  eq(removed, 1)
end)

test('curl transport keeps secrets out of argv, uses stdin, and removes temporary files', function()
  local curl = require('ai_complete.transport.curl')
  local seen_paths = {}
  local response = ok(curl.request({
    url = 'https://example.test/response',
    headers = { Authorization = 'Bearer top-secret', ['Content-Type'] = 'application/json' },
    body = '{"secret":"body-only"}',
    max_retries = 0,
  }, {
    execute = function(argv, input)
      local joined = table.concat(argv, '\n')
      ok(not joined:find('top-secret', 1, true))
      ok(not joined:find('body-only', 1, true))
      eq(input, '{"secret":"body-only"}')
      local request_header
      for index, arg in ipairs(argv) do
        if arg == '--header' then request_header = argv[index + 1]:sub(2) end
        if arg == '--dump-header' then seen_paths[#seen_paths + 1] = argv[index + 1] end
        if arg == '--output' then seen_paths[#seen_paths + 1] = argv[index + 1] end
      end
      seen_paths[#seen_paths + 1] = request_header
      local header_contents = table.concat(vim.fn.readfile(request_header), '\n')
      ok(header_contents:find('top-secret', 1, true))
      write(seen_paths[1], 'HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n')
      write(seen_paths[2], 'body')
      return { code = 0, stdout = '200', stderr = '' }
    end,
  }))
  eq(response.status, 200)
  eq(response.body, 'body')
  eq(response.headers['content-type'], 'text/event-stream')
  for _, path in ipairs(seen_paths) do
    eq(vim.uv.fs_stat(path), nil)
  end
end)

test('curl transport retries transient status with Retry-After', function()
  local curl = require('ai_complete.transport.curl')
  local attempts = 0
  local sleeps = {}
  local response = ok(curl.request({
    url = 'https://example.test/response',
    headers = {},
    max_retries = 2,
  }, {
    sleep = function(ms) sleeps[#sleeps + 1] = ms end,
    execute = function(argv)
      attempts = attempts + 1
      local header_path, body_path
      for index, arg in ipairs(argv) do
        if arg == '--dump-header' then header_path = argv[index + 1] end
        if arg == '--output' then body_path = argv[index + 1] end
      end
      local status = attempts == 1 and 429 or 200
      write(header_path, 'HTTP/1.1 ' .. status .. ' X\r\nRetry-After: 0\r\n\r\n')
      write(body_path, attempts == 1 and 'retry' or 'ok')
      return { code = 0, stdout = tostring(status), stderr = '' }
    end,
  }))
  eq(response.status, 200)
  eq(attempts, 2)
  eq(sleeps, { 0 })
end)

test('SSE supports CRLF, comments, multiline data, final buffers, and terminal validation', function()
  local Provider = require('ai_complete.providers.openai_codex')
  local body = table.concat({
    ': keepalive\r\n',
    'data: {"type":"response.output_item.done",\r\n',
    'data: "item":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"done"}]}}\r\n\r\n',
    'event: response.completed\r\n',
    'data: {"type":"response.completed","response":{"status":"completed"}}',
  })
  local parsed = ok(Provider._parse_events(ok(Provider._sse_events(body))))
  eq(parsed.text, 'done')

  local events, err = Provider._sse_events('data: [DONE]\n\n')
  eq(events, nil)
  ok(err:find('terminal', 1, true))
  events, err = Provider._sse_events('data: not-json\n\ndata: {"type":"response.completed"}\n\n')
  eq(events, nil)
  ok(err:find('malformed', 1, true))
end)

test('provider preserves reasoning, messages, calls, and empty final output', function()
  local Provider = require('ai_complete.providers.openai_codex')
  local reasoning = { id = 'r1', type = 'reasoning', encrypted_content = 'opaque', summary = {} }
  local call = { id = 'i1', type = 'function_call', call_id = 'c1', name = 'read', arguments = '{"path":"x"}' }
  local message = { id = 'm1', type = 'message', role = 'assistant', content = { { type = 'output_text', text = '' } } }
  local parsed = ok(Provider._parse_events(ok(Provider._sse_events(sse({ reasoning, call, message })))))
  eq(parsed.items[1].encrypted_content, 'opaque')
  eq(parsed.calls[1].call_id, 'c1')
  eq(parsed.has_message, true)
  eq(parsed.text, '')
end)

test('read, ls, find, and grep fallback are bounded, deterministic, and read-only', function()
  local tools = require('ai_complete.tools')
  local root = tempdir()
  write(root .. '/a.lua', 'first\nNeedle\nthird\n')
  write(root .. '/b.txt', 'needle lower\n')
  write(root .. '/.hidden', 'secret\n')
  write(root .. '/binary', 'x\0y')
  vim.fn.mkdir(root .. '/sub', 'p')
  write(root .. '/sub/c.lua', 'Needle too\n')
  local request = { cwd = root }
  local deps = { force_fallback = true }

  local listing = tools.execute(request, { name = 'ls', arguments = '{}' }, deps)
  ok(listing:find('.hidden', 1, true))
  ok(listing:find('sub/', 1, true))

  local found = tools.execute(request, { name = 'find', arguments = '{"pattern":"**/*.lua"}' }, deps)
  ok(found:find('a.lua', 1, true))
  ok(found:find('sub/c.lua', 1, true))
  ok(found:find('a.lua', 1, true) < found:find('sub/c.lua', 1, true))

  local read = tools.execute(request, { name = 'read', arguments = '{"path":"a.lua","offset":2,"limit":1}' }, deps)
  ok(read:find('2: Needle', 1, true))
  ok(read:find('offset=3', 1, true))

  local grep = tools.execute(request, {
    name = 'grep',
    arguments = '{"pattern":"needle","ignoreCase":true,"context":1,"limit":10}',
  }, deps)
  ok(grep:find('a.lua:2:', 1, true))
  ok(grep:find('b.txt:1:', 1, true))
  ok(not grep:find('binary', 1, true))

  local unknown = tools.execute(request, { name = 'shell', arguments = '{}' }, deps)
  ok(unknown:find('unknown tool', 1, true))
  local invalid = tools.execute(request, { name = 'read', arguments = '{"path":1}' }, deps)
  ok(invalid:find('tool error', 1, true))
  vim.fn.delete(root, 'rf')
end)

test('read observes unsaved loaded-buffer content', function()
  local tools = require('ai_complete.tools')
  local root = tempdir()
  local path = root .. '/loaded.txt'
  write(path, 'disk\n')
  local buffer = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buffer, path)
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { 'unsaved' })
  local output = tools.execute({ cwd = root }, { name = 'read', arguments = '{"path":"loaded.txt"}' }, { force_fallback = true })
  ok(output:find('unsaved', 1, true))
  ok(not output:find('disk', 1, true))
  vim.api.nvim_buf_delete(buffer, { force = true })
  vim.fn.delete(root, 'rf')
end)

test('find and grep use rg through fixed argv when available', function()
  local tools = require('ai_complete.tools')
  local root = tempdir()
  write(root .. '/a.lua', 'hit\n')
  local commands = {}
  local deps = {
    rg_available = true,
    run = function(argv)
      commands[#commands + 1] = argv
      if argv[2] == '--files' then
        return { code = 0, stdout = './z.lua\n./a.lua\n', stderr = '' }
      end
      return {
        code = 0,
        stdout = vim.json.encode({
          type = 'match',
          data = { path = { text = 'a.lua' }, lines = { text = 'hit\n' }, line_number = 3 },
        }) .. '\n',
        stderr = '',
      }
    end,
  }
  local request = { cwd = root }
  local found = tools.execute(request, { name = 'find', arguments = '{"pattern":"*.lua"}' }, deps)
  ok(found:find('a.lua', 1, true) < found:find('z.lua', 1, true))
  local grep = tools.execute(request, { name = 'grep', arguments = '{"pattern":"hit","literal":true}' }, deps)
  ok(grep:find('a.lua:3:', 1, true))
  eq(commands[1][1], 'rg')
  eq(commands[2][1], 'rg')
  ok(vim.tbl_contains(commands[2], '--fixed-strings'))
  vim.fn.delete(root, 'rf')
end)

test('agent replays complete items, executes every call in order, and ignores pre-tool text', function()
  local agent = require('ai_complete.agent')
  local reasoning = { id = 'r', type = 'reasoning', encrypted_content = 'opaque' }
  local early = { id = 'm', type = 'message', role = 'assistant', content = { { type = 'output_text', text = 'not final' } } }
  local first_call = { id = 'f1', type = 'function_call', call_id = 'c1', name = 'read', arguments = '{}' }
  local second_call = { id = 'f2', type = 'function_call', call_id = 'c2', name = 'ls', arguments = '{}' }
  local seen_transcript
  local provider = {
    initial_input = function() return { { type = 'message', role = 'user', content = {} } } end,
    infer = function(_, _, transcript)
      if not seen_transcript then
        seen_transcript = transcript
        return { items = { reasoning, early, first_call, second_call }, calls = {
          { call_id = 'c1', name = 'read', arguments = '{}' },
          { call_id = 'c2', name = 'ls', arguments = '{}' },
        }, has_message = true, text = 'not final' }
      end
      eq(transcript[2], reasoning)
      eq(transcript[3], early)
      eq(transcript[4], first_call)
      eq(transcript[5], second_call)
      eq(transcript[6], { type = 'function_call_output', call_id = 'c1', output = 'result-read' })
      eq(transcript[7], { type = 'function_call_output', call_id = 'c2', output = 'result-ls' })
      return { items = {}, calls = {}, has_message = true, text = 'final' }
    end,
  }
  local order = {}
  local output = ok(agent.run({ current_round = 0 }, { provider = 'openai-codex', max_tool_rounds = 2 }, {
    auth = { get_valid = function() return credentials() end },
    provider = provider,
    execute_tool = function(_, call) order[#order + 1] = call.name return 'result-' .. call.name end,
  }))
  eq(output, 'final')
  eq(order, { 'read', 'ls' })
end)

test('agent forces one refresh after 401 and fails without applying at the loop bound', function()
  local agent = require('ai_complete.agent')
  local refreshes = 0
  local calls = 0
  local auth = {
    get_valid = function() return credentials() end,
    refresh = function() refreshes = refreshes + 1 return credentials({ access_token = jwt('account-2') }) end,
  }
  local provider = {
    initial_input = function() return {} end,
    infer = function()
      calls = calls + 1
      if calls == 1 then return nil, { status = 401, message = 'expired' } end
      return { items = {}, calls = {}, has_message = true, text = 'ok' }
    end,
  }
  eq(agent.run({ current_round = 0 }, { provider = 'openai-codex', max_tool_rounds = 1 }, {
    auth = auth,
    provider = provider,
  }), 'ok')
  eq(refreshes, 1)
  eq(calls, 2)

  local looping = {
    initial_input = function() return {} end,
    infer = function()
      return {
        items = {},
        calls = { { call_id = 'x', name = 'read', arguments = '{}' } },
        has_message = false,
        text = '',
      }
    end,
  }
  local value, err = agent.run({ current_round = 0 }, { provider = 'openai-codex', max_tool_rounds = 0 }, {
    auth = auth,
    provider = looping,
    execute_tool = function() error('must not execute beyond bound') end,
  })
  eq(value, nil)
  ok(err:find('maximum', 1, true))
end)

local function select(keys)
  vim.cmd('normal! ' .. keys .. 'y')
  local first = vim.fn.getpos("'<")
  local last = vim.fn.getpos("'>")
  return { range = 2, line1 = math.min(first[2], last[2]), line2 = math.max(first[2], last[2]) }
end

local function integration(lines, keys, replacement, expected)
  local complete = require('ai_complete')
  vim.cmd('enew!')
  local undo_levels = vim.bo.undolevels
  vim.bo.undolevels = -1
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  vim.bo.undolevels = undo_levels
  vim.fn.setreg('z', 'sentinel\n', 'V')
  complete._set_dependencies({
    run_agent = function(request)
      ok(request.selection_text ~= nil)
      return replacement
    end,
  })
  local opts = select(keys)
  complete.complete('change it', opts)
  eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), expected)
  eq(vim.fn.getreg('z'), 'sentinel\n')
  eq(vim.fn.getregtype('z'), 'V')
  vim.cmd('silent undo')
  eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), lines)
end

test('Visual integration preserves characterwise, linewise, blockwise, deletion, register, and undo behavior', function()
  integration({ 'alpha beta' }, 'gg0v4l', 'X', { 'X beta' })
  integration({ 'one', 'two', 'three' }, 'ggVj', 'X\nY\n', { 'X', 'Y', 'three' })
  integration({ 'abc', 'def' }, 'gg0\022jl', 'X\nY', { 'X c', 'Y f' })
  integration({ 'alpha beta' }, 'gg0v4l', '', { ' beta' })
end)

test('Visual integration restores the register and leaves the buffer unchanged on failure', function()
  local complete = require('ai_complete')
  vim.cmd('enew!')
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'unchanged' })
  vim.fn.setreg('z', 'keep', 'v')
  complete._set_dependencies({ run_agent = function() return nil, 'failed request' end })
  local opts = select('gg0v3l')
  complete.complete('fail', opts)
  eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { 'unchanged' })
  eq(vim.fn.getreg('z'), 'keep')
  eq(vim.fn.getregtype('z'), 'v')
end)

for _, item in ipairs(tests) do
  local success, err = xpcall(item.fn, debug.traceback)
  if success then
    io.stdout:write('ok - ' .. item.name .. '\n')
  else
    failures = failures + 1
    io.stderr:write('not ok - ' .. item.name .. '\n' .. err .. '\n')
  end
end

io.stdout:write(string.format('%d tests, %d failures\n', #tests, failures))
if failures > 0 then
  vim.cmd('cquit ' .. failures)
end
