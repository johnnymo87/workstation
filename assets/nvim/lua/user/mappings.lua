-- Terminal mode: Ctrl-W a to escape back to normal mode
vim.keymap.set("t", "<C-w>a", [[<C-\><C-n>]], { noremap = true, silent = true })
