# TODO

## Suggest next _few_ lines?

Either on idle cursor, or as an explicit command from the user, generate a suggestion from the code surrounding the current cursor position. Show it as a suggestion (italic maybe) with a vim command to accept.

## Look into asynchronous generation

Blocking the UI is a shortcut that ensures the buffer does not change and lets us easily insert the LLM output without collisions or conflicts by using Neovim's `gv` command.
It is time to stop using this shortcut and make the generation asynchronous.
