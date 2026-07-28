local common = require('ai_complete.tools.common')

local M = {}

local implementations = {
  read = require('ai_complete.tools.read'),
  ls = require('ai_complete.tools.ls'),
  find = require('ai_complete.tools.find'),
  grep = require('ai_complete.tools.grep'),
}

local function object(properties, required)
  return {
    type = 'object',
    properties = properties,
    required = required or {},
    additionalProperties = false,
  }
end

local definitions = {
  {
    type = 'function',
    name = 'read',
    description = 'Read a text file. Loaded Neovim buffer content is used when available.',
    parameters = object({
      path = { type = 'string', description = 'Absolute path or path relative to the captured cwd.' },
      offset = { type = 'integer', minimum = 1, description = 'First 1-indexed line to return.' },
      limit = { type = 'integer', minimum = 1, description = 'Maximum number of lines to return.' },
    }, { 'path' }),
  },
  {
    type = 'function',
    name = 'ls',
    description = 'List a directory, including dotfiles.',
    parameters = object({
      path = { type = 'string', description = 'Directory path. Defaults to the captured cwd.' },
      limit = { type = 'integer', minimum = 1, description = 'Maximum number of entries.' },
    }),
  },
  {
    type = 'function',
    name = 'find',
    description = 'Recursively find files whose relative paths match a glob.',
    parameters = object({
      pattern = { type = 'string', description = 'Glob matched against paths relative to the search root.' },
      path = { type = 'string', description = 'Search root. Defaults to the captured cwd.' },
      limit = { type = 'integer', minimum = 1, description = 'Maximum number of results.' },
    }, { 'pattern' }),
  },
  {
    type = 'function',
    name = 'grep',
    description = 'Search text files and return paths, line numbers, matching lines, and optional context.',
    parameters = object({
      pattern = { type = 'string', description = 'Literal text or regular expression.' },
      path = { type = 'string', description = 'File or directory. Defaults to the captured cwd.' },
      glob = { type = 'string', description = 'Optional file glob.' },
      ignoreCase = { type = 'boolean', description = 'Use case-insensitive matching.' },
      literal = { type = 'boolean', description = 'Treat pattern as literal text.' },
      context = { type = 'integer', minimum = 0, description = 'Surrounding lines to include.' },
      limit = { type = 'integer', minimum = 1, description = 'Maximum number of matches.' },
    }, { 'pattern' }),
  },
}

function M.definitions()
  return vim.deepcopy(definitions)
end

function M.execute(request, call, deps)
  if type(call) ~= 'table' or type(call.name) ~= 'string' then
    return 'tool error: malformed function call'
  end
  local implementation = implementations[call.name]
  if not implementation then
    return 'tool error: unknown tool "' .. call.name .. '"'
  end

  local args, decode_error = common.decode_arguments(call.arguments)
  if not args then
    return 'tool error: ' .. decode_error
  end

  local ok, output, tool_error = pcall(implementation.run, request, args, deps)
  if not ok then
    return 'tool error: tool execution failed'
  end
  if output == nil then
    return 'tool error: ' .. tostring(tool_error or 'tool execution failed')
  end
  return output
end

return M
