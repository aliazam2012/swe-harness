-- Keymaps that need no plugin. Plugin keymaps live with their plugin spec.
-- Leader is space. Press <leader> and wait to see the which-key menu.

local map = vim.keymap.set

-- Clear the search highlight
map('n', '<Esc>', '<cmd>nohlsearch<CR>', { desc = 'Clear search highlight' })

-- Files
map('n', '<leader>w', '<cmd>write<CR>', { desc = 'Write file' })
map('n', '<leader>q', '<cmd>quit<CR>', { desc = 'Quit window' })
map('n', '<leader>Q', '<cmd>qall<CR>', { desc = 'Quit all' })

-- Window navigation
map('n', '<C-h>', '<C-w>h', { desc = 'Go to the left window' })
map('n', '<C-j>', '<C-w>j', { desc = 'Go to the lower window' })
map('n', '<C-k>', '<C-w>k', { desc = 'Go to the upper window' })
map('n', '<C-l>', '<C-w>l', { desc = 'Go to the right window' })

-- Buffers
map('n', '<S-h>', '<cmd>bprevious<CR>', { desc = 'Previous buffer' })
map('n', '<S-l>', '<cmd>bnext<CR>', { desc = 'Next buffer' })
map('n', '<leader>bd', '<cmd>bdelete<CR>', { desc = 'Delete buffer' })

-- Move the selected lines up or down
map('v', 'J', ":m '>+1<CR>gv=gv", { desc = 'Move selection down' })
map('v', 'K', ":m '<-2<CR>gv=gv", { desc = 'Move selection up' })

-- Keep the selection after an indent
map('v', '<', '<gv', { desc = 'Indent left and keep selection' })
map('v', '>', '>gv', { desc = 'Indent right and keep selection' })

-- Paste over a selection without losing the yank register
map('v', 'p', '"_dP', { desc = 'Paste without yanking the replaced text' })

-- Diagnostics
map('n', '<leader>e', vim.diagnostic.open_float, { desc = 'Show the diagnostic under the cursor' })
map('n', '<leader>xx', vim.diagnostic.setloclist, { desc = 'Diagnostics to the location list' })

-- Terminal: escape to normal mode
map('t', '<C-\\>', '<C-\\><C-n>', { desc = 'Leave terminal insert mode' })

-- Quickfix
map('n', '[q', '<cmd>cprevious<CR>', { desc = 'Previous quickfix item' })
map('n', ']q', '<cmd>cnext<CR>', { desc = 'Next quickfix item' })
