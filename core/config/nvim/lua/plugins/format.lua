-- Formatting and extra linting.
--
-- conform.nvim runs the formatter. nvim-lint runs mypy, which is not a language
-- server and so cannot report through LSP. Both prefer the binary in the active
-- virtualenv, so Python results match the ruff and mypy hook.

--- Find an executable inside the project virtualenv, else fall back to PATH.
--- @param name string
--- @return string|nil
local function venv_bin(name)
  local roots = {}
  if vim.env.VIRTUAL_ENV then table.insert(roots, vim.env.VIRTUAL_ENV) end
  local cwd = vim.fn.getcwd()
  table.insert(roots, cwd .. '/.venv')
  table.insert(roots, cwd .. '/venv')

  for _, root in ipairs(roots) do
    local candidate = root .. '/bin/' .. name
    if vim.uv.fs_stat(candidate) then return candidate end
  end

  local on_path = vim.fn.exepath(name)
  return on_path ~= '' and on_path or nil
end

return {
  {
    'stevearc/conform.nvim',
    event = 'BufWritePre',
    cmd = 'ConformInfo',
    keys = {
      {
        '<leader>cf',
        function() require('conform').format({ async = true, lsp_format = 'fallback' }) end,
        mode = { 'n', 'v' },
        desc = 'Format the buffer or selection',
      },
      {
        '<leader>cF',
        function() vim.g.disable_autoformat = not vim.g.disable_autoformat end,
        desc = 'Toggle format on save',
      },
    },
    opts = {
      formatters_by_ft = {
        python = { 'ruff_organize_imports', 'ruff_format' },
        lua = { 'stylua' },
        sh = { 'shfmt' },
        bash = { 'shfmt' },
        zsh = { 'shfmt' },
        javascript = { 'prettier' },
        typescript = { 'prettier' },
        typescriptreact = { 'prettier' },
        json = { 'prettier' },
        jsonc = { 'prettier' },
        yaml = { 'prettier' },
        markdown = { 'prettier' },
        css = { 'prettier' },
        html = { 'prettier' },
      },
      formatters = {
        ruff_format = { command = venv_bin('ruff') or 'ruff' },
        ruff_organize_imports = { command = venv_bin('ruff') or 'ruff' },
      },
      format_on_save = function(bufnr)
        if vim.g.disable_autoformat or vim.b[bufnr].disable_autoformat then
          return nil
        end
        return { timeout_ms = 3000, lsp_format = 'fallback' }
      end,
    },
  },

  {
    'mfussenegger/nvim-lint',
    event = { 'BufReadPre', 'BufNewFile' },
    config = function()
      local lint = require('lint')

      lint.linters_by_ft = {
        python = { 'mypy' },
      }

      local mypy = venv_bin('mypy')
      if mypy then
        lint.linters.mypy.cmd = mypy
      else
        lint.linters_by_ft.python = {}
      end

      -- mypy is slow, so run it on write and on entering a buffer, not on every keystroke
      vim.api.nvim_create_autocmd({ 'BufWritePost', 'BufEnter' }, {
        group = vim.api.nvim_create_augroup('harness_lint', { clear = true }),
        callback = function()
          if vim.bo.modifiable and not vim.bo.readonly then
            lint.try_lint()
          end
        end,
      })

      vim.keymap.set('n', '<leader>cl', function() lint.try_lint() end, { desc = 'Run the linters now' })
    end,
  },
}
