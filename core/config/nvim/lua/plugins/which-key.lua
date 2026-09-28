-- which-key: press <leader> and wait. A menu shows every keymap under it.
-- This is how you learn the config without reading it.
return {
  {
    'folke/which-key.nvim',
    event = 'VeryLazy',
    opts = {
      preset = 'helix',
      delay = 400,
      spec = {
        { '<leader>b', group = 'buffer' },
        { '<leader>c', group = 'code' },
        { '<leader>f', group = 'find' },
        { '<leader>g', group = 'git' },
        { '<leader>x', group = 'diagnostics' },
      },
    },
    keys = {
      {
        '<leader>?',
        function() require('which-key').show({ global = false }) end,
        desc = 'Keymaps for this buffer',
      },
    },
  },
}
