local bit = require('bit')
local util = require('ai_complete.util')

local Store = {}
Store.__index = Store

local VERSION = 1
local PROVIDER = 'openai-codex'

local function permissions(stat)
  return bit.band(stat.mode or 0, 511)
end

local function owned_by_user(stat)
  return type(vim.uv.getuid) ~= 'function' or stat.uid == vim.uv.getuid()
end

local function validate_directory(path)
  local stat = vim.uv.fs_lstat(path)
  if not stat then
    return nil, 'credential directory is unavailable'
  end
  if stat.type ~= 'directory' or not owned_by_user(stat) or permissions(stat) ~= 448 then
    return nil, 'credential directory has insecure permissions'
  end
  return true
end

local function ensure_directory(path)
  local stat = vim.uv.fs_lstat(path)
  if stat then
    return validate_directory(path)
  end

  local ok = vim.fn.mkdir(path, 'p', 448)
  if ok ~= 1 and not vim.uv.fs_stat(path) then
    return nil, 'could not create credential directory'
  end
  local chmod_ok = vim.uv.fs_chmod(path, 448)
  if not chmod_ok then
    return nil, 'could not secure credential directory'
  end
  return validate_directory(path)
end

local function validate_credentials(value)
  if type(value) ~= 'table' then
    return nil
  end
  if type(value.access_token) ~= 'string' or value.access_token == '' then
    return nil
  end
  if type(value.refresh_token) ~= 'string' or value.refresh_token == '' then
    return nil
  end
  if type(value.account_id) ~= 'string' or value.account_id == '' then
    return nil
  end
  if type(value.expires_at) ~= 'number' or value.expires_at <= 0 then
    return nil
  end

  return {
    access_token = value.access_token,
    refresh_token = value.refresh_token,
    account_id = value.account_id,
    expires_at = value.expires_at,
  }
end

local function decode_store(contents)
  local ok, decoded = pcall(util.json_decode, contents)
  if not ok or type(decoded) ~= 'table' or decoded.version ~= VERSION or type(decoded.providers) ~= 'table' then
    return nil, 'credential store is malformed'
  end

  local providers = {}
  for name, value in pairs(decoded.providers) do
    if name ~= PROVIDER then
      return nil, 'credential store contains an unsupported provider'
    end
    local credentials = validate_credentials(value)
    if not credentials then
      return nil, 'credential store is malformed'
    end
    providers[name] = credentials
  end
  return providers
end

function Store.new(path, deps)
  return setmetatable({
    path = path or (vim.fn.stdpath('data') .. '/ai-complete/auth.json'),
    deps = deps or {},
  }, Store)
end

function Store:load_all()
  local directory = vim.fs.dirname(self.path)
  local directory_stat = vim.uv.fs_lstat(directory)
  if not directory_stat then
    return {}
  end

  local ok, err = validate_directory(directory)
  if not ok then
    return nil, err
  end

  local stat = vim.uv.fs_lstat(self.path)
  if not stat then
    return {}
  end
  if stat.type ~= 'file' or not owned_by_user(stat) or permissions(stat) ~= 384 then
    return nil, 'credential file has insecure permissions'
  end

  local fd = vim.uv.fs_open(self.path, 'r', 384)
  if not fd then
    return nil, 'could not read credential store'
  end
  local contents = vim.uv.fs_read(fd, stat.size, 0)
  vim.uv.fs_close(fd)
  if type(contents) ~= 'string' then
    return nil, 'could not read credential store'
  end

  return decode_store(contents)
end

function Store:load(provider)
  local providers, err = self:load_all()
  if not providers then
    return nil, err
  end
  return providers[provider]
end

function Store:save(provider, credentials)
  if provider ~= PROVIDER or not validate_credentials(credentials) then
    return nil, 'invalid credentials'
  end

  local providers, load_error = self:load_all()
  if not providers then
    return nil, load_error
  end
  providers[provider] = validate_credentials(credentials)
  return self:_write(providers)
end

function Store:remove(provider)
  if provider ~= PROVIDER then
    return nil, 'unsupported provider'
  end

  local providers, load_error = self:load_all()
  if not providers then
    return nil, load_error
  end
  providers[provider] = nil

  if next(providers) == nil then
    local stat = vim.uv.fs_lstat(self.path)
    if stat and not vim.uv.fs_unlink(self.path) then
      return nil, 'could not remove credentials'
    end
    return true
  end

  return self:_write(providers)
end

function Store:_write(providers)
  local directory = vim.fs.dirname(self.path)
  local ok, directory_error = ensure_directory(directory)
  if not ok then
    return nil, directory_error
  end

  local encoded_ok, contents = pcall(util.json_encode, {
    version = VERSION,
    providers = providers,
  })
  if not encoded_ok then
    return nil, 'could not encode credential store'
  end

  local suffix, random_error = util.random_id(self.deps)
  if not suffix then
    return nil, random_error
  end
  local temporary = self.path .. '.tmp.' .. suffix
  local fd = vim.uv.fs_open(temporary, 'wx', 384)
  if not fd then
    return nil, 'could not create temporary credential file'
  end

  local written = vim.uv.fs_write(fd, contents, 0)
  local write_ok = written == #contents
  local sync_ok = write_ok and vim.uv.fs_fsync(fd)
  vim.uv.fs_close(fd)

  if not write_ok or not sync_ok or not vim.uv.fs_chmod(temporary, 384) then
    vim.uv.fs_unlink(temporary)
    return nil, 'could not write credential store'
  end

  local rename_ok = vim.uv.fs_rename(temporary, self.path)
  if not rename_ok then
    vim.uv.fs_unlink(temporary)
    return nil, 'could not replace credential store'
  end
  vim.uv.fs_chmod(self.path, 384)
  return true
end

return Store
