local common = require('ai_complete.tools.common')
local util = require('ai_complete.util')

local M = {}

local function optimized(root, pattern, deps)
  local result, run_error = common.run({
    'rg',
    '--files',
    '--hidden',
    '--glob',
    '!.git/**',
    '--glob',
    pattern,
    '.',
  }, root, deps)
  if not result then
    return nil, run_error
  end
  if result.code ~= 0 and result.code ~= 1 then
    return nil, 'rg file search failed'
  end

  local paths = {}
  for line in result.stdout:gmatch('[^\r\n]+') do
    line = line:gsub('^%./', '')
    if line ~= '' then
      paths[#paths + 1] = line
    end
  end
  table.sort(paths)
  return paths
end

local function fallback(root, pattern, limit)
  local lua_pattern, pattern_error = common.glob_pattern(pattern)
  if not lua_pattern then
    return nil, pattern_error
  end
  local files, stopped = common.walk(root, {
    traversal_limit = common.limits.traversal,
    result_limit = limit,
    byte_limit = common.limits.output_bytes,
    accept = function(relative)
      return relative:match(lua_pattern) ~= nil
    end,
  })
  if not files then
    return nil, stopped
  end

  local paths = {}
  for _, file in ipairs(files) do
    paths[#paths + 1] = file.relative
  end
  table.sort(paths)
  return paths, stopped
end

function M.run(request, args, deps)
  if type(args.pattern) ~= 'string' or args.pattern == '' then
    return nil, 'pattern must be a non-empty glob string'
  end
  if args.path ~= nil and (type(args.path) ~= 'string' or args.path == '') then
    return nil, 'path must be a non-empty string'
  end
  if args.limit ~= nil and not util.is_integer(args.limit, 1) then
    return nil, 'limit must be a positive integer'
  end

  local root = common.resolve(request, args.path or '.')
  local stat = vim.uv.fs_stat(root)
  if not stat then
    return nil, 'search root does not exist'
  end
  if stat.type ~= 'directory' then
    return nil, 'search root is not a directory'
  end

  local limit = math.min(args.limit or 200, common.limits.entries)
  local paths, stopped
  if common.rg_available(deps) then
    paths = optimized(root, args.pattern, deps)
  else
    paths, stopped = fallback(root, args.pattern, limit)
  end
  if not paths then
    return nil, stopped or 'file search failed'
  end

  if #paths == 0 then
    return common.display(request, root) .. ': no matching files'
  end

  local selected = {}
  for index = 1, math.min(limit, #paths) do
    selected[#selected + 1] = paths[index]
  end
  local byte_truncated
  selected, byte_truncated = common.bounded_lines(selected, common.limits.output_bytes)

  local output = { common.display(request, root) .. ':' }
  vim.list_extend(output, selected)
  if #selected < #paths then
    output[#output + 1] = string.format('truncated by result limit; %d of %d collected results shown', #selected, #paths)
  elseif byte_truncated then
    output[#output + 1] = 'truncated by output byte limit'
  elseif stopped then
    output[#output + 1] = 'truncated by ' .. stopped
  end
  return table.concat(output, '\n')
end

return M
