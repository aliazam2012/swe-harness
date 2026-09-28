-- Status line. Shows the git branch, diagnostics, and the attached LSP servers.
return {
  {
    'nvim-lualine/lualine.nvim',
    event = 'VeryLazy',
    dependencies = { 'nvim-tree/nvim-web-devicons' },
    opts = function()
      -- Name the language servers attached to this buffer
      local function lsp_names()
        local clients = vim.lsp.get_clients({ bufnr = 0 })
        if #clients == 0 then return '' end
        local names = {}
        for _, client in ipairs(clients) do
          table.insert(names, client.name)
        end
        return ' ' .. table.concat(names, ',')
      end

      return {
        options = {
          theme = 'gruvbox',
          globalstatus = true,
          section_separators = '',
          component_separators = '│',
        },
        sections = {
          lualine_a = { 'mode' },
          lualine_b = { 'branch', 'diff' },
          lualine_c = { { 'filename', path = 1 } },
          lualine_x = {
            { 'diagnostics', sources = { 'nvim_lsp' } },
            { lsp_names },
            'filetype',
          },
          lualine_y = { 'progress' },
          lualine_z = { 'location' },
        },
      }
    end,
  },
}
