-- Treesitter configuration (grammars provided by nix, no runtime install)
require("nvim-treesitter.configs").setup({
  auto_install = false,
  highlight = {
    enable = true,
    additional_vim_regex_highlighting = false,
  },
  incremental_selection = {
    enable = true,
  },
  indent = {
    enable = true,
  },
})

-- Telescope configuration
require("telescope").setup({
  defaults = {
    mappings = {
      i = {
        ["<C-n>"] = "cycle_history_next",
        ["<C-p>"] = "cycle_history_prev",
        ["<C-j>"] = "move_selection_next",
        ["<C-k>"] = "move_selection_previous",
      },
    },
  },
})

local builtin = require("telescope.builtin")
vim.keymap.set("n", "<leader>ff", function() builtin.find_files({ hidden = true }) end, { desc = "Find files" })
vim.keymap.set("n", "<leader>fg", builtin.live_grep, { desc = "Live grep" })
vim.keymap.set("n", "<leader>fG", builtin.grep_string, { desc = "Grep string under cursor" })
vim.keymap.set("n", "<leader>fb", builtin.buffers, { desc = "Buffers" })
vim.keymap.set("n", "<leader>fh", builtin.help_tags, { desc = "Help tags" })

require("telescope").load_extension("fzy_native")