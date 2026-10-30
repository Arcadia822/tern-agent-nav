--!strict
-- Agent Navigations: one agent list per window that follows the shown tab as a
-- full-height rail on the left or right edge, at a remembered share of the tab.
--
-- Placement follows Overseer's Projects panel pattern: Tern panes belong to one tab,
-- so the window keeps a single canvas and moves it into whichever tab is shown.
-- cx.layout:move only splits beside a leaf, so the destination's content is
-- rebuilt around the rail (one move per split, original ratios restored) until
-- the rail is the root split's outer child.

local ui = tern.ui

local TITLE = "Agent Navigations"
local ABOUT = "Agents across Tern sessions. Click a row to switch to its session and focus it."
local TICK_MS = 750
local DEFAULT_SHARE = 0.2
local MIN_SHARE, MAX_SHARE = 0.08, 0.6
-- First guess of a tab's width in cells; each resize then corrects by what it moved.
local CELLS_GUESS = 180

local KV_ENABLED = "agent_nav.enabled"
local KV_SIDE = "agent_nav.side"
local KV_SHARE = "agent_nav.share"
local KV_LAUNCH_UI = "agent_nav.launch_ui"

-- Clean up settings from obsolete layouts.
for _, key in { "agent_nav.width", "agent_nav.auto_tabs", "agent_nav.omp_debug", "agent_nav.panes_dump", "agent_nav.test_ping" } do
	if tern.kv.get(key) ~= nil then
		tern.kv.set(key, nil)
	end
end

local HARNESS_ICONS: { [string]: string } = {
	omp = "app-omp",
	hermes = "app-hermes",
	claude = "mi-claude",
	["claude-code"] = "mi-claude",
	["claude-code-acp"] = "mi-claude",
	codex = "provider-openai",
	["codex-acp"] = "provider-openai",
	copilot = "mi-copilot",
	["copilot-acp"] = "mi-copilot",
	gemini = "mi-gemini-ai",
	["gemini-cli"] = "mi-gemini-ai",
	cursor = "mi-cursor",
	opencode = "mi-code",
	kimi = "sparkle",
	kilo = "sparkle",
	carly = "sparkle",
}

-- Tern registers these ids before their ACP adapters are installed.
local BUILTIN_AGENTS: { { id: string, label: string } } = {
	{ id = "claude", label = "Claude Code" },
	{ id = "codex", label = "Codex" },
	{ id = "copilot", label = "GitHub Copilot" },
}

type Side = "left" | "right"

type AgentRow = {
	pane: number,
	session: number,
	title: string,
	icon: string,
	status: string,
	is_current: boolean,
}

type Badge = { kind: "icon", name: string } | { kind: "letter", text: string }
type LaunchUI = "tui" | "chat"
type Harness = { id: string, label: string, badge: Badge, tui: string?, chat: string }
type Menu = { session: number, items: { Harness } }
type Action = { pattern: string, run: (cx: WindowCx, session: number, arg: string?) -> boolean }

--------------------------------------------------------------------------------
-- Settings & State
--------------------------------------------------------------------------------

local wantPanel = tern.kv.get(KV_ENABLED) == true

local function setWantPanel(want: boolean)
	wantPanel = want
	tern.kv.set(KV_ENABLED, want)
end

local function side(): Side
	return if tern.kv.get(KV_SIDE) == "left" then "left" else "right"
end

local function clampShare(v: number): number
	return math.clamp(v, MIN_SHARE, MAX_SHARE)
end

local function storedShare(): number
	local v = tonumber(tern.kv.get(KV_SHARE))
	return if v then clampShare(v) else DEFAULT_SHARE
end

--------------------------------------------------------------------------------
-- Split Tree Helpers (cx.session:layout(tab).root)
--------------------------------------------------------------------------------

local function firstLeaf(t: any): number
	if t.pane then
		return t.pane
	end
	return firstLeaf(t[1])
end

-- Return the tree without `pane`; its parent split collapses into the sibling.
local function strip(t: any, pane: number): any?
	if not t then
		return nil
	end
	if t.pane then
		return if t.pane == pane then nil else t
	end
	local a, b = strip(t[1], pane), strip(t[2], pane)
	if not a then
		return b
	end
	if not b then
		return a
	end
	return { split = t.split, ratio = t.ratio, [1] = a, [2] = b }
end

-- Find the leaf of `t` touching its far edge toward `dir`.
local function edgeLeaf(t: any, dir: string): number
	if t.pane then
		return t.pane
	end
	return edgeLeaf(if t.split == dir then t[2] else t[1], dir)
end

local function nodeAt(t: any, path: { number }): any?
	for _, i in path do
		if not t or t.pane then
			return nil
		end
		t = t[i]
	end
	return t
end

-- Return the rail's share of the tab when it is the root split's outer child on `s`.
local function railShare(root: any, pane: number, s: Side): number?
	if not root or root.split ~= "right" then
		return nil
	end
	local ratio = root.ratio or 0.5
	if s == "left" and root[1] and root[1].pane == pane then
		return ratio
	end
	if s == "right" and root[2] and root[2].pane == pane then
		return 1 - ratio
	end
	return nil
