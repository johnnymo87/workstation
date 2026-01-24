-- Leader key (set early, before mappings and plugins)
vim.g.mapleader = ","
vim.g.maplocalleader = " "

-- Clipboard: use system clipboard
-- On SSH sessions, force OSC 52 provider for clipboard over terminal
if vim.env.SSH_TTY then
  vim.g.clipboard = "osc52"
end
vim.opt.clipboard = "unnamedplus"

-- Display
vim.opt.list = true
vim.opt.listchars = "tab:▷▷⋮,trail:·"
vim.opt.number = true
vim.opt.relativenumber = true
vim.opt.termguicolors = true
vim.opt.colorcolumn = "80,121"
vim.cmd("highlight ColorColumn ctermbg=235 guibg=#2c2d27")

-- Folding (treesitter-based)
vim.opt.foldmethod = "expr"
vim.opt.foldexpr = "nvim_treesitter#foldexpr()"
vim.opt.foldenable = false

-- Search
vim.opt.ignorecase = true
vim.opt.hlsearch = true
vim.opt.incsearch = true

-- Don't wrap lines
vim.opt.wrap = false

-- No swap/backup files
vim.opt.swapfile = false
vim.opt.backup = false
vim.opt.writebackup = false

-- Require save before switching buffers
vim.opt.hidden = false

-- Indentation
vim.opt.expandtab = true
vim.opt.copyindent = true
vim.opt.preserveindent = true
vim.opt.shiftwidth = 2
vim.opt.softtabstop = 2
vim.opt.tabstop = 2

-- netrw (built-in file explorer)
vim.g.netrw_keepj = ""
