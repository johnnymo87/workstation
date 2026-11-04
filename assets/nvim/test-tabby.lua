-- Unit tests for tabby.lua (tab label extraction).
-- Driven via `nvim --clean -l assets/nvim/test-tabby.lua`.

local N = 0
local function check(cond, msg) N = N + 1; assert(cond, msg) end

-- Guard: tabby.lua calls M.setup() at load and pcall-requires "tabby".
-- Preload a stub so require("tabby") fails cleanly and M.setup() returns early
-- without side effects (timers, autocmds, highlights).
package.loaded["tabby"] = nil
package.preload["tabby"] = function() error("tabby stubbed for test") end

local tabby = loadfile("assets/nvim/lua/user/tabby.lua")()

-- 1. OC prefix -> captures session name
check(tabby.session_label("OC | my-session", nil) == "my-session", "OC prefix with nil oc_session_id")
check(tabby.session_label("OC | feature-work", "ses_123") == "feature-work", "OC prefix with opencode session id")

-- 2. "OpenCode" -> "OpenCode"
check(tabby.session_label("OpenCode", nil) == "OpenCode", "OpenCode with nil oc_session_id")
check(tabby.session_label("OpenCode", "ses_123") == "OpenCode", "OpenCode with opencode session id")

-- 3. goose buffer with title -> term_title
check(tabby.session_label("my-goose-title", "goose:12345") == "my-goose-title", "goose buffer with title")
check(tabby.session_label("20261104_1", "goose:20261104_1") == "20261104_1", "goose buffer untitled (session id as title)")
check(tabby.session_label("term:///d//1:/nix/store/x/bin/honk chat 1_1", "goose:1_1") == nil, "goose buffer with seeded term:// URI -> nil")

-- 4. goose buffer with empty title -> nil
check(tabby.session_label("", "goose:12345") == nil, "goose buffer with empty string title")
check(tabby.session_label(nil, "goose:12345") == nil, "goose buffer with nil title")

-- 5. non-goose buffer with arbitrary title (e.g. "bash") -> nil
check(tabby.session_label("bash", nil) == nil, "non-goose buffer (nil oc_session_id) with arbitrary title")
check(tabby.session_label("zsh", "other:123") == nil, "non-goose buffer (unknown prefix) with arbitrary title")

-- 6. nil oc_session_id -> nil
check(tabby.session_label("random-proc", nil) == nil, "nil oc_session_id with random title")
check(tabby.session_label("", nil) == nil, "nil oc_session_id with empty title")
check(tabby.session_label(nil, nil) == nil, "nil oc_session_id with nil title")

-- 7. opencode `ses_` oc_session_id with arbitrary title -> nil
check(tabby.session_label("bash", "ses_xyz") == nil, "opencode ses_ oc_session_id with arbitrary title bash")
check(tabby.session_label("node", "ses_123") == nil, "opencode ses_ oc_session_id with arbitrary title node")

print("LUA_TEST_OK " .. N)
