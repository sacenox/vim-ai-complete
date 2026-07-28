local util = require('ai_complete.util')

local M = {}

M.limits = {
  output_bytes = 50 * 1024,
  line_bytes = 4000,
  read_lines = 1000,
  read_source_bytes = 4 * 1024 * 1024,
  entries = 1000,
  traversal = 20000,
  grep_files = 2000,
  grep_source_bytes = 16 * 1024 * 1024,
}

function M.decode_arguments(value)
  if type(value) ~= 'string' then
    return nil, 'arguments must be a JSON object'
  end
  local ok, decoded = pcall(util.json_decode, value)
  if not ok or type(decoded) ~= 'table' or vim.islist(decoded) then
    return nil, 'arguments must be a JSON object'
  end
  return decoded
end

function M.resolve(request, path)
  return util.resolve_path(path, request.cwd)
end

function M.display(request, path)
  return util.display_path(path, request.cwd)
end

function M.loaded_buffer_lines(path)
  local normalized = vim.fs.normalize(path)
  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buffer) then
      local name = vim.api.nvim_buf_get_name(buffer)
      if name ~= '' and vim.fs.normalize(name) == normalized then
        return vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
      end
    end
  end
end

function M.read_disk(path, maximum)
  local stat = vim.uv.fs_stat(path)
  if not stat then
    return nil, 'path does not exist'
  end
  if stat.type ~= 'file' then
    return nil, 'path is not a regular file'
  end
  if stat.size > maximum then
    return nil, 'file exceeds the scan byte limit'
  end

  local fd = vim.uv.fs_open(path, 'r', 384)
  if not fd then
    return nil, 'file is unreadable'
  end
  local value = vim.uv.fs_read(fd, stat.size, 0)
  vim.uv.fs_close(fd)
  if type(value) ~= 'string' then
    return nil, 'file is unreadable'
  end
  return value
end

function M.split_lines(value)
  local lines = vim.split(value, '\n', { plain = true })
  if value:sub(-1) == '\n' then
    table.remove(lines)
  end
  return lines
end

function M.is_binary(value)
  return value:find('\0', 1, true) ~= nil
end

function M.truncate_line(value)
  if #value <= M.limits.line_bytes then
    return value
  end
  return value:sub(1, M.limits.line_bytes) .. '...[line truncated]'
end

function M.glob_pattern(glob)
  if type(glob) ~= 'string' or glob == '' then
    return nil, 'glob must be a non-empty string'
  end

  local out = { '^' }
  local i = 1
  while i <= #glob do
    local char = glob:sub(i, i)
    local pair = glob:sub(i, i + 1)
    if pair == '**' then
      if glob:sub(i + 2, i + 2) == '/' then
        out[#out + 1] = '(.-)'
        i = i + 3
      else
        out[#out + 1] = '.*'
        i = i + 2
      end
    elseif char == '*' then
      out[#out + 1] = '[^/]*'
      i = i + 1
    elseif char == '?' then
      out[#out + 1] = '[^/]'
      i = i + 1
    else
      local magic = char:find('[%^%$%(%)%%%.%[%]%+%-]') ~= nil
      out[#out + 1] = magic and ('%' .. char) or char
      i = i + 1
    end
  end
  out[#out + 1] = '$'
  return table.concat(out)
end

function M.walk(root, opts)
  opts = opts or {}
  local files = {}
  local visited = 0
  local file_count = 0
  local result_bytes = 0
  local stopped = nil

  local function visit(directory, relative)
    if stopped then
      return
    end
    local handle = vim.uv.fs_scandir(directory)
    if not handle then
      return
    end

    local entries = {}
    while true do
      local name, kind = vim.uv.fs_scandir_next(handle)
      if not name then
        break
      end
      entries[#entries + 1] = { name = name, kind = kind }
    end
    table.sort(entries, function(a, b)
      return a.name < b.name
    end)

    for _, entry in ipairs(entries) do
      if stopped then
        break
      end
      local rel = relative == '' and entry.name or (relative .. '/' .. entry.name)
      if rel ~= '.git' and not rel:match('^%.git/') then
        visited = visited + 1
        if visited > (opts.traversal_limit or M.limits.traversal) then
          stopped = 'traversal limit'
          break
        end

        local full = root .. '/' .. rel
        local kind = entry.kind
        if not kind then
          local stat = vim.uv.fs_lstat(full)
          kind = stat and stat.type
        end
        if kind == 'directory' then
          visit(full, rel)
        elseif kind == 'file' then
          file_count = file_count + 1
          if not opts.accept or opts.accept(rel) then
            files[#files + 1] = { path = full, relative = rel }
            result_bytes = result_bytes + #rel + 1
            if opts.result_limit and #files >= opts.result_limit then
              stopped = 'result limit'
              break
            end
            if opts.byte_limit and result_bytes >= opts.byte_limit then
              stopped = 'result byte limit'
              break
            end
          end
          if opts.file_limit and file_count >= opts.file_limit then
            stopped = 'file limit'
            break
          end
        end
      end
    end
  end

  local stat = vim.uv.fs_stat(root)
  if not stat then
    return nil, 'path does not exist'
  end
  if stat.type == 'file' then
    return { { path = root, relative = vim.fs.basename(root) } }, nil, 1
  end
  if stat.type ~= 'directory' then
    return nil, 'path is not a file or directory'
  end

  visit(root:gsub('/$', ''), '')
  return files, stopped, visited
end

function M.rg_available(deps)
  if deps and deps.force_fallback then
    return false
  end
  if deps and deps.rg_available ~= nil then
    return deps.rg_available
  end
  return vim.fn.executable('rg') == 1
end

function M.run(argv, cwd, deps)
  if deps and deps.run then
    return deps.run(argv, cwd)
  end
  if type(vim.system) == 'function' then
    local ok, result = pcall(function()
      return vim.system(argv, { cwd = cwd, text = true, timeout = 30000 }):wait()
    end)
    if not ok then
      return nil, 'search command failed'
    end
    return {
      code = result.code,
      stdout = result.stdout or '',
      stderr = result.stderr or '',
    }
  end
  return nil, 'optimized search requires Neovim 0.10 or newer'
end

function M.bounded_lines(lines, maximum)
  local out = {}
  local bytes = 0
  local truncated = false
  for _, line in ipairs(lines) do
    local addition = #line + 1
    if bytes + addition > maximum then
      truncated = true
      break
    end
    out[#out + 1] = line
    bytes = bytes + addition
  end
  return out, truncated
end

return M
