-- Auto-start vim-obsession in project directories for tmux-resurrect integration
-- tmux-resurrect's @resurrect-strategy-nvim 'session' expects Session.vim in cwd
--
-- How it works:
-- 1. On VimEnter, check if we're in a "project" directory (has .git, flake.nix, etc.)
-- 2. If so, start Obsession to continuously save Session.vim
-- 3. tmux-resurrect will restore nvim with `nvim -S` using this file

local uv = vim.uv or vim.loop

-- Check if a file/directory exists
local function exists(path)
  return uv.fs_stat(path) ~= nil
end

-- Check if directory looks like a project root
local function is_project_dir(dir)
  local markers = {
    ".git",
    "flake.nix",
    "Cargo.toml",
    "go.mod",
    "package.json",
    "pyproject.toml",
    "Makefile",
  }
  for _, marker in ipairs(markers) do
    if exists(dir .. "/" .. marker) then
      return true
    end
  end
  return false
end

-- Decide whether to auto-start session recording
local function should_record_session()
  local dir = vim.fn.getcwd()

  -- Don't litter home or root with Session.vim
  if dir == vim.env.HOME or dir == "/" then
    return false
  end

  -- Need write permission to create Session.vim
  if vim.fn.filewritable(dir) ~= 2 then
    return false
  end

  -- Only record in project directories
  return is_project_dir(dir)
end

-- Auto-start Obsession on VimEnter in project directories
vim.api.nvim_create_autocmd("VimEnter", {
  group = vim.api.nvim_create_augroup("SessionsAutoStart", { clear = true }),
  callback = function()
    -- Skip if opened with arguments (e.g., nvim file.txt) - let user decide
    if vim.fn.argc() > 0 then
      return
    end

    if should_record_session() then
      -- Start recording to Session.vim in current directory
      -- silent! suppresses errors if Obsession isn't loaded
      vim.cmd("silent! Obsess")
    end
  end,
})
