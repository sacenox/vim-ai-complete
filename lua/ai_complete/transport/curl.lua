local util = require('ai_complete.util')

local M = {}

local function temporary_file()
  local path = vim.fn.tempname()
  local fd = vim.uv.fs_open(path, 'wx', 384)
  if not fd then
    return nil, 'could not create a secure temporary file'
  end
  vim.uv.fs_close(fd)
  vim.uv.fs_chmod(path, 384)
  return path
end

local function read_file(path, maximum)
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.size > maximum then
    return nil, stat and 'HTTP response exceeded the byte limit' or 'could not read HTTP response'
  end
  local fd = vim.uv.fs_open(path, 'r', 384)
  if not fd then
    return nil, 'could not read HTTP response'
  end
  local value = vim.uv.fs_read(fd, stat.size, 0)
  vim.uv.fs_close(fd)
  if type(value) ~= 'string' then
    return nil, 'could not read HTTP response'
  end
  return value
end

local function write_headers(path, headers)
  local keys = vim.tbl_keys(headers)
  table.sort(keys, function(a, b)
    return a:lower() < b:lower()
  end)

  local lines = {}
  for _, name in ipairs(keys) do
    local value = headers[name]
    if type(name) ~= 'string' or type(value) ~= 'string' or name == '' or name:find('[:\r\n]') or value:find('[\r\n]') then
      return nil, 'invalid HTTP header'
    end
    lines[#lines + 1] = name .. ': ' .. value
  end

  local fd = vim.uv.fs_open(path, 'w', 384)
  if not fd then
    return nil, 'could not prepare HTTP headers'
  end
  local ok = vim.uv.fs_write(fd, table.concat(lines, '\n') .. '\n', 0)
  vim.uv.fs_close(fd)
  if not ok or not vim.uv.fs_chmod(path, 384) then
    return nil, 'could not prepare HTTP headers'
  end
  return true
end

local function execute(argv, input, deps)
  if deps and deps.execute then
    return deps.execute(argv, input)
  end

  if type(vim.system) == 'function' then
    local ok, result = pcall(function()
      return vim.system(argv, { stdin = input, text = true }):wait()
    end)
    if not ok then
      return { code = -1, stdout = '', stderr = 'curl could not be started' }
    end
    return {
      code = result.code,
      stdout = result.stdout or '',
      stderr = result.stderr or '',
    }
  end

  local ok, stdout = pcall(vim.fn.system, argv, input)
  if not ok then
    return { code = -1, stdout = '', stderr = 'curl could not be started' }
  end
  return {
    code = vim.v.shell_error,
    stdout = stdout or '',
    stderr = '',
  }
end

local function parse_headers(raw)
  raw = raw:gsub('\r\n', '\n'):gsub('\r', '\n')
  local latest = {}
  local current = nil

  for line in (raw .. '\n'):gmatch('(.-)\n') do
    if line:match('^HTTP/%S+%s+%d%d%d') then
      current = {}
      latest = current
    elseif current and line ~= '' then
      local name, value = line:match('^([^:]+):%s*(.*)$')
      if name then
        name = name:lower()
        if current[name] then
          current[name] = current[name] .. ', ' .. value
        else
          current[name] = value
        end
      end
    end
  end

  return latest
end

local function retry_delay(headers, attempt, opts, deps)
  local maximum = opts.max_retry_after_ms or 10000
  local retry_after = headers['retry-after']
  if retry_after then
    local seconds = tonumber(retry_after)
    if seconds then
      return math.min(math.max(0, seconds * 1000), maximum)
    end

    local parsed = vim.fn.strptime('%a, %d %b %Y %H:%M:%S GMT', retry_after)
    if parsed and parsed >= 0 then
      local local_offset = os.difftime(os.time(os.date('*t')), os.time(os.date('!*t')))
      local target_ms = (parsed + local_offset) * 1000
      return math.min(math.max(0, target_ms - util.now_ms(deps)), maximum)
    end
  end
  local base = opts.retry_delay_ms or 500
  return math.min(base * (2 ^ attempt), maximum)
end

local function curl_error(message, extra)
  local value = extra or {}
  value.kind = value.kind or 'transport'
  value.message = message
  return value
end

function M.request(opts, deps)
  deps = deps or {}
  if type(opts) ~= 'table' or type(opts.url) ~= 'string' or not opts.url:match('^https://') then
    return nil, curl_error('invalid HTTPS request')
  end
  if vim.fn.executable('curl') ~= 1 and not deps.execute then
    return nil, curl_error('curl is required')
  end

  local maximum = opts.max_response_bytes or 10 * 1024 * 1024
  local max_retries = opts.max_retries == nil and 3 or opts.max_retries
  local attempt = 0

  while true do
    local request_headers, request_error = temporary_file()
    local response_headers, response_header_error = temporary_file()
    local response_body, response_body_error = temporary_file()
    local response_stderr, response_stderr_error = temporary_file()
    local paths = { request_headers, response_headers, response_body, response_stderr }

    local function cleanup()
      for _, path in ipairs(paths) do
        if path then
          vim.uv.fs_unlink(path)
        end
      end
    end

    if not request_headers or not response_headers or not response_body or not response_stderr then
      cleanup()
      return nil, curl_error(request_error or response_header_error or response_body_error or response_stderr_error)
    end

    local headers_ok, headers_error = write_headers(request_headers, opts.headers or {})
    if not headers_ok then
      cleanup()
      return nil, curl_error(headers_error)
    end

    local argv = {
      'curl',
      '--silent',
      '--show-error',
      '--stderr',
      response_stderr,
      '--proto',
      '=https',
      '--tlsv1.2',
      '--connect-timeout',
      tostring(opts.connect_timeout or 10),
      '--max-time',
      tostring(opts.timeout or 300),
      '--request',
      opts.method or 'POST',
      '--header',
      '@' .. request_headers,
      '--dump-header',
      response_headers,
      '--output',
      response_body,
      '--write-out',
      '%{http_code}',
    }
    if opts.body ~= nil then
      argv[#argv + 1] = '--data-binary'
      argv[#argv + 1] = '@-'
    end
    argv[#argv + 1] = opts.url

    local process = execute(argv, opts.body, deps)
    local raw_headers, header_error = read_file(response_headers, 512 * 1024)
    local body, body_error = read_file(response_body, maximum)
    local stderr = read_file(response_stderr, 512 * 1024)
    cleanup()

    local status = tonumber((process.stdout or ''):match('(%d%d%d)%s*$'))
    local response = {
      status = status or 0,
      headers = raw_headers and parse_headers(raw_headers) or {},
      body = body or '',
      stderr = stderr or process.stderr or '',
      attempt = attempt + 1,
    }

    local retry = false
    if process.code ~= 0 or not status or not raw_headers or not body then
      retry = attempt < max_retries
      if not retry then
        return nil, curl_error(header_error or body_error or 'HTTP request failed', {
          exit_code = process.code,
          status = status,
        })
      end
    elseif (status == 408 or status == 429 or (status >= 500 and status <= 599)) and attempt < max_retries then
      retry = true
    end

    if not retry then
      return response
    end

    util.sleep(retry_delay(response.headers, attempt, opts, deps), deps)
    attempt = attempt + 1
  end
end

return M
