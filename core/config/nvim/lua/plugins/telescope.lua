-- Telescope: fuzzy finder over files, grep results, buffers, and LSP symbols.
-- It uses the ripgrep and fd binaries that are already on PATH.
return {
  {
    'nvim-telescope/telescope.nvim',
    cmd = 'Telescope',
    dependencies = {
      'nvim-lua/plenary.nvim',
      { 'nvim-telescope/telescope-fzf-native.nvim', build = 'make' },
      'nvim-tree/nvim-web-devicons',
    },
    keys = {
      { '<leader>ff', '<cmd>Telescope find_files<CR>', desc = 'Find files' },
      { '<leader>fg', '<cmd>Telescope live_grep<CR>', desc = 'Grep in the project' },
      { '<leader>fb', '<cmd>Telescope buffers<CR>', desc = 'Find open buffers' },
      { '<leader>fh', '<cmd>Telescope help_tags<CR>', desc = 'Search the help' },
      { '<leader>fr', '<cmd>Telescope oldfiles<CR>', desc = 'Recent files' },
      { '<leader>fw', '<cmd>Telescope grep_string<CR>', desc = 'Grep the word under the cursor' },
      { '<leader>fd', '<cmd>Telescope diagnostics<CR>', desc = 'Find diagnostics' },
      { '<leader>fs', '<cmd>Telescope lsp_document_symbols<CR>', desc = 'Symbols in this file' },
      { '<leader>fS', '<cmd>Telescope lsp_dynamic_workspace_symbols<CR>', desc = 'Symbols in the project' },
      { '<leader>fk', '<cmd>Telescope keymaps<CR>', desc = 'Search keymaps' },
      { '<leader>fc', '<cmd>Telescope git_status<CR>', desc = 'Changed files' },
    },
    opts = function()
      local actions = require('telescope.actions')
      return {
        defaults = {
          prompt_prefix = '   ',
          selection_caret = ' ',
          path_display = { 'truncate' },
          sorting_strategy = 'ascending',
          layout_config = {
            horizontal = { prompt_position = 'top', preview_width = 0.55 },
            width = 0.9,
            height = 0.85,
          },
          file_ignore_patterns = {
            '%.git/', 'node_modules/', '%.venv/', 'venv/', '__pycache__/',
            '%.mypy_cache/', '%.ruff_cache/', '%.pytest_cache/', 'dist/', 'build/',
          },
          mappings = {
            i = {
              ['<C-j>'] = actions.move_selection_next,
              ['<C-k>'] = actions.move_selection_previous,
              ['<C-q>'] = actions.send_to_qflist + actions.open_qflist,
              ['<Esc>'] = actions.close,
            },
          },
        },
        pickers = {
          find_files = { hidden = true },
        },
        extensions = {
          fzf = { fuzzy = true, override_generic_sorter = true, override_file_sorter = true },
        },
      }
    end,
    config = function(_, opts)
      local telescope = require('telescope')
      telescope.setup(opts)
      pcall(telescope.load_extension, 'fzf')
    end,
  },
}
