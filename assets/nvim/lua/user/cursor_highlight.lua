-- Toggle cursor line and column highlighting to quickly find the cursor.
-- Inspired by https://vim.fandom.com/wiki/Highlight_current_line

local function toggle_cursor_highlight()
    local cursorline = vim.wo.cursorline
    local cursorcolumn = vim.wo.cursorcolumn

    vim.wo.cursorline = not cursorline
    vim.wo.cursorcolumn = not cursorcolumn

    local highlight_group_settings = {
        CursorLine = { bg = 'DarkRed', fg = 'White' },
        CursorColumn = { bg = 'DarkRed', fg = 'White' }
    }

    for group, settings in pairs(highlight_group_settings) do
        vim.api.nvim_set_hl(0, group, settings)
    end
end

vim.api.nvim_set_keymap('n', '<C-K>', '', {
    noremap = true,
    silent = true,
    callback = toggle_cursor_highlight
})