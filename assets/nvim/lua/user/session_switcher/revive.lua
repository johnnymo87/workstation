-- session_switcher/revive.lua
--
-- Pure validation and prompt text for the picker's one-keypress revive
-- (workstation-6lnw.7). Turns an `oc-revive plan` result into a list of OFFERS,
-- each carrying the exact argv the floating terminal will run, and renders the
-- vim.fn.confirm message and buttons for them.
--
-- PURE: no vim.system, vim.fn, vim.api or vim.notify. exec.lua owns every side
-- effect; this module only decides what to show and what argv to hand over.
--
-- LUA NEVER COMPUTES A PATH. oc-revive chose the path, and apply re-checks
-- everything under its lock. This module only REJECTS: any field that fails
-- validation makes the whole plan unusable, and the caller stays silent exactly
-- as it does for a plan that failed to parse. A partly-valid plan is not offered,
-- because offering only the valid half would hide the disagreement the human is
-- meant to see.

local M = {}

M.TITLE_MAX = 60
M.SUBJECT_MAX = 72

local function is_str(v)
  return type(v) == "string" and v ~= ""
end

--- Replace control characters and truncate, for text shown in the prompt.
--- @param s any
--- @param max integer
--- @return string|nil
function M.display(s, max)
  if type(s) ~= "string" then
    return nil
  end
  local out = s:gsub("%c", " ")
  if #out > max then
    out = out:sub(1, max - 3) .. "..."
  end
  return out
end

--- A branch becomes an argv VALUE (`--branch <b>`), so a leading "-" would be
--- parsed by argparse as an option. Whitespace, control characters and
--- backticks have no business in a ref name the human is asked to confirm.
function M.valid_branch(b)
  return is_str(b) and b:find("[%s%c`]") == nil and b:sub(1, 1) ~= "-"
end