end

type Op = { pane: number, target: number, dir: Dir }
type Fit = { path: { number }, ratio: number, edge: number, dir: Dir }

-- Compute moves to leave `content` intact with the rail as the root's `s` child.
local function rebuild(content: any, rail: number, s: Side): ({ Op }, { Fit })
	local ops: { Op } = { { pane = rail, target = firstLeaf(content), dir = s } }
	local fits: { Fit } = {}
	local path: { number } = {}
	local function walk(node: any)
		if node.pane then
			return
		end
		local dir: Dir = if node.split == "down" then "down" else "right"
		table.insert(ops, { pane = firstLeaf(node[2]), target = firstLeaf(node[1]), dir = dir })
		table.insert(fits, { path = table.clone(path), ratio = node.ratio or 0.5, edge = edgeLeaf(node[1], dir), dir = dir })
		for i = 1, 2 do
			table.insert(path, i)
			walk(node[i])
			table.remove(path)
		end
	end
	walk(content)
	return ops, fits
end

-- Resize iteratively toward target ratio using observed step corrections.
local function steer(read: () -> number?, push: (cells: number) -> boolean, want: number)
	local r = read()
	if not r then
		return
	end
	local step = math.floor((want - r) * CELLS_GUESS + 0.5)
	for _ = 1, 8 do
		if math.abs(r - want) < 0.004 or step == 0 then
			return
		end
		if not push(step) then
			return
		end
		local after = read()
		if not after or after == r then
			return
		end
		step = math.floor((want - after) * step / (after - r) + 0.5)
		r = after
	end
end

--------------------------------------------------------------------------------
-- The Panel & State Tracking
--------------------------------------------------------------------------------

local slotPane: number? = nil
local panelTab: number? = nil
local placedSide: Side? = nil
local appliedShare: number? = nil
local share = storedShare()
local busy = false
local warnedIds = false
-- Ratio restore and rail sizing are spread across ticks: a full rebuild with
-- 8-step steering per split inside one hook overran Tern's 50 ms plugin
-- budget, and Tern then disables the hook until reload, which freezes the
-- panel on stale state.
local pendingFits: { Fit } = {}
local pendingSize = false
local pendingTab: number? = nil

-- Persistent state tracking across ticks/events:
local wasRunning: { [number]: boolean } = {}
local unreadPanes: { [number]: boolean } = {}
-- Authoritative agent-block states from cx.agents:list(). Kept across ticks:
-- a failed or oversized list response (daemon frame limit) must degrade to the
-- last known state, not drop every native agent onto screen heuristics.
local agentStates: { [number]: string } = {}
-- Cached screen-state probes. Reading every navigable pane every tick overran
-- Tern's 50 ms plugin hook budget (the hook is then disabled until reload and
-- the panel freezes on stale state), so reads are cached per pane, refreshed
-- immediately when a cheap signal (title, busy, prompt, alert) changes, and
-- otherwise staggered: at most SCREEN_READS_PER_TICK fresh reads per render,
-- with each entry re-read at latest after SCREEN_TTL_TICKS.
local screenCache: { [number]: { sig: string, state: ("ask" | "working")?, tick: number } } = {}
local SCREEN_TTL_TICKS = 8
local SCREEN_READS_PER_TICK = 2
local tickCounter = 0
local screenBudget = 0

-- The open harness menu; its items are built when it opens, so rendering never
-- reads settings or the filesystem.
local menu: Menu? = nil

local function slot(cx: WindowCx): number?
	if slotPane and not cx.session:pane(slotPane) then
		slotPane = nil
	end
	local found: { number } = {}
	for _, c in cx.canvas:list() do
		if c.owner == tern.plugin.id and c.title == TITLE then
			table.insert(found, c.pane)
		end
	end
	slotPane = slotPane or found[1]
	for _, pane in found do
		if pane ~= slotPane then
			cx.layout:close(pane)
		end
	end
	return slotPane
end

local function shownTab(cx: WindowCx): number?
	local focused = cx.session:focused()
	return focused and cx.session:tab_of(focused)
end

local function localHost(cx: WindowCx): boolean
	return cx.hosts:current().kind == "local"
end

local function readRail(cx: WindowCx, tab: number, pane: number, s: Side): number?
	local l = cx.session:layout(tab)
	return l and railShare(l.root, pane, s)
end

local function sizeRail(cx: WindowCx, tab: number, pane: number, s: Side, want: number)
	local toward: Dir = if s == "left" then "right" else "left"
	steer(function()
		return readRail(cx, tab, pane, s)
	end, function(cells)
		return cx.layout:resize(pane, toward, cells)
	end, want)
	appliedShare = readRail(cx, tab, pane, s)
end

