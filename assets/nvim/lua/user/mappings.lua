-- Helper: only bind mapping if command exists (for plugin-dependent mappings)
local function map_if_cmd(cmd, mode, lhs, rhs, opts)
  if vim.fn.exists(":" .. cmd) == 2 then
    vim.keymap.set(mode, lhs, rhs, opts)
  end
end

-- Terminal mode: Ctrl-W a to escape back to normal mode
vim.keymap.set("t", "<C-w>a", [[<C-\><C-n>]], { noremap = true, silent = true })

-- Strip trailing whitespace
vim.keymap.set("n", "<leader>s", [[:%s/\s\+$//e<CR>]], { noremap = true, silent = true, desc = "Strip trailing whitespace" })

-- Copy current file's absolute path to clipboard
vim.keymap.set("n", "<leader>cp", function()
  vim.fn.setreg("+", vim.fn.expand("%:p"))
end, { noremap = true, desc = "Copy file path to clipboard" })

-- Plugin-dependent mappings (only bind if plugin is loaded)
map_if_cmd("Rg", "n", "<leader>rr", ":Rg ''<left>", { noremap = true, desc = "Ripgrep search" })
map_if_cmd("Git", "n", "<leader>gg", ":Git ", { noremap = true, desc = "Git (Fugitive)" })
