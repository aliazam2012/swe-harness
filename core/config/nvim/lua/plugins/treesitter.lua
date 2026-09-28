-- Treesitter: real syntax trees, so highlighting, folds, and indent follow the
-- code structure instead of regex guesses.
--
-- This uses the `main` branch, which is a full rewrite. The old
-- `ensure_installed` option is gone; you call install() with a language list.
-- Highlighting itself comes from Neovim (vim.treesitter.start).
local languages = {
  'bash', 'c', 'css', 'diff', 'dockerfile', 'gitcommit', 'gitignore', 'go',
  'html', 'javascript', 'json', 'lua', 'luadoc', 'make', 'markdown',
  'markdown_inline', 'python', 'query', 'regex', 'sql', 'toml', 'tsx',
  'typescript', 'vim', 'vimdoc', 'yaml',
}

return {
  {
    'nvim-treesitter/nvim-treesitter',
    branch = 'main',
    lazy = false,
    build = ':TSUpdate',
    config = function()
      require('nvim-treesitter').setup({
        install_dir = vim.fn.stdpath('data') .. '/site',
      })
      require('nvim-treesitter').install(languages)

      -- Turn on the treesitter features for any file we have a parser for
      vim.api.nvim_create_autocmd('FileType', {
        group = vim.api.nvim_create_augroup('harness_treesitter', { clear = true }),
        callback = function(event)
          local lang = vim.treesitter.language.get_lang(vim.bo[event.buf].filetype)
          if not lang or not vim.treesitter.language.add(lang) then
            return -- no parser for this filetype, leave the regex highlighter alone
          end
          vim.treesitter.start(event.buf, lang)
          vim.wo.foldexpr = 'v:lua.vim.treesitter.foldexpr()'
          vim.wo.foldmethod = 'expr'
          vim.bo[event.buf].indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()"
        end,
      })

      -- Folds start open. zc closes one, zR opens all.
      vim.opt.foldlevel = 99
      vim.opt.foldtext = ''
    end,
  },
}
