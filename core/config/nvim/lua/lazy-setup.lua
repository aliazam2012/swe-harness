-- Bootstrap and configure lazy.nvim, the plugin manager.
-- Plugin specs live in lua/plugins/. Each file there returns a spec table.
-- Docs: https://lazy.folke.io

local lazypath = vim.fn.stdpath('data') .. '/lazy/lazy.nvim'
if not (vim.uv or vim.loop).fs_stat(lazypath) then
  local out = vim.fn.system({
    'git', 'clone', '--filter=blob:none', '--branch=stable',
    'https://github.com/folke/lazy.nvim.git', lazypath,
  })
  if vim.v.shell_error ~= 0 then
    vim.api.nvim_echo({
      { 'Failed to clone lazy.nvim:\n', 'ErrorMsg' },
      { out, 'WarningMsg' },
      { '\nPress any key to exit...' },
    }, true, {})
    vim.fn.getchar()
    os.exit(1)
  end
end
vim.opt.rtp:prepend(lazypath)

require('lazy').setup({
  spec = { { import = 'plugins' } },
  install = { colorscheme = { 'gruvbox', 'habamax' } },
  checker = { enabled = true, notify = false },  -- check for updates quietly
  change_detection = { notify = false },
  rocks = { enabled = false },  -- no plugin here needs luarocks
  ui = { border = 'rounded' },
  performance = {
    rtp = {
      disabled_plugins = { 'gzip', 'tarPlugin', 'tohtml', 'tutor', 'zipPlugin', 'netrwPlugin' },
    },
  },
})
