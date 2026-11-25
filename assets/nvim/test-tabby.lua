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

-- 8. stall-watch coordinator goose tabs: strip leading `stallwatch-` and trailing `-<digits>`
check(tabby.session_label("stallwatch-honk-1792619184012", "goose:20261021_40") == "honk", "coordinator single-word program")
check(tabby.session_label("stallwatch-foo-alerts-1792501106112", "goose:20261020_3") == "foo-alerts", "coordinator hyphenated program")
check(tabby.session_label("stallwatch-my-cool-prog-123", "goose:1_1") == "my-cool-prog", "coordinator multi-hyphen program")
check(tabby.session_label("stallwatch-v2-1792619184012", "goose:1_1") == "v2", "coordinator program containing digits")
check(tabby.session_label("stallwatch-2026-1792619184012", "goose:1_1") == "2026", "coordinator numeric program")

-- 9. non-coordinator titles must remain unchanged
check(tabby.session_label("fix-pr-12345", "goose:1_1") == "fix-pr-12345", "goose title ending in -digits without stallwatch- prefix")
check(tabby.session_label("stallwatch-picker", "goose:1_1") == "stallwatch-picker", "goose title starting with stallwatch- without -digits suffix")
check(tabby.session_label("stallwatch-1792619184012", "goose:1_1") == "stallwatch-1792619184012", "degenerate stallwatch-<digits> with no program name")
check(tabby.session_label("stallwatch--12345", "goose:1_1") == "stallwatch--12345", "degenerate stallwatch--<digits> with empty program name")
check(tabby.session_label("OC | stallwatch-honk-1792619184012", "ses_123") == "stallwatch-honk-1792619184012", "opencode OC title is not stripped")
check(tabby.session_label("stallwatch-honk-1792619184012", nil) == nil, "non-goose buffer with coordinator-like title -> nil")

print("LUA_TEST_OK " .. N)