local function valid_full_sha(s)
  return type(s) == "string" and (#s == 40 or #s == 64) and s:match("^%x+$") ~= nil
end

--- The path must be EXACTLY <repo>/.worktrees/<one component>, and not the dead dir.
--- @return boolean
function M.valid_path(path, repo, dead_dir)
  if not is_str(path) or not is_str(repo) or path:find("%c") then
    return false
  end
  if repo:sub(1, 1) ~= "/" or repo:find("%c") then
    return false
  end
  local prefix = repo:gsub("/+$", "") .. "/.worktrees/"
  if path:sub(1, #prefix) ~= prefix then
    return false
  end
  local leaf = path:sub(#prefix + 1)
  if leaf == "" or leaf == "." or leaf == ".." or leaf:find("/", 1, true) or leaf:sub(1, 1) == "-" then
    return false
  end
  return path ~= dead_dir
end

local function valid_sid(sid)
  return type(sid) == "string" and sid:match("^ses_[%w]+$") ~= nil
end

--- Validate a decoded plan and build the offers.
---
--- @param plan any decoded `oc-revive plan` JSON
--- @param sid string the row's session id
--- @param dead_dir string the row's (missing) directory
--- @return table|nil result { kind = "revive"|"resume", offers = { {branch, path, tip_short, subject?, date?, merged, source, argv} } }
function M.offers(plan, sid, dead_dir)
  if type(plan) ~= "table" or not valid_sid(sid) or plan.sid ~= sid then
    return nil
  end
  if not is_str(dead_dir) or plan.dead_dir ~= dead_dir then
    return nil
  end
  local repo = plan.repo
  if not is_str(repo) then
    return nil
  end

  if plan.revivable == true then
    if type(plan.candidates) ~= "table" or #plan.candidates == 0 then
      return nil
    end
    local offers = {}
    for _, c in ipairs(plan.candidates) do
      if type(c) ~= "table"
        or not M.valid_branch(c.branch)
        or not valid_full_sha(c.tip)
        or type(c.tip_short) ~= "string" or c.tip_short:match("^%x+$") == nil
        or type(c.source) ~= "string" or c.source:match("^[%w%-]+$") == nil
        or c.action ~= "add"
        or not M.valid_path(c.path, repo, dead_dir)
      then
        return nil
      end
      local date = type(c.tip_ct) == "string" and c.tip_ct:match("^(%d%d%d%d%-%d%d%-%d%d)") or nil
      table.insert(offers, {
        branch = c.branch,
        path = c.path,
        tip_short = c.tip_short,
        source = c.source,
        subject = M.display(c.subject, M.SUBJECT_MAX),
        date = date,
        merged = c.merged == true,
        argv = {
          "oc-revive", "apply", sid,
          "--branch", c.branch,
          "--path", c.path,
          "--action", "add",
          "--expect-tip", c.tip,
          "--expect-old-dir", dead_dir,
        },
      })
    end
    return { kind = "revive", offers = offers, repo = repo }
  end

  -- Blocked by an earlier revive that created the worktree but never finished.
  -- A PREFIX token, never a match anywhere in the prose; and only the structured
  -- `resume` object is used -- the prose command is never parsed.
  if type(plan.reason) == "string" and plan.reason:find("blocked_by_worktree:", 1, true) == 1 then
    local r = plan.resume
    if type(r) ~= "table"
      or not M.valid_branch(r.branch)
      or not valid_full_sha(r.expect_tip)
      or r.expect_old_dir ~= dead_dir
      or not M.valid_path(r.path, repo, dead_dir)
    then
      return nil
    end
    return {
      kind = "resume",
      repo = repo,
      offers = {
        {
          branch = r.branch,
          path = r.path,
          tip_short = r.expect_tip:sub(1, 9),
          merged = false,
          argv = {
            "oc-revive", "resume", sid,
            "--branch", r.branch,
            "--path", r.path,
            "--expect-tip", r.expect_tip,
            "--expect-old-dir", dead_dir,
          },
        },
      },
    }
  end

  return nil
end

local function rel(path, repo)
  local prefix = repo:gsub("/+$", "") .. "/"
  if path:sub(1, #prefix) == prefix then
    return path:sub(#prefix + 1)
  end
  return path
end

local function button(label)
  -- "&&" is a literal "&" in a confirm choice; a single one would make the
  -- following character an accelerator.
  return (label:gsub("&", "&&"))
end

local function describe(o)
  local s = string.format("branch %s @ %s", o.branch, o.tip_short)
  if o.subject and o.subject ~= "" then
    s = s .. " - " .. o.subject
  end
  if o.date then
    s = s .. " (" .. o.date .. ")"
  end
  return s
end

--- Render the confirm prompt.
---
--- @param result table from M.offers
--- @param title string|nil session title (falls back to sid)
--- @param sid string
--- @return string message, string choices, integer default (always Cancel)
function M.prompt(result, title, sid)
  local name = M.display(title, M.TITLE_MAX) or sid
  if name == "" then
    name = sid
  end
  local offers = result.offers
  local lines = {}
  local choices = {}

  if result.kind == "resume" then
    local o = offers[1]
    table.insert(lines, string.format('Resume the unfinished revive of "%s"?', name))
    table.insert(lines, "  " .. describe(o))
    table.insert(lines, "  worktree " .. rel(o.path, result.repo) .. " (made by an earlier attempt that did not finish)")
    table.insert(choices, "&Resume")
  elseif #offers == 1 then
    local o = offers[1]
    table.insert(lines, string.format('Revive read-only session "%s"?', name))
    table.insert(lines, "  " .. describe(o))
    table.insert(lines, "  new dir " .. rel(o.path, result.repo))
    if o.merged then
      table.insert(lines, "  ! branch already merged: the worktree is swept ~7 days after the session goes idle")
    end
    table.insert(choices, "&Revive")
  else
    table.insert(lines, string.format('Revive read-only session "%s"? The branch evidence disagrees; pick one:', name))
    local same_path = true
    for _, o in ipairs(offers) do
      same_path = same_path and o.path == offers[1].path
    end
    for i, o in ipairs(offers) do
      local where = same_path and "" or (", new dir " .. rel(o.path, result.repo))
      table.insert(lines, string.format("  [%d] %s [%s]%s%s", i, describe(o), o.source, o.merged and " (merged)" or "", where))
      table.insert(choices, string.format("&%d %s", i, button(o.branch)))
    end
    if same_path then
      table.insert(lines, "  new dir " .. rel(offers[1].path, result.repo))
    end
    for _, o in ipairs(offers) do
      if o.merged then
        table.insert(lines, "  ! a merged branch's worktree is swept ~7 days after the session goes idle")
        break
      end
    end
  end

  if result.kind ~= "resume" then
    table.insert(lines, "  Uncommitted files are NOT carried over.")
  end
  table.insert(choices, "&Cancel")
  return table.concat(lines, "\n"), table.concat(choices, "\n"), #choices
end

return M