-- Save manual divider adjustments made by the user.
local function noteDrag(cx: WindowCx, tab: number, pane: number)
	if not placedSide or not appliedShare then
		return
	end
	local current = readRail(cx, tab, pane, placedSide)
	if current and math.abs(current - appliedShare) > 0.005 then
		share = clampShare(current)
		appliedShare = current
		tern.kv.set(KV_SHARE, share)
	end
end

-- Mount the panel in `tab` as the outer rail on the active side.
local function pin(cx: WindowCx, tab: number)
	local pane = slot(cx)
	if not pane then
		return
	end
	local layout = cx.session:layout(tab)
	if not layout then
		return
	end
	local from = cx.session:tab_of(pane)
	local s = side()

	if from then
		noteDrag(cx, from, pane)
	end

	-- Check if panel is already in target tab and correctly placed on side s.
	if from == tab and railShare(layout.root, pane, s) then
		panelTab, placedSide = tab, s
		-- If not yet sized (e.g. freshly opened with default 50% split), size now.
		if not appliedShare then
			sizeRail(cx, tab, pane, s, share)
		end
		return
	end

	local content = strip(layout.root, pane)
	if not content then
		-- Alone in tab: park so the tab closes cleanly.
		cx.layout:park(pane)
		return
	end

	if from ~= tab then
		if from then
			cx.layout:move_to_tab(pane, tab, { focus = false })
		else
			cx.layout:unpark(pane, { focus = false })
		end
	end
	local ops, fits = rebuild(content, pane, s)
	for _, op in ops do
		cx.layout:move(op.pane, op.target, op.dir, { focus = false })
	end

	-- Restore original content split ratios and the rail width across ticks
	-- (settle below): steering every split inside this one hook overran the
	-- 50 ms budget and Tern disabled the hook, freezing the panel.
	pendingFits = fits
	pendingSize = true
	pendingTab = tab
	panelTab, placedSide = tab, s
end

-- Work through the pending ratio restores a couple per tick, then size the
-- rail. Abandoned when the panel moved again meanwhile (pin re-plans).
local function settle(cx: WindowCx)
	if not pendingTab then
		return
	end
	local pane = slot(cx)
	local tab = pendingTab
	if not pane or cx.session:tab_of(pane) ~= tab then
		pendingFits, pendingSize, pendingTab = {}, false, nil
		return
	end
	local s = if placedSide then placedSide else "right"
	local contentSide = if s == "left" then 2 else 1
	for _ = 1, 2 do
		local fit = table.remove(pendingFits, 1)
		if not fit then
			break
		end
		local function read(): number?
			local l = cx.session:layout(tab)
			local node = l and l.root and nodeAt(l.root[contentSide], fit.path)
			return if node and not node.pane then node.ratio or 0.5 else nil
		end
		steer(read, function(cells)
			return cx.layout:resize(fit.edge, fit.dir, cells)
		end, fit.ratio)
	end
	if #pendingFits == 0 and pendingSize then
		pendingSize = false
		sizeRail(cx, tab, pane, s, share)
	end
	if #pendingFits == 0 and not pendingSize then
		pendingTab = nil
	end
 end

--------------------------------------------------------------------------------
-- View
--------------------------------------------------------------------------------

-- A pane's foreground program, from `tern process`, for terminal panes whose
-- window metadata no longer carries the command (programs started before this
-- window opened). One lookup per pane and title: every CLI call is a daemon
-- connection, so they are cached rather than repeated on each render.
local foreground: { [number]: { title: string, argv: string } } = {}
local probing: { [number]: boolean } = {}

local function probeForeground(pane_info: any)
	local pane, title = pane_info.pane, pane_info.title or ""
	local known = foreground[pane]
	if probing[pane] or (known and known.title == title) or tern.runtime.os == "ios" then
		return
	end
	probing[pane] = true
	local ok = pcall(function()
		tern.process.run({ "tern", "process", tostring(pane), "--json" }, { timeout_ms = 3000 }, function(r, _cx)
			probing[pane] = nil
			local argv = ""
			if r.status == 0 then
				local okJ, doc = pcall(tern.json.decode, r.stdout)
				local fg = okJ and type(doc) == "table" and doc.foreground
				if type(fg) == "table" and type(fg.argv) == "table" then
					argv = string.lower(table.concat(fg.argv, " "))
				end
			end
			-- The next tick draws the row.
			foreground[pane] = { title = title, argv = argv }
		end)
	end)
	if not ok then
		probing[pane] = nil
	end
end

