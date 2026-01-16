-- Use OSC 52 for clipboard (works over SSH)
vim.g.clipboard = "osc52"

-- Sync unnamed register with system clipboard (so yy goes to clipboard)
vim.opt.clipboard = "unnamedplus"
