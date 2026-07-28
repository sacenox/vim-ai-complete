local common = require('ai_complete.tools.common')
local util = require('ai_complete.util')

local M = {}

function M.run(request, args)
  if args.path ~= nil and (type(args.path) ~= 'string' or args.path == '') then
    return nil, 'path must be a non-empty string'
  end
  if args.limit ~= nil and not util.is_integer(args.limit, 1) then
    return nil, 'limit must be a positive integer'
  end

  local path = common.resolve(request, args.path or '.')
  local stat = vim.uv.fs_stat(path)
  if not stat then
    return nil, 'path does not exist'
  end
  if stat.type ~= 'directory' then
    return nil, 'path is not a directory'
  end

  local handle = vim.uv.fs_scandir(path)
  if not handle then
    return nil, 'directory is unreadable'
  end
  local entries = {}
  while true do
    local name, kind = vim.uv.fs_scandir_next(handle)
    if not name then
      break
    end
    if not kind then
      local item = vim.uv.fs_stat(path .. '/' .. name)
      kind = item and item.type
    end
    entries[#entries + 1] = name .. (kind == 'directory' and '/' or '')
  end
  table.sort(entries)

  local display = common.display(request, path)
  if #entries == 0 then
    return display .. ': empty directory'
  end

  local limit = math.min(args.limit or 200, common.limits.entries)
  local selected = {}
  for index = 1, math.min(limit, #entries) do
    selected[#selected + 1] = entries[index]
  end
  local byte_truncated
  selected, byte_truncated = common.bounded_lines(selected, common.limits.output_bytes)

  local output = { display .. ':' }
  vim.list_extend(output, selected)
  if #selected < #entries or byte_truncated then
    output[#output + 1] = string.format('truncated; %d of %d entries shown', #selected, #entries)
  end
  return table.concat(output, '\n')
end

return M
