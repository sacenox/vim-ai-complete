-- Create a table that will hold everything this module exposes.
-- In Lua plugins, returning a table like this lets other files call M.complete().
local M = {}

-- Build the prompt that will be sent to the `pi` command-line tool.
-- We include both editor context and the text the user selected so the tool knows
-- exactly what file it is working on and what text it should transform.
local function prompt_for_pi(user_prompt, selected_text)
  -- table.concat joins each line below with a newline, producing one readable
  -- prompt instead of manually adding "\n" to every string.
  return table.concat({
    -- Current file name, without directories. Example: "init.lua".
    'filename: ' .. vim.fn.expand('%:t'),
    -- Full path to the current file, so the tool has precise context.
    'path: ' .. vim.fn.expand('%:p'),
    -- The user's instruction, such as "add comments" or "refactor this".
    'prompt: ' .. user_prompt,
    -- A label that separates metadata above from the selected text below.
    'selection:',
    -- The actual text selected in Visual mode.
    selected_text,
    -- The "system" prompt
    'Generate an exact replacement for the selected text using the user prompt and surrounding file context. Return only the replacement text.'
  }, '\n')
end

-- Complete or rewrite the current visual selection using the external `pi` tool.
-- `user_prompt` is the instruction typed by the user.
-- `has_range` tells us whether Vim passed a visual range to this command.
function M.complete(user_prompt, has_range)
  -- This command only makes sense when text is selected. If there is no range,
  -- show an error and stop before changing anything.
  if has_range == 0 then
    vim.notify('ai-complete: select text visually first', vim.log.levels.ERROR)
    return
  end

  -- We use register "z" as a temporary clipboard for the selected text and for
  -- the replacement. Before touching it, save its contents and type so we can
  -- restore the user's register exactly as it was.
  local old_z = vim.fn.getreg('z')
  local old_z_type = vim.fn.getregtype('z')

  -- Re-select the previous Visual selection (`gv`), then yank it into register z
  -- (`"zy`). `silent normal!` runs the Normal-mode keys without extra messages or
  -- user mappings, making the command predictable.
  vim.cmd([[silent normal! gv"zy]])

  -- Read the selected text and selection type from register z. The type matters:
  -- it tells Vim whether the selection was characterwise, linewise, or blockwise.
  local selected_text = vim.fn.getreg('z')
  local selected_type = vim.fn.getregtype('z')

  -- Let the user know Neovim is about to block while pi generates a response.
  vim.notify('ai-complete: generating...', vim.log.levels.INFO)
  vim.cmd('redraw')

  -- Call the external `pi` program with a prompt built from the user instruction
  -- and the selected text from Vim's current working directory. The command's
  -- stdout becomes `output`.
  local output = vim.fn.system({
    'sh',
    '-c',
    'cd "$1" && shift && exec "$@"',
    'sh',
    vim.fn.getcwd(),
    'pi',
    '-t',
    'read,find,ls,grep',
    '--thinking',
    'minimal',
    '-p',
    prompt_for_pi(user_prompt, selected_text),
  })

  -- If the shell command failed, restore register z, report the error, and leave
  -- the buffer unchanged.
  if vim.v.shell_error ~= 0 then
    vim.fn.setreg('z', old_z, old_z_type)
    vim.notify('ai-complete: pi failed', vim.log.levels.ERROR)
    return
  end

  -- Put the generated output into register z using the original selection type,
  -- then re-select the same text and paste over it from register z.
  vim.fn.setreg('z', output, selected_type)
  vim.cmd([[silent normal! gv"zp]])

  -- Finally, restore register z so this plugin does not clobber the user's data.
  vim.fn.setreg('z', old_z, old_z_type)

  -- Let the user know we are done.
  vim.notify('ai-complete: done.', vim.log.levels.INFO)
  vim.cmd('redraw')
end

-- Return the module table so Neovim can require() this file and call M.complete().
return M
