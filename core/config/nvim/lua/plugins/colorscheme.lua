-- Gruvbox, hard contrast. This matches the WezTerm color_scheme
-- "GruvboxDarkHard" in ~/.config/wezterm/wezterm.lua and the starship prompt.
return {
  {
    'ellisonleao/gruvbox.nvim',
    priority = 1000, -- load before every other plugin
    lazy = false,
    opts = {
      contrast = 'hard',
      italic = { strings = false, comments = true, folds = true },
      bold = true,
      transparent_mode = false,
    },
    config = function(_, opts)
      require('gruvbox').setup(opts)
      vim.cmd.colorscheme('gruvbox')
    end,
  },
}
