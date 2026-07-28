local M = {}

local B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

function M.json_encode(value)
  return vim.json.encode(value)
end

function M.json_decode(value)
  return vim.json.decode(value, { luanil = { object = true, array = true } })
end

function M.base64_encode(value)
  local out = {}

  for i = 1, #value, 3 do
    local a = value:byte(i) or 0
    local b = value:byte(i + 1) or 0
    local c = value:byte(i + 2) or 0
    local n = a * 65536 + b * 256 + c

    out[#out + 1] = B64:sub(math.floor(n / 262144) % 64 + 1, math.floor(n / 262144) % 64 + 1)
    out[#out + 1] = B64:sub(math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1)
    out[#out + 1] = i + 1 <= #value and B64:sub(math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1) or '='
    out[#out + 1] = i + 2 <= #value and B64:sub(n % 64 + 1, n % 64 + 1) or '='
  end

  return table.concat(out)
end

function M.base64_decode(value)
  value = value:gsub('%s', '')
  if #value % 4 ~= 0 then
    return nil, 'invalid base64 length'
  end

  local reverse = {}
  for i = 1, #B64 do
    reverse[B64:sub(i, i)] = i - 1
  end

  local out = {}
  for i = 1, #value, 4 do
    local chars = { value:sub(i, i), value:sub(i + 1, i + 1), value:sub(i + 2, i + 2), value:sub(i + 3, i + 3) }
    local nums = {}
    for j, char in ipairs(chars) do
      if char == '=' then
        nums[j] = 0
      elseif reverse[char] ~= nil then
        nums[j] = reverse[char]
      else
        return nil, 'invalid base64 character'
      end
    end

    local n = nums[1] * 262144 + nums[2] * 4096 + nums[3] * 64 + nums[4]
    out[#out + 1] = string.char(math.floor(n / 65536) % 256)
    if chars[3] ~= '=' then
      out[#out + 1] = string.char(math.floor(n / 256) % 256)
    end
    if chars[4] ~= '=' then
      out[#out + 1] = string.char(n % 256)
    end
  end

  return table.concat(out)
end

function M.base64url_encode(value)
  return (M.base64_encode(value):gsub('+', '-'):gsub('/', '_'):gsub('=', ''))
end

function M.base64url_decode(value)
  local normalized = value:gsub('-', '+'):gsub('_', '/')
  normalized = normalized .. string.rep('=', (4 - #normalized % 4) % 4)
  return M.base64_decode(normalized)
end

function M.hex_to_bytes(value)
  if #value % 2 ~= 0 or value:find('[^0-9a-fA-F]') then
    return nil
  end

  return (value:gsub('..', function(pair)
    return string.char(tonumber(pair, 16))
  end))
end

function M.random_bytes(length, deps)
  local random = deps and deps.random or vim.uv.random
  local ok, value = pcall(random, length)
  if not ok or type(value) ~= 'string' or #value ~= length then
    return nil, 'secure random generation failed'
  end
  return value
end

function M.random_id(deps)
  local bytes, err = M.random_bytes(16, deps)
  if not bytes then
    return nil, err
  end
  return M.base64url_encode(bytes)
end

function M.url_encode(value)
  return (tostring(value):gsub('[^%w%-._~]', function(char)
    return string.format('%%%02X', char:byte())
  end))
end

function M.url_decode(value)
  value = value:gsub('+', ' ')
  if value:find('%%[^%x]') or value:find('%%$') then
    return nil, 'invalid URL encoding'
  end
  return (value:gsub('%%(%x%x)', function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

function M.parse_query(value)
  local result = {}
  if value == '' or value == nil then
    return result
  end

  for field in value:gmatch('[^&]+') do
    local key, item = field:match('^([^=]*)=(.*)$')
    if not key then
      key, item = field, ''
    end
    key = M.url_decode(key)
    item = M.url_decode(item)
    if not key or not item then
      return nil, 'invalid callback URL'
    end
    result[key] = item
  end
  return result
end

function M.form_encode(fields)
  local keys = vim.tbl_keys(fields)
  table.sort(keys)
  local out = {}
  for _, key in ipairs(keys) do
    out[#out + 1] = M.url_encode(key) .. '=' .. M.url_encode(fields[key])
  end
  return table.concat(out, '&')
end

function M.resolve_path(path, cwd)
  if path:sub(1, 1) ~= '/' then
    path = cwd .. '/' .. path
  end
  return vim.fs.normalize(path)
end

function M.display_path(path, cwd)
  local normalized = vim.fs.normalize(path)
  local root = vim.fs.normalize(cwd):gsub('/$', '')
  if normalized == root then
    return '.'
  end
  if normalized:sub(1, #root + 1) == root .. '/' then
    return normalized:sub(#root + 2)
  end
  return normalized
end

function M.is_integer(value, minimum)
  return type(value) == 'number' and value == math.floor(value) and (minimum == nil or value >= minimum)
end

function M.now_ms(deps)
  if deps and deps.now_ms then
    return deps.now_ms()
  end
  return os.time() * 1000
end

function M.sleep(ms, deps)
  if deps and deps.sleep then
    return deps.sleep(ms)
  end
  vim.wait(math.max(0, math.floor(ms)))
end

return M
