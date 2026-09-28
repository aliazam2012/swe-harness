-- Completion. blink.cmp reads from the language servers, snippets, the current
-- buffer, and paths. The fuzzy matcher is a prebuilt Rust binary, so no cargo
-- toolchain is needed.
--
-- Keys: C-space opens the menu, C-n and C-p move, C-y accepts, C-e hides.
return {
  {
    'saghen/blink.cmp',
    event = { 'InsertEnter', 'CmdlineEnter' },
    version = '*', -- a release tag, so the prebuilt binary is downloaded
    dependencies = {
      'saghen/blink.lib',
      'rafamadriz/friendly-snippets',
    },
    build = function()
      require('blink.cmp').build():pwait()
    end,
    ---@module 'blink.cmp'
    ---@type blink.cmp.Config
    opts = {
      keymap = { preset = 'default' },
      appearance = { nerd_font_variant = 'mono' },
      completion = {
        documentation = { auto_show = true, auto_show_delay_ms = 300 },
        ghost_text = { enabled = false },
        list = { selection = { preselect = false, auto_insert = true } },
      },
      signature = { enabled = true },
      sources = {
        default = { 'lsp', 'path', 'snippets', 'buffer' },
      },
      fuzzy = { implementation = 'prefer_rust_with_warning' },
    },
    opts_extend = { 'sources.default' },
  },
}
