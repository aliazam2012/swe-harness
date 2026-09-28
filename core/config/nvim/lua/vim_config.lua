-- Core editor options. No plugins are needed for anything in this file.
-- Docs: :help option-list

local o = vim.opt

vim.g.mapleader = ' '                  -- space is the leader key
vim.g.maplocalleader = '\\'            -- backslash is the local leader

-- Indentation. Two spaces by default; per-language overrides are in autocmds.lua
o.expandtab = true                     -- spaces, not tabs
o.shiftwidth = 2                       -- 2 spaces per indent level
o.tabstop = 2                          -- render a tab as 2 columns
o.softtabstop = 2                      -- backspace removes a full indent
o.smartindent = true                   -- keep indent on a new line

-- Line numbers and gutter
o.number = true                        -- absolute number on the cursor line
o.relativenumber = true                -- relative line numbers for fast jumps
o.cursorline = true                    -- highlight the cursor line
o.signcolumn = 'yes'                   -- always show the sign column, so text never shifts
o.colorcolumn = '100'                  -- the line-length guide

-- Search
o.ignorecase = true                    -- search is case-insensitive by default
o.smartcase = true                     -- case-sensitive only if I type a capital
o.inccommand = 'split'                 -- live preview for :substitute

-- Movement and clipboard
o.clipboard = 'unnamedplus'            -- share the system clipboard
o.scrolloff = 16                       -- keep the cursor away from the screen edge
o.sidescrolloff = 8                    -- the same rule for horizontal scroll
o.wrap = false                         -- do not wrap long lines

-- Files and history
o.undofile = true                      -- persistent undo across sessions
o.swapfile = false                     -- no swap files; undofile covers recovery
o.confirm = true                       -- ask to save instead of failing the command

-- Splits and UI
o.splitright = true                    -- vertical splits open on the right
o.splitbelow = true                    -- horizontal splits open below
o.termguicolors = true                 -- 24-bit color, needed by the theme
o.winborder = 'rounded'                -- rounded borders on floating windows
o.mouse = 'a'                          -- mouse works in all modes
o.updatetime = 250                     -- faster diagnostics and git signs
o.timeoutlen = 400                     -- wait 400ms for a key chord
o.completeopt = 'menu,menuone,noselect'
o.list = true                          -- show invisible characters
o.listchars = { tab = '» ', trail = '·', nbsp = '␣' }
