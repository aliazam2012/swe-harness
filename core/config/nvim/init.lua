-- Neovim entry point.
--   lua/vim_config.lua   core options, no plugins
--   lua/keymaps.lua      keymaps that need no plugin
--   lua/autocmds.lua     autocommands
--   lua/lazy-setup.lua   plugin manager, loads lua/plugins/*.lua
--
-- Health check:  :checkhealth
-- Plugin status: :Lazy
-- LSP status:    :checkhealth vim.lsp

require('vim_config')
require('keymaps')
require('autocmds')
require('lazy-setup')
