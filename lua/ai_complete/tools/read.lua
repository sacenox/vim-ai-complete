local common = require('ai_complete.tools.common')
local util = require('ai_complete.util')

local M = {}

function M.run(request, args)
  if type(args.path) ~= 'string' or args.path == '' then
    return nil, 'path must be a non-empty string'
  end
  if args.offset ~= nil and not util.is_integer(args.offset, 1) then
    return nil, 'offset must be a positive integer'
  end
  if args.limit ~= nil and not util.is_integer(args.limit, 1) then
    return nil, 'limit must be a positive integer'
  end

  local path = common.resolve(request, args.path)
  local lines = common.loaded_buffer_lines(path)
  if not lines then
    local contents, read_error = common.read_disk(path, common.limits.read_source_bytes)
    if not contents then
      return nil, read_error
    end
    if common.is_binary(contents) then
      return nil, 'binary files are not supported'
    end
    lines = common.split_lines(contents)
  else
    for _, line in ipairs(lines) do
      if common.is_binary(line) then
        return nil, 'binary buffer content is not supported'
      end
    end
  end

  local display = common.display(request, path)
  if #lines == 0 then
    return display .. ': empty file'
  end

  local offset = args.offset or 1
  if offset > #lines then
    return nil, 'offset is past the end of the file (' .. #lines .. ' lines)'
  end
  local requested_limit = math.min(args.limit or 200, common.limits.read_lines)
  local last = math.min(#lines, offset + requested_limit - 1)
  local output = {}
  local bytes = 0
  local actual_last = offset - 1

  for number = offset, last do
    local line = string.format('%d: %s', number, common.truncate_line(lines[number]))
    if bytes + #line + 1 > common.limits.output_bytes then
      break
    end
    output[#output + 1] = line
    bytes = bytes + #line + 1
    actual_last = number
  end

  local header = string.format('%s: lines %d-%d of %d', display, offset, actual_last, #lines)
  table.insert(output, 1, header)
  if actual_last < #lines then
    output[#output + 1] = string.format('truncated; continue with offset=%d', actual_last + 1)
  end
  return table.concat(output, '\n')
end

return M
