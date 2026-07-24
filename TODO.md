# TODO

These items describe product needs, not committed designs.

## Conversational edit sessions

Support a conversation or session around each requested edit so the user can iterate with the model and refine its result while retaining relevant context. See [`docs/llama-vim-reference.md`](docs/llama-vim-reference.md) for a source-based review of a similar edit-scoped conversation model.

The interaction model is intentionally undecided. Do not commit to retry commands, refinement commands, or a particular session UI until the workflow has been explored further.

## Authentication UX

Authentication currently belongs to the configured LLM command. If a future integration requires plugin-managed authentication, provide a progressive in-Neovim flow similar to Windsurf's: let the user open the authorization page, copy its URL, display it inside Neovim, or provide an existing credential. Secret input must not expose credentials in the command line, messages, or logs.

Keep the user in Neovim except when browser authorization is required, and provide a fallback when automatically opening the browser is unavailable.

## Long-prompt input

Investigate a dedicated prompt input UI because long `:Ai` command-line prompts can disrupt Neovim's layout. The input should handle long or multiline prompts while keeping the selected code visible. `vim.ui.input()`, a floating window, or a scratch buffer are possible approaches, not requirements.

## Asynchronous generation

Revisit non-blocking generation when conversational edit sessions make it useful. Blocking is intentional for the current one-shot workflow because it prevents the target selection from changing while generation is in progress.

Any asynchronous design must define what happens when the user edits the target buffer or selection before a result arrives. It must not overwrite newer edits unconditionally, and automatic reconciliation should not be introduced without a clear interaction model.
