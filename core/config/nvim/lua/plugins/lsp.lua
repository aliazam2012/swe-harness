-- Language servers: go-to-definition, rename, hover docs, inline errors.
--
-- Neovim 0.11+ configures servers with vim.lsp.config() and turns them on with
-- vim.lsp.enable(). nvim-lspconfig only supplies the default cmd and root
-- markers for each server. mason installs the server binaries into
-- ~/.local/share/nvim/mason, so nothing lands on the global PATH.
--
-- Python is the exception: ruff and mypy come from the active virtualenv, so
-- the rules here match the ruff and mypy settings the harness hook enforces.

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
    'neovim/nvim-lspconfig',
    event = { 'BufReadPre', 'BufNewFile' },
    dependencies = {
      { 'mason-org/mason.nvim', opts = { ui = { border = 'rounded' } } },
      'mason-org/mason-lspconfig.nvim',
      'WhoIsSethDaniel/mason-tool-installer.nvim',
    },
    config = function()
      -- ----------------------------------------------------------------
      -- How diagnostics look
      -- ----------------------------------------------------------------
      vim.diagnostic.config({
        severity_sort = true,
        underline = { severity = vim.diagnostic.severity.WARN },
        update_in_insert = false,
        virtual_text = {
          spacing = 2,
          source = 'if_many',
          prefix = '●',
        },
        signs = {
          text = {
            [vim.diagnostic.severity.ERROR] = ' ',
            [vim.diagnostic.severity.WARN] = ' ',
            [vim.diagnostic.severity.INFO] = ' ',
            [vim.diagnostic.severity.HINT] = ' ',
          },
        },
        float = { border = 'rounded', source = 'if_many' },
      })

      -- ----------------------------------------------------------------
      -- Keymaps, set only in buffers that have a server attached
      -- ----------------------------------------------------------------
      vim.api.nvim_create_autocmd('LspAttach', {
        group = vim.api.nvim_create_augroup('harness_lsp_attach', { clear = true }),
        callback = function(event)
          local function map(keys, fn, desc, mode)
            vim.keymap.set(mode or 'n', keys, fn, { buffer = event.buf, desc = 'LSP: ' .. desc })
          end

          map('gd', vim.lsp.buf.definition, 'Go to definition')
          map('gD', vim.lsp.buf.declaration, 'Go to declaration')
          map('gr', vim.lsp.buf.references, 'List references')
          map('gi', vim.lsp.buf.implementation, 'Go to implementation')
          map('gt', vim.lsp.buf.type_definition, 'Go to type definition')
          map('K', vim.lsp.buf.hover, 'Hover docs')
          map('<leader>cr', vim.lsp.buf.rename, 'Rename symbol')
          map('<leader>ca', vim.lsp.buf.code_action, 'Code action', { 'n', 'v' })
          map('<leader>cs', vim.lsp.buf.signature_help, 'Signature help')
          map('<leader>ci', function()
            local enabled = vim.lsp.inlay_hint.is_enabled({ bufnr = event.buf })
            vim.lsp.inlay_hint.enable(not enabled, { bufnr = event.buf })
          end, 'Toggle inlay hints')

          -- pyright owns hover for Python. Ruff only reports lint problems.
          local client = vim.lsp.get_client_by_id(event.data.client_id)
          if client and client.name == 'ruff' then
            client.server_capabilities.hoverProvider = false
          end
        end,
      })

      -- ----------------------------------------------------------------
      -- Per-server settings. These merge onto the nvim-lspconfig defaults.
      -- ----------------------------------------------------------------
      vim.lsp.config('lua_ls', {
        settings = {
          Lua = {
            runtime = { version = 'LuaJIT' },
            workspace = { checkThirdParty = false },
            diagnostics = { globals = { 'vim' } },
            telemetry = { enable = false },
            hint = { enable = true },
            format = { enable = false }, -- stylua does the formatting
          },
        },
      })

      vim.lsp.config('pyright', {
        settings = {
          python = {
            pythonPath = venv_bin('python3'),
            analysis = {
              typeCheckingMode = 'standard',
              autoSearchPaths = true,
              useLibraryCodeForTypes = true,
              -- ruff reports these, so do not report them twice
              diagnosticSeverityOverrides = {
                reportUnusedImport = 'none',
                reportUnusedVariable = 'none',
              },
            },
          },
        },
      })

      -- ----------------------------------------------------------------
      -- Install and enable. mason must be set up before mason-lspconfig.
      -- ----------------------------------------------------------------
      require('mason-lspconfig').setup({
        ensure_installed = {
          'lua_ls',      -- Lua, including this config
          'pyright',     -- Python types
          'ts_ls',       -- TypeScript and JavaScript
          'bashls',      -- shell scripts
          'jsonls',      -- JSON
          'yamlls',      -- YAML
          'marksman',    -- Markdown
        },
        -- stylua ships an LSP config, but conform.nvim already runs stylua.
        -- Enabling both makes two formatters fight over the same buffer.
        automatic_enable = { exclude = { 'stylua' } },
      })

      require('mason-tool-installer').setup({
        ensure_installed = { 'stylua', 'prettier', 'shfmt' },
        run_on_start = true,
      })

      -- Ruff comes from the virtualenv, not from mason, so the lint rules are
      -- the same ones the harness hook enforces.
      local ruff = venv_bin('ruff')
      if ruff then
        vim.lsp.config('ruff', { cmd = { ruff, 'server' } })
        vim.lsp.enable('ruff')
      else
        vim.notify('ruff not found in the venv or on PATH; Python lint is off', vim.log.levels.WARN)
      end
    end,
  },
}
