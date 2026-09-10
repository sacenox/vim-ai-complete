# TODO

## Look into asynchronous generation

Blocking the UI is a shortcut that ensures the buffer does not change and lets us easily insert the LLM output without collisions or conflicts by using Neovim's `gv` command.
It is time to stop using this shortcut and make the generation asynchronous.
