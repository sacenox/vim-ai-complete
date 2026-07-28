local common = require('ai_complete.tools.common')
local util = require('ai_complete.util')

local M = {}

local function optimized(request, target, args, limit, deps)
  local files, stopped = common.walk(target, {
    traversal_limit = common.limits.traversal,
    file_limit = common.limits.grep_files,
  })
  if not files then
    return nil, stopped
  end

  local glob_pattern
  if args.glob then
    local pattern_error
    glob_pattern, pattern_error = common.glob_pattern(args.glob)
    if not glob_pattern then
      return nil, pattern_error
    end
  end

  local argv = {
    'rg',
    '--json',
    '--max-filesize',
    tostring(common.limits.read_source_bytes),
    '--max-columns',
    tostring(common.limits.line_bytes),
    '--max-columns-preview',
    '--max-count',
    tostring(limit),
  }
  if args.ignoreCase then
    argv[#argv + 1] = '--ignore-case'
  end
  if args.literal then
    argv[#argv + 1] = '--fixed-strings'
  end
  if args.context and args.context > 0 then
    vim.list_extend(argv, { '--context', tostring(args.context) })
  end
  vim.list_extend(argv, { '--', args.pattern })

  local argv_bytes = 0
  local selected_files = 0
  for _, file in ipairs(files) do
    if not glob_pattern or file.relative:match(glob_pattern) then
      if argv_bytes + #file.path + 1 > 256 * 1024 then
        stopped = 'file argument byte limit'
        break
      end
      argv[#argv + 1] = file.path
      argv_bytes = argv_bytes + #file.path + 1
      selected_files = selected_files + 1
    end
  end
  if selected_files == 0 then
    return {}, 0, stopped
  end

  local result, run_error = common.run(argv, request.cwd, deps)
  if not result then
    return nil, run_error
  end
  if result.code ~= 0 and result.code ~= 1 then
    return nil, 'regular expression or search path is invalid'
  end

  local lines = {}
  local matches = 0
  local truncated = stopped
  for encoded in result.stdout:gmatch('[^\r\n]+') do
    local ok, event = pcall(util.json_decode, encoded)
    if not ok or type(event) ~= 'table' then
      return nil, 'rg returned malformed search data'
    end
    if event.type == 'match' or event.type == 'context' then
      local data = event.data
      local path = type(data) == 'table' and data.path or nil
      local text = type(data) == 'table' and data.lines or nil
      if type(path) == 'table' and type(path.text) == 'string' and type(text) == 'table' and type(text.text) == 'string' then
        if event.type == 'match' then
          matches = matches + 1
        end
        if matches > limit then
          truncated = 'match limit'
          break
        end
        local separator = event.type == 'match' and ':' or '-'
        local content = text.text:gsub('[\r\n]+$', '')
        lines[#lines + 1] = string.format(
          '%s%s%d%s %s',
          common.display(request, path.text),
          separator,
          data.line_number or 0,
          separator,
          common.truncate_line(content)
        )
      end
    end
  end

  local bounded, byte_truncated = common.bounded_lines(lines, common.limits.output_bytes)
  if byte_truncated then
    truncated = 'output byte limit'
  end
  return bounded, matches, truncated
end

local function compile_matcher(args)
  if args.literal then
    local needle = args.ignoreCase and args.pattern:lower() or args.pattern
    return function(line)
      local haystack = args.ignoreCase and line:lower() or line
      return haystack:find(needle, 1, true) ~= nil
    end
  end

  local pattern = args.ignoreCase and ('\\c' .. args.pattern) or args.pattern
  local ok, regex = pcall(vim.regex, pattern)
  if not ok then
    return nil, 'regular expression is invalid'
  end
  return function(line)
    return regex:match_str(line) ~= nil
  end
end

local function fallback(request, target, args, limit)
  local matcher, matcher_error = compile_matcher(args)
  if not matcher then
    return nil, matcher_error
  end

  local files, stopped = common.walk(target, {
    traversal_limit = common.limits.traversal,
    file_limit = common.limits.grep_files,
  })
  if not files then
    return nil, stopped
  end

  local glob_pattern
  if args.glob then
    glob_pattern, matcher_error = common.glob_pattern(args.glob)
    if not glob_pattern then
      return nil, matcher_error
    end
  end

  local output = {}
  local matches = 0
  local scanned_bytes = 0
  local truncated = stopped

  for _, file in ipairs(files) do
    if not truncated or truncated == 'file limit' then
      if not glob_pattern or file.relative:match(glob_pattern) then
        local lines = common.loaded_buffer_lines(file.path)
        local contents
        if not lines then
          local stat = vim.uv.fs_stat(file.path)
          if stat and stat.size + scanned_bytes > common.limits.grep_source_bytes then
            truncated = 'scan byte limit'
            break
          end
          contents = common.read_disk(file.path, common.limits.read_source_bytes)
          if contents and not common.is_binary(contents) then
            scanned_bytes = scanned_bytes + #contents
            lines = common.split_lines(contents)
          end
        elseif vim.tbl_contains(lines, '\0') then
          lines = nil
        else
          for _, line in ipairs(lines) do
            if common.is_binary(line) then
              lines = nil
              break
            end
          end
        end

        if lines then
          local emitted_context = {}
          for number, line in ipairs(lines) do
            if matcher(line) then
              matches = matches + 1
              if matches > limit then
                truncated = 'match limit'
                break
              end
              local context = args.context or 0
              local first = math.max(1, number - context)
              local last = math.min(#lines, number + context)
              for current = first, last do
                local key = file.path .. ':' .. current
                if not emitted_context[key] then
                  local separator = current == number and ':' or '-'
                  output[#output + 1] = string.format(
                    '%s%s%d%s %s',
                    common.display(request, file.path),
                    separator,
                    current,
                    separator,
                    common.truncate_line(lines[current])
                  )
                  emitted_context[key] = true
                end
              end
            end
          end
        end
      end
    end
    if truncated and truncated ~= 'file limit' then
      break
    end
  end

  local bounded, byte_truncated = common.bounded_lines(output, common.limits.output_bytes)
  if byte_truncated then
    truncated = 'output byte limit'
  end
  return bounded, matches, truncated
end

function M.run(request, args, deps)
  if type(args.pattern) ~= 'string' or args.pattern == '' then
    return nil, 'pattern must be a non-empty string'
  end
  if args.path ~= nil and (type(args.path) ~= 'string' or args.path == '') then
    return nil, 'path must be a non-empty string'
  end
  if args.glob ~= nil and (type(args.glob) ~= 'string' or args.glob == '') then
    return nil, 'glob must be a non-empty string'
  end
  if args.ignoreCase ~= nil and type(args.ignoreCase) ~= 'boolean' then
    return nil, 'ignoreCase must be a boolean'
  end
  if args.literal ~= nil and type(args.literal) ~= 'boolean' then
    return nil, 'literal must be a boolean'
  end
  if args.context ~= nil and not util.is_integer(args.context, 0) then
    return nil, 'context must be a non-negative integer'
  end
  if args.limit ~= nil and not util.is_integer(args.limit, 1) then
    return nil, 'limit must be a positive integer'
  end

  args.context = math.min(args.context or 0, 20)
  local limit = math.min(args.limit or 200, common.limits.entries)
  local target = common.resolve(request, args.path or '.')
  if not vim.uv.fs_stat(target) then
    return nil, 'search path does not exist'
  end

  local lines, matches, truncated
  if common.rg_available(deps) then
    lines, matches, truncated = optimized(request, target, args, limit, deps)
  else
    lines, matches, truncated = fallback(request, target, args, limit)
  end
  if not lines then
    return nil, matches
  end

  if #lines == 0 then
    return common.display(request, target) .. ': no matches'
  end
  local output = { string.format('%s: %d match(es)', common.display(request, target), math.min(matches, limit)) }
  vim.list_extend(output, lines)
  if truncated then
    output[#output + 1] = 'truncated by ' .. truncated
  end
  return table.concat(output, '\n')
end

return M
