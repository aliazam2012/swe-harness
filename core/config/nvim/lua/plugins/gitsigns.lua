-- Gitsigns: change markers in the sign column, inline blame, hunk staging.
return {
  {
    'lewis6991/gitsigns.nvim',
    event = { 'BufReadPre', 'BufNewFile' },
    opts = {
      signs = {
        add = { text = '│' },
        change = { text = '│' },
        delete = { text = '_' },
        topdelete = { text = '‾' },
        changedelete = { text = '~' },
        untracked = { text = '┆' },
      },
      current_line_blame = false, -- toggle it with <leader>gb
      current_line_blame_opts = { delay = 300, virt_text_pos = 'eol' },
      on_attach = function(bufnr)
        local gs = require('gitsigns')
        local function map(mode, lhs, rhs, desc)
          vim.keymap.set(mode, lhs, rhs, { buffer = bufnr, desc = desc })
        end

        map('n', ']c', function()
          if vim.wo.diff then return ']c' end
          vim.schedule(function() gs.nav_hunk('next') end)
          return '<Ignore>'
        end, 'Next git hunk')

        map('n', '[c', function()
          if vim.wo.diff then return '[c' end
          vim.schedule(function() gs.nav_hunk('prev') end)
          return '<Ignore>'
        end, 'Previous git hunk')

        map('n', '<leader>gs', gs.stage_hunk, 'Stage hunk')
        map('n', '<leader>gr', gs.reset_hunk, 'Reset hunk')
        map('n', '<leader>gp', gs.preview_hunk, 'Preview hunk')
        map('n', '<leader>gb', gs.toggle_current_line_blame, 'Toggle line blame')
        map('n', '<leader>gB', function() gs.blame_line({ full = true }) end, 'Blame this line')
        map('n', '<leader>gd', gs.diffthis, 'Diff against the index')
      end,
    },
  },
}
