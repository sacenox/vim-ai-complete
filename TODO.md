# TODO

These items describe product needs, not committed designs.

## Conversational edit sessions

Support a conversation or session around each requested edit so the user can iterate with the model and refine its result while retaining relevant context. See [`docs/llama-vim-reference.md`](docs/llama-vim-reference.md) for a source-based review of a similar edit-scoped conversation model.

The interaction model is intentionally undecided. Do not commit to retry commands, refinement commands, or a particular session UI until the workflow has been explored further.

## Long-prompt input

Investigate a dedicated prompt input UI because long `:Ai` command-line prompts can disrupt Neovim's layout. The input should handle long or multiline prompts while keeping the selected code visible. `vim.ui.input()`, a floating window, or a scratch buffer are possible approaches, not requirements.

## Asynchronous generation

Revisit non-blocking generation when conversational edit sessions make it useful. Blocking is intentional for the current one-shot workflow because it prevents the target selection from changing while generation is in progress.

Any asynchronous design must define what happens when the user edits the target buffer or selection before a result arrives. It must not overwrite newer edits unconditionally, and automatic reconciliation should not be introduced without a clear interaction model.
