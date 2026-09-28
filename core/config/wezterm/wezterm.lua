-- WezTerm configuration
-- Docs: https://wezterm.org/config/files.html
-- This file hot-reloads on save. No restart needed.

local wezterm = require("wezterm")
local act = wezterm.action
local config = wezterm.config_builder()

-- ---------------------------------------------------------------------------
-- Appearance: matches the Gruvbox Rainbow starship prompt
-- ---------------------------------------------------------------------------
config.color_scheme = "GruvboxDarkHard"

config.font = wezterm.font_with_fallback({
	{ family = "JetBrainsMono Nerd Font", weight = "Regular" },
	{ family = "Symbols Nerd Font Mono", scale = 0.9 },
	"Apple Color Emoji",
})
config.font_size = 13.0
config.line_height = 1.1
config.cell_width = 1.0

-- ---------------------------------------------------------------------------
-- Window
-- ---------------------------------------------------------------------------
config.window_decorations = "RESIZE"
config.window_padding = { left = 12, right = 12, top = 10, bottom = 8 }
config.initial_cols = 120
config.initial_rows = 34
config.adjust_window_size_when_changing_font_size = false
config.default_cursor_style = "BlinkingBar"
config.scrollback_lines = 10000
config.audible_bell = "Disabled"

-- ---------------------------------------------------------------------------
-- Tab bar
-- ---------------------------------------------------------------------------
config.use_fancy_tab_bar = false
config.hide_tab_bar_if_only_one_tab = true
config.tab_bar_at_bottom = false
config.tab_max_width = 32
config.show_new_tab_button_in_tab_bar = false

-- ---------------------------------------------------------------------------
-- Keys
--
-- herdr owns panes, tabs, and workspaces (prefix ctrl+b). WezTerm deliberately
-- keeps no split or pane-navigation bindings, so the two never fight over the
-- same keystroke. See ~/.config/herdr/config.toml.
--
-- Only CMD+k stays, because clearing the scrollback is a terminal concern.
-- ---------------------------------------------------------------------------
config.keys = {
	{ key = "k", mods = "CMD", action = act.ClearScrollback("ScrollbackAndViewport") },
}

return config
