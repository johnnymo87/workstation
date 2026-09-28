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
vim.keymap.set("n", "<leader>fs", function()
  if vim.fn.executable("oc-session-list") == 0 then
    vim.notify("session switcher unavailable on this host", vim.log.levels.WARN)
    return
  end
  require("user.session_switcher").open()
end, { desc = "OC sessions" })

-- Stall-watch programs picker (workstation-p8ch). Registered ONLY when the
-- private read command is executable on this host: unlike <leader>fs, which is
-- always bound and explains itself, a host without the stall-watcher gets no
-- key at all (design: "the keymap is registered only if the command is
-- executable"). Checked once, at startup; set $STALLWATCH_ITEMS_CMD to point
-- it elsewhere.
do
  local ok, sw_source = pcall(require, "user.stallwatch_picker.source")
  if ok and sw_source.available() then
    vim.keymap.set("n", "<leader>fp", function()
      require("user.stallwatch_picker").open()
    end, { desc = "Stall-watch programs" })
  end
end

require("telescope").load_extension("fzy_native")