-- Terminal agents that never report `busy` (Codex) mark a working turn with a
-- braille spinner frame (U+2800..U+28FF) at the start of their title.
local function spinnerTitle(title: string?): (boolean, string?)
	if type(title) ~= "string" then
		return false, title
	end
	local first = utf8.codepoint(title, 1, 1)
	if first and first >= 0x2800 and first <= 0x28FF then
		local rest = string.match(string.sub(title, utf8.offset(title, 2) or (#title + 1)), "^%s*(.-)$")
		return true, rest
	end
	return false, title
end
-- Codex appends a braille spinner frame to its title while a turn runs
-- ("task · dir · ⠼") instead of a leading frame.
local function spinnerTitleSuffix(title: string?): boolean
	if type(title) ~= "string" or title == "" then
		return false
	end
	-- The last character can be multi-byte; codepoint at a continuation byte errors.
	local ok, last = pcall(utf8.codepoint, title, #title)
	return ok and last ~= nil and last >= 0x2800 and last <= 0x28FF
end

-- Terminal agents that report nothing to Tern while they work or wait on the
-- user still draw it on screen: a question picker ends in a key-hint line, a
-- working turn shows a status line. These are the lines seen on real screens.
local ASK_HINTS = {
	"enter accept · tab next · ctrl+d decline", -- GitHub Copilot ask_user
	"enter continue · esc skip", -- Codex update/confirm picker
	"esc to cancel · tab to amend", -- Claude Code tool permission / confirmation
	"do you want to proceed?", -- Claude Code confirmation
}
local WORKING_HINTS = {
	-- GitHub Copilot status line while a turn runs: "◉ Working esc esc edit prompt"
	-- before output streams, "● Working · 95 B esc esc interrupt" after.
	"working esc esc edit prompt",
	"esc esc interrupt",
	"esc to interrupt", -- Claude Code footer while a turn runs
}

local function screenHas(lines: { string }, hints: { string }): boolean
	for _, line in lines do
		local lower = string.lower(line)
		for _, hint in hints do
			if string.find(lower, hint, 1, true) then
				return true
			end
		end
	end
	return false
end

-- What a terminal pane's last screen rows show: "ask" for a question or
-- approval picker, "working" for a running turn, nil otherwise. Reads only
-- the visible screen (no scrollback).
local function screenState(cx: WindowCx, pane: number): ("ask" | "working")?
	local ok, read = pcall(function()
		return cx.session:read(pane, { lines = 8, scrollback = false })
	end)
	if not ok or type(read) ~= "table" or type((read :: any).lines) ~= "table" then
		return nil
	end
	local lines = (read :: any).lines
	if screenHas(lines, ASK_HINTS) then
		return "ask"
	end
	if screenHas(lines, WORKING_HINTS) then
		return "working"
	end
	return nil
end
-- Staggered cache wrapper around screenState: at most SCREEN_READS_PER_TICK
-- fresh reads per render, an immediate refresh when a cheap pane signal
-- changes (title spinner start/stop, busy, prompt, alert), else a re-read at
-- latest after SCREEN_TTL_TICKS. Panes over budget keep their previous state.
local function screenStateCached(cx: WindowCx, p: any): ("ask" | "working")?
	local sig = string.format("%s\1%s\1%s\1%s", tostring(p.title), tostring(p.busy), tostring(p.at_prompt), tostring(p.alert))
	local hit = screenCache[p.pane]
	if hit and hit.sig == sig and tickCounter - hit.tick < SCREEN_TTL_TICKS then
		return hit.state
	end
	if screenBudget <= 0 then
		return if hit then hit.state else nil
	end
	screenBudget -= 1
	local state = screenState(cx, p.pane)
	screenCache[p.pane] = { sig = sig, state = state, tick = tickCounter }
	return state
end

--------------------------------------------------------------------------------
-- Harness actions
--------------------------------------------------------------------------------

-- Harness keys in a fixed order: table iteration order is not, and a menu entry
-- must match exactly like the row it mirrors.
local HARNESS_KEYS: { string } = {}
for key in HARNESS_ICONS do
	table.insert(HARNESS_KEYS, key)
end
table.sort(HARNESS_KEYS)

local function harness_icon(text: string): (string?, string?)
	local lower = string.lower(text)
	if lower == "" then
		return nil, nil
	end
	for _, key in HARNESS_KEYS do
		if string.find(lower, key, 1, true) then
			return key, HARNESS_ICONS[key]
		end
	end
	return nil, nil
end

local function letter_of(name: string): string
	local ok, letter = pcall(function()
		local i = 1
		while i <= #name do
			local cp = utf8.codepoint(name, i)
			if cp > 0x20 then
				return string.upper(utf8.char(cp))
			end
			i = utf8.offset(name, 2, i) or (#name + 1)
		end
		return "?"
	end)
	return if ok and letter then letter else "?"
end

local function shell_quote(text: string): string
	return "'" .. string.gsub(text, "'", "'\\''") .. "'"
end

local function badge_of(id: string, label: string): Badge
	for _, source in { id, label } do
		local _, icon = harness_icon(source)
		if icon then
			return { kind = "icon", name = icon }
		end
	end
	return { kind = "letter", text = letter_of(label) }
end

local function launch_ui(): LaunchUI
	return if tern.kv.get(KV_LAUNCH_UI) == "tui" then "tui" else "chat"
end

local function harness_of(id: string, label: string, tui: string?): Harness
	return { id = id, label = label, badge = badge_of(id, label), tui = tui, chat = "command tern acp " .. shell_quote(id) }
end

local function default_harness(): Harness
	return {
		id = "omp-default", label = "OMP", badge = { kind = "icon", name = "app-omp" },
		tui = "env PI_TUI_NATIVE=0 omp", chat = "env PI_TUI_NATIVE=1 omp",
	}
end

-- Every harness Tern perceives locally, in menu order: its registered built-ins,
-- then the configured custom agents. Read when a menu opens, never per row.
local function build_harnesses(cx: WindowCx): { Harness }
	local items: { Harness } = { default_harness() }
	for _, agent in BUILTIN_AGENTS do
		table.insert(items, harness_of(agent.id, agent.label, "command " .. agent.id))
	end
	local customs = cx.settings:get("agents.custom")
	if type(customs) == "table" then
		for _, agent in customs do
			if type(agent) == "table" and type(agent.id) == "string" and type(agent.command) == "string" then
				local label = if type(agent.name) == "string" and agent.name ~= "" then agent.name else agent.id
				table.insert(items, harness_of(agent.id, label, nil))
			end
		end
	end
	return items
end

-- New blocks start where the session's first tab runs. nil (or an unknown or
-- blank directory) lets Tern pick.
local function session_cwd(cx: WindowCx, session: number): string?
	local first: number? = nil
	for _, info in cx.session:sessions() do
		if info.id == session then
			first = info.tabs[1]
			break
		end
	end
	if not first then
		return nil
	end
	for _, tab in cx.session:tabs() do
		if tab.id == first then
			return if tab.cwd and tab.cwd ~= "" then tab.cwd else nil
		end
	end
	return nil
end

local function open_harness(cx: WindowCx, session: number, h: Harness): boolean
	local command = if launch_ui() == "tui" then h.tui else h.chat
	if not command then
		return false
	end
	local cwd = session_cwd(cx, session)
	cx.sessions:switch(session)
	menu = nil
	local pane = cx.layout:new_tab({ command = command, cwd = cwd }, { focus = true })
	if not pane then
		cx:toast("error", "Agent Nav: Could not open " .. h.label, "")
	end
	return true
end

local function toggle_menu(cx: WindowCx, session: number): boolean
	if menu and menu.session == session then
		menu = nil
	else
		menu = { session = session, items = build_harnesses(cx) }
	end
	return true
end

local function goto_key(session: number, pane: number): string
	return "goto:" .. tostring(session) .. ":" .. tostring(pane)
end

local function new_key(session: number): string
	return "new:" .. tostring(session)
end

local function menu_key(session: number): string
	return "menu:" .. tostring(session)
end

local function pick_key(session: number, harness_id: string): string
	return "pick:" .. tostring(session) .. ":" .. harness_id
end

local ACTIONS: { [string]: Action } = {
	goto = {
		pattern = "^(%d+):(%d+)$",
		run = function(cx, session, arg)
			local pane = tonumber(arg)
			if not pane then
				return false
			end
			menu = nil
			cx.sessions:switch(session)
			cx.layout:focus(pane)
			return true
		end,
	},
	new = {
		pattern = "^(%d+)$",
		run = function(cx, session)
			return open_harness(cx, session, default_harness())
		end,
	},
	menu = {
		pattern = "^(%d+)$",
		run = function(cx, session)
			return toggle_menu(cx, session)
		end,
	},
	dismiss = {
		pattern = "^(%d+)$",
		run = function()
			menu = nil
			return true
		end,
	},
	mode = {
		pattern = "^(%d+):(%a+)$",
		run = function(_cx, session, value)
			if not menu or menu.session ~= session or (value ~= "tui" and value ~= "chat") then
				return false
			end
			tern.kv.set(KV_LAUNCH_UI, value)
			return true
		end,
	},
	-- A click can only launch what the menu showed, so `pick` resolves against
	-- the open menu: a key from an earlier menu does nothing.
	pick = {
		pattern = "^(%d+):(.+)$",
		run = function(cx, session, arg)
			local open = menu
			if not arg or not open or open.session ~= session then
				return false
			end
			for _, h in open.items do
				if h.id == arg then
					return open_harness(cx, session, h)
				end
			end
			return false
		end,
	},
}

-- Route one canvas click; false when it is not ours, so the caller keeps its own
-- fallback.
local function dispatch(cx: WindowCx, act: string): boolean
	local verb, rest = string.match(act, "^(%a+):(.*)$")
	if not verb or not rest then
		return false
	end
	local action = ACTIONS[verb]
	if not action then
		return false
	end
	local session, arg = string.match(rest, action.pattern)
	local sid = tonumber(session)
	if not sid then
		return false
	end
	return action.run(cx, sid, arg)
end

local function badge_node(badge: Badge): Node
	if badge.kind == "icon" then
		return ui.el("span", { class = "agent-nav-logo", attrs = { ["aria-hidden"] = "true" } }, {
			ui.node("icon", { name = badge.name }),
		})
	end
	return ui.el("span", { class = "agent-nav-avatar", attrs = { ["aria-hidden"] = "true" }, text = badge.text })
end

local function icon_button(key: string, icon: string, title: string): Node
	return ui.el("button", {
		key = key,
		actions = { click = key },
		class = "agent-nav-action",
		attrs = { title = title, ["aria-label"] = title },
	}, {
		ui.node("icon", { name = icon }),
	})
end

local function session_header(session: number, name: string): Node
	return ui.el("div", { class = "agent-nav-session-row" }, {
		ui.el("div", { class = "agent-nav-session", text = name }),
		icon_button(new_key(session), "plus", "New agent tab"),
		icon_button(menu_key(session), "more", "Choose a harness"),
	})
end

local function menu_node(m: Menu): Node
	local selected = launch_ui()
	local enabled = selected == "chat"
	local key = "mode:" .. tostring(m.session) .. ":" .. (if enabled then "tui" else "chat")
	local rows: { Node } = {
		ui.el("div", { class = "agent-nav-mode" }, {
			ui.el("span", { text = "Enable Tern UI" }),
			ui.el("button", {
				key = key, actions = { click = key },
				class = "agent-nav-mode-switch" .. (if enabled then " is-on" else ""),
				attrs = { role = "switch", ["aria-label"] = "Enable Tern UI", ["aria-checked"] = tostring(enabled) },
			}, { ui.el("span", { class = "agent-nav-switch-thumb" }) }),
		}),
	}
	for _, h in m.items do
		local key = pick_key(m.session, h.id)
		local unavailable = selected == "tui" and h.tui == nil
		table.insert(rows, ui.el("button", {
			key = key,
			actions = if unavailable then nil else { click = key },
			class = "agent-nav-menu-item" .. (if unavailable then " is-disabled" else ""),
			attrs = { title = if unavailable then h.label .. " (Tern Chat UI only)" else h.label, ["aria-disabled"] = tostring(unavailable) },
		}, {
			badge_node(h.badge),
			ui.el("span", { class = "agent-nav-menu-name", text = h.label }),
		}))
	end
	return ui.el("div", { class = "agent-nav-menu" }, rows)
end

local function detect_harness(pane_info: any): (string, string)
	if pane_info.kind == "carly" then
		return "carly", "sparkle"
	end
	-- The foreground command names the harness most reliably: `program` can report
	-- the shell, and titles (Codex: "<task> | <dir>") need not mention the agent.
	local running = pane_info.running
	local line = string.lower(if running and type(running.line) == "string" then running.line else "")
	local command = string.match(line, "^%s*([^%s]+)") or ""
	command = string.match(command, "([^/\\]+)$") or command
	local fg = foreground[pane_info.pane]
	local probed = if fg then fg.argv else ""
	local prog = string.lower(pane_info.program or "")
	local title = string.lower(pane_info.title or "")
	for _, source in { command, probed, prog, title } do
		local key, icon = harness_icon(source)
		if key and icon then
			return key, icon
		end
	end
	if pane_info.kind == "agent" then
		return "agent", "app-omp"
	end
	return "terminal", "terminal"
end

local function is_navigable_pane(pane_info: any): boolean
	if pane_info.block == "tern.canvas" then
		return false
	end
	if pane_info.kind == "agent" or pane_info.kind == "carly" then
		return true
	end
	if pane_info.kind == "terminal" then
		local harness, _ = detect_harness(pane_info)
		if harness == "terminal" then
			probeForeground(pane_info)
		end
		return harness ~= "terminal"
	end
	return false
end

local function build_view(cx: WindowCx): Node
	tickCounter += 1
	screenBudget = SCREEN_READS_PER_TICK

	-- Query native agent blocks for authoritative first-class state; on
	-- failure (for example a response too large for the daemon frame) keep
	-- the previous snapshot.
	local ok_ag, ag_list = pcall(function() return cx.agents:list() end)
	if ok_ag and type(ag_list) == "table" then
		local fresh: { [number]: string } = {}
		for _, a in ag_list do
			if a.pane and a.state then
				fresh[a.pane] = a.state
			end
		end
		agentStates = fresh
	end


	local tab_to_session: { [number]: number } = {}
	for _, t in cx.session:tabs() do
		tab_to_session[t.id] = t.session
	end

	local session_groups: { [number]: { name: string, agents: { AgentRow } } } = {}
	local session_order: { number } = {}
	for _, s in cx.session:sessions() do
		session_groups[s.id] = { name = s.name, agents = {} }
		table.insert(session_order, s.id)
	end

	for _, p in cx.session:panes() do
		local sid = p.tab and tab_to_session[p.tab]
		local group = sid and session_groups[sid]
		if group and sid and is_navigable_pane(p) then
			local harness, icon = detect_harness(p)
			-- The window's own focus flag, not a pane-id comparison: the id
			-- from cx.session:focused() can be truncated (stencil-hq/tern-sdk#30).
			local is_focused = p.focused == true

			-- Determine running state reliably across native agents and interactive terminals:
			local is_running = false
			local ag_state: string? = agentStates[p.pane]
			-- Cheap signals a laggy agent block cannot fake: ACP-wrapped CLI
			-- panes have been seen reporting state="idle" through a real turn.
			local spinning = spinnerTitle(p.title) or spinnerTitleSuffix(p.title)
			local busyWorking = p.busy == true and not p.at_prompt
			if ag_state == "working" or ag_state == "waiting_input" then
				-- Trust a positive authoritative state.
				is_running = ag_state == "working"
			else
				-- No state, or an idle/exited report: cross-check against the
				-- cheap signals and the pane's screen before believing idle.
				is_running = spinning or busyWorking
				local screen = screenStateCached(cx, p)
				if screen == "ask" then
					ag_state = "waiting_input"
					is_running = false
				elseif screen == "working" then
					is_running = true
				end
			end

			-- Check transition from running -> finished
			if wasRunning[p.pane] == true and not is_running then
				-- Just completed! If user is not currently focused on this pane, mark unread.
				if not is_focused then
					unreadPanes[p.pane] = true
				end
			end
			wasRunning[p.pane] = is_running

			-- Also honor terminal alert bell on inactive panes as unread
			if p.alert and not is_focused and not is_running and ag_state ~= "waiting_input" then
				unreadPanes[p.pane] = true
			end

			-- If the user is currently focused on this pane, clear unread immediately.
			if is_focused then
				unreadPanes[p.pane] = nil
			end

			-- Status precedence:
			-- 1. Attention (waiting for user input / approval): purple
			-- 2. Running: amber/yellow with text shimmer
			-- 3. Done unread: emerald green
			-- 4. Error: red
			-- 5. Done read / idle: muted secondary text
			local status = "done-read"
			if ag_state == "waiting_input" then
				status = "attention"
			elseif is_running then
				status = "running"
			elseif not is_focused and (unreadPanes[p.pane] or p.alert) then
				status = "done-unread"
			elseif p.error or (p.exited and p.exited ~= 0) then
				status = "error"
			else
				status = "done-read"
			end

			-- omp writes its session title into the pane title once it has one; an
			-- untitled omp session keeps the program name.
			local _, title = spinnerTitle(p.title)
			if not title or title == "" then
				title = if harness == "omp" then "omp" else (p.cwd and string.match(p.cwd, "([^/\\]+)$") or ("Pane " .. tostring(p.pane)))
			end

			table.insert(group.agents, {
				pane = p.pane,
				session = sid,
				title = title,
				icon = icon,
				status = status,
				is_current = is_focused,
			})
		end
	end

	local menu_drawn = false
	local sections = {}
	for _, sid in session_order do
		local g = session_groups[sid]
		if #g.agents > 0 then
			local rows = { session_header(sid, g.name) }
			if menu and menu.session == sid then
				table.insert(rows, menu_node(menu))
				menu_drawn = true
			end
			for _, ag in g.agents do
				local action_key = goto_key(ag.session, ag.pane)
				table.insert(rows, ui.el("button", {
					key = action_key,
					actions = { click = action_key },
					class = "agent-nav-agent status-" .. ag.status .. (if ag.is_current then " is-current" else ""),
					attrs = { title = ag.title .. " · " .. ag.status },
				}, {
					ui.el("span", { class = "agent-nav-logo", attrs = { ["aria-hidden"] = "true" } }, {
						ui.node("icon", { name = ag.icon }),
					}),
					-- Running titles use Tern's native per-character shimmer (the sweep omp's
					-- working label uses); its colors come from --sh-* in styles.css.
					if ag.status == "running"
						then ui.el("span", { class = "agent-nav-title" }, {
							ui.node("shimmer", { mode = "classic", spans = { { t = ag.title } } }),
						})
						else ui.el("span", { class = "agent-nav-title", text = ag.title }),
				}))
			end
			table.insert(sections, ui.el("section", { class = "agent-nav-group" }, rows))
		end
	end

	if menu and not menu_drawn then
		menu = nil
	end

	if #sections == 0 then
		table.insert(sections, ui.el("div", { class = "agent-nav-empty", text = "No agent sessions active" }))
	end

	local children = {
		ui.el("header", { class = "agent-nav-header" }, {
			ui.el("span", { class = "agent-nav-heading", text = "Agents" }),
		}),
		ui.el("div", { class = "agent-nav-groups" }, sections),
	}
	if menu then
		local key = "dismiss:" .. tostring(menu.session)
		table.insert(children, ui.el("button", { key = key, actions = { click = key }, class = "agent-nav-dismiss", attrs = { ["aria-label"] = "Close harness menu" } }))
	end
	return ui.el("div", { class = "agent-nav-root" }, children)
end

local rendered: string? = nil
local renderedPane: number? = nil

local function draw(cx: WindowCx)
	local pane = slot(cx)
	if not pane then
		return
	end
	local view = build_view(cx)
	local key = tern.json.encode(view)
	if pane == renderedPane and key == rendered then
		return
	end
	cx.canvas:set(pane, { view = view })
	rendered, renderedPane = key, pane
end

--------------------------------------------------------------------------------
-- Tab Following Lifecycle
--------------------------------------------------------------------------------

local function openPanel(cx: WindowCx, tab: number)
	local view = build_view(cx)
	local pane, err = cx.canvas:open({ title = TITLE, about = ABOUT, view = view, how = "beside", focus = false })
	if not pane then
		cx:toast("error", "Agent Nav: Could not open panel", tostring(err))
		return
	end
	slotPane = pane
	rendered, renderedPane = tern.json.encode(view), pane
	appliedShare = nil
	pin(cx, tab)
end

-- Warn if pane ID exceeds 44 bits (Tern upstream issue stencil-hq/tern-sdk#30).
local function idsResolve(cx: WindowCx): boolean
	local focused = cx.session:focused()
	if not focused or cx.session:pane(focused) then
		return true
	end
	if not warnedIds then
		warnedIds = true
		tern.log.warn("Agent Nav: window API cannot resolve focused pane ID " .. tostring(focused))
		cx:toast("error", "Agent Nav: Cannot position panel",
			"Local pane ID exceeds 44 bits. Tern window API truncates it so lookups return nil (cx.session:pane returns nil). Move/resize operations are disabled by upstream Tern bug #30.")
	end
	return false
end

-- Keep the panel in the active tab.
local function follow(cx: WindowCx, tab: number?)
	if busy or not localHost(cx) or not idsResolve(cx) then
		return
	end
	local shown = tab or shownTab(cx)
	if not shown then
		return
	end
	busy = true
	local ok, err = pcall(function()
		local pane = slot(cx)
		if not pane then
			if not wantPanel then
				return
			end
			-- Reopen if closed with its tab; leave closed if user explicitly closed it.
			for _, info in cx.session:tabs() do
				if info.id == panelTab then
					setWantPanel(false)
					panelTab = nil
					return
				end
			end
			openPanel(cx, shown)
			return
		end
		if not wantPanel then
			setWantPanel(true)
		end
		pin(cx, shown)
	end)
	busy = false
	if not ok then
		tern.log.warn("Agent Nav follow: " .. tostring(err))
	end
end

local function followAndDraw(cx: WindowCx?, tab: number?)
	if not cx then
		return
	end
	follow(cx, tab)
	local okS, errS = pcall(settle, cx)
	if not okS then
		tern.log.warn("Agent Nav settle: " .. tostring(errS))
	end
	local ok, err = pcall(draw, cx)
	if not ok then
		tern.log.warn("Agent Nav draw: " .. tostring(err))
	end
end

--------------------------------------------------------------------------------
-- Commands & Events
--------------------------------------------------------------------------------

tern.command({
	id = "toggle",
	title = "Agent Nav: Toggle",
	keys = { "ctrl+alt+n" },
	run = function(cx)
		local pane = slot(cx)
		if pane then
			setWantPanel(false)
			panelTab, slotPane, rendered, renderedPane = nil, nil, nil, nil
			menu = nil
			appliedShare, placedSide = nil, nil
			pendingFits, pendingSize, pendingTab = {}, false, nil
			cx.layout:close(pane)
			return
		end
		setWantPanel(true)
		panelTab = nil
		appliedShare, placedSide = nil, nil
		pendingFits, pendingSize, pendingTab = {}, false, nil
		warnedIds = false
		followAndDraw(cx)
	end,
})

tern.command({
	id = "toggle_side",
	title = "Agent Nav: Toggle left / right",
	run = function(cx)
		local pane = slot(cx)
		local from = pane and cx.session:tab_of(pane)
		if pane and from then
			noteDrag(cx, from, pane)
		end
		tern.kv.set(KV_SIDE, if side() == "left" then "right" else "left")
		followAndDraw(cx)
	end,
})

tern.command({
	id = "reset_width",
	title = "Agent Nav: Reset Width",
	run = function(cx)
		tern.kv.set(KV_SHARE, nil)
		share = DEFAULT_SHARE
		appliedShare = nil
		local pane = slot(cx)
		local tab = pane and cx.session:tab_of(pane)
		if pane and tab and placedSide and readRail(cx, tab, pane, placedSide) then
			sizeRail(cx, tab, pane, placedSide, share)
		end
	end,
})

tern.on("canvas_action", function(ev: CanvasAction, cx: WindowCx): boolean?
	if ev.pane ~= slot(cx) then
		return false
	end
	if dispatch(cx, ev.act) then
		draw(cx)
		return true
	end
	return false
end)

tern.on("focus", function(ev: FocusEvent, cx: WindowCx)
	if menu and ev.pane ~= slotPane then
		menu = nil
	end
	followAndDraw(cx, ev.tab)
end)

-- Re-render immediately on window events, pane title changes, and agent turn completions.
for _, name in { "tab_created", "tab_closed", "pane_created", "pane_closed", "title", "agent_finished" } do
	tern.on(name, function(_ev: any, cx: WindowCx)
		followAndDraw(cx)
	end)
end

tern.on("window_start", function(cx: WindowCx)
	followAndDraw(cx)
end)

local function tick(cx: WindowCx?)
	followAndDraw(cx)
	tern.timer(TICK_MS, tick)
end
tern.timer(TICK_MS, tick)
