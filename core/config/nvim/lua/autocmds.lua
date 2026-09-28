-- Autocommands. No plugins are needed for anything in this file.

local augroup = function(name)
  return vim.api.nvim_create_augroup('harness_' .. name, { clear = true })
end

-- Flash the text I just yanked, so I can see what was copied
vim.api.nvim_create_autocmd('TextYankPost', {
  group = augroup('highlight_yank'),
  callback = function() vim.hl.on_yank() end,
})

-- Return to the last cursor position when reopening a file
vim.api.nvim_create_autocmd('BufReadPost', {
  group = augroup('last_position'),
  callback = function(event)
    local mark = vim.api.nvim_buf_get_mark(event.buf, '"')
    local line_count = vim.api.nvim_buf_line_count(event.buf)
    if mark[1] > 0 and mark[1] <= line_count then
      pcall(vim.api.nvim_win_set_cursor, 0, mark)
    end
  end,
})

-- Four-space indent for the languages that require it
vim.api.nvim_create_autocmd('FileType', {
  group = augroup('indent_four'),
  pattern = { 'python', 'go', 'rust', 'java', 'c', 'cpp' },
  callback = function()
    vim.bo.shiftwidth = 4
    vim.bo.tabstop = 4
    vim.bo.softtabstop = 4
  end,
})

-- No line numbers in a terminal buffer
vim.api.nvim_create_autocmd('TermOpen', {
  group = augroup('terminal'),
  callback = function()
    vim.wo.number = false
    vim.wo.relativenumber = false
    vim.wo.signcolumn = 'no'
  end,
})

-- q closes these read-only windows
vim.api.nvim_create_autocmd('FileType', {
  group = augroup('close_with_q'),
  pattern = { 'help', 'qf', 'man', 'checkhealth', 'lspinfo', 'gitsigns-blame' },
  callback = function(event)
    vim.bo[event.buf].buflisted = false
    vim.keymap.set('n', 'q', '<cmd>close<CR>', { buffer = event.buf, silent = true })
  end,
})

-- Warn me before I write a file with trailing whitespace in a shared repo
vim.api.nvim_create_autocmd('BufWritePre', {
  group = augroup('trim_whitespace'),
  callback = function()
    if vim.bo.filetype == 'markdown' then return end -- two trailing spaces mean a line break
    local view = vim.fn.winsaveview()
    vim.cmd([[keeppatterns %s/\s\+$//e]])
    vim.fn.winrestview(view)
  end,
})
