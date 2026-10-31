--!strict
-- Agent Navigations: one agent list per window that follows the shown tab as a
-- full-height rail on the left or right edge, at a remembered share of the tab.
--
-- Placement follows Overseer's Projects panel pattern: Tern panes belong to one tab,
-- so the window keeps a single canvas and moves it into whichever tab is shown.
-- The rail can only reach the tab's edge while the other side is a single pane, and
-- cx.layout:resize only moves the nearest divider of the requested axis, so a
-- placement is one bounded, journalled rebuild: park the content (every program
-- keeps running and no pane is closed), put the rail on its edge at the
-- remembered share, then re-grow the saved tree node by node, fitting each
-- divider while its two children are still leaves.

local ui = tern.ui

local TITLE = "Agent Navigations"
local ABOUT = "Agents across Tern sessions. Click a row to switch to its session and focus it."
local TICK_MS = 750
-- A restore that is still moving panes continues on this shorter cadence instead
-- of waiting for the next normal tick; one follow-up is outstanding at a time.
local FAST_TICK_MS = 60
local DEFAULT_SHARE = 0.2
local MIN_SHARE, MAX_SHARE = 0.08, 0.6

local KV_ENABLED = "agent_nav.enabled"
local KV_SIDE = "agent_nav.side"
local KV_SHARE = "agent_nav.share"
local KV_LAUNCH_UI = "agent_nav.launch_ui"
local KV_OPEN_TAB = "agent_nav.open_in_tab"

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
-- Arrangement Model
--------------------------------------------------------------------------------
-- cx.session:layout(tab).root is a TabTree whose children are numeric [1]/[2]
-- keys, and tern.json.decode drops null members and loses order, so a TabTree
-- cannot be round-tripped through the journal. Everything this module stores,
-- compares or replans therefore uses one shape: a `pane` leaf, or a split with
-- named `axis`, `ratio`, `first` and `second`. Ratios live in the tree, so the
-- model is exactly what a rebuild has to put back: pane ids, programs and titles
-- are never touched, and no pane is ever closed to finish a restore.

type Axis = "right" | "down"
type Tree = {
	pane: number?,
	axis: Axis?,
	ratio: number?,
	first: Tree?,
	second: Tree?,
}

local MAX_TREE_DEPTH = 32
local MAX_TREE_LEAVES = 64

-- Strip `pane` from the raw native node tree before converting to Tree, so that
-- valid depth-32 content does not become depth-33 when wrapped by a rail split.
local function strip_native_pane(node: any, pane: number): any?
	if type(node) ~= "table" then
		return nil
	end
	if node.pane == pane then
		return nil
	end
	if node.pane ~= nil then
		return node
	end
	local split = node.split
	if split ~= "right" and split ~= "down" then
		return nil
	end
	local child1 = strip_native_pane(node[1], pane)
	local child2 = strip_native_pane(node[2], pane)
	if not child1 then
		return child2
	end
	if not child2 then
		return child1
	end
	return { split = split, ratio = node.ratio, [1] = child1, [2] = child2 }
end

-- Normalize a native TabTree; bounds match decoder exactly (depth 32, leaves 64, unique panes).
local function tree_of(node: any, depth: number?, budget: { number }?, seen: { [number]: boolean }?): Tree?
	local d = depth or 0
	local left = budget or { MAX_TREE_LEAVES }
	local panes = seen or {}
	if type(node) ~= "table" or d > MAX_TREE_DEPTH then
		return nil
	end
	local pane = node.pane
	if type(pane) == "number" then
		if pane <= 0 or pane ~= math.floor(pane) or left[1] <= 0 or panes[pane] then
			return nil
		end
		left[1] -= 1
		panes[pane] = true
		return { pane = pane }
	end
	local axis = node.split
	if axis ~= "right" and axis ~= "down" then
		return nil
	end
	local split: Axis = axis
	local first = tree_of(node[1], d + 1, left, panes)
	local second = tree_of(node[2], d + 1, left, panes)
	if not first or not second then
		return nil
	end
	local ratio = node.ratio
	return {
		axis = split,
		ratio = if type(ratio) == "number" and ratio > 0 and ratio < 1 then ratio else 0.5,
		first = first,
		second = second,
	}
end

-- Pane ids of a tree, in native order. Never silently truncates membership.
local function leaves_of(t: Tree, out: { number }?): { number }
	local acc = out or {}
	local pane = t.pane
	if pane then
		table.insert(acc, pane)
		return acc
	end
	local first, second = t.first, t.second
	if first then
		leaves_of(first, acc)
	end
	if second then
		leaves_of(second, acc)
	end
	return acc
end

local function first_leaf(t: Tree): number?
	local pane = t.pane
	if pane then
		return pane
	end
	local first = t.first
	return if first then first_leaf(first) else nil
end

local function has_pane(t: Tree, pane: number): boolean
	local own = t.pane
	if own then
		return own == pane
	end
	local first, second = t.first, t.second
	return (first ~= nil and has_pane(first, pane)) or (second ~= nil and has_pane(second, pane))
end

-- The tree without `pane`, its parent split collapsed into the sibling; nil when
-- the tree held nothing else.
local function strip_pane(t: Tree, pane: number): Tree?
	local own = t.pane
	if own then
		return if own == pane then nil else t
	end
	local axis, ratio, first, second = t.axis, t.ratio, t.first, t.second
	if not axis or not first or not second then
		return nil
	end
	local a, b = strip_pane(first, pane), strip_pane(second, pane)
	if not a then
		return b
	end
	if not b then
		return a
	end
	return { axis = axis, ratio = ratio or 0.5, first = a, second = b }
end

-- Same leaves in the same positions on the same axes; ratios excluded.
local function same_shape(a: Tree, b: Tree): boolean
	local pa, pb = a.pane, b.pane
	if pa or pb then
		return pa == pb
	end
	if a.axis ~= b.axis then
		return false
	end
	local af, bf, as, bs = a.first, b.first, a.second, b.second
	if not af or not bf or not as or not bs then
		return false
	end
	return same_shape(af, bf) and same_shape(as, bs)
end


-- The split that owns `pane` as a direct child, read from the live native tree
-- so a fit knows which divider cx.layout:resize will move: its axis, its ratio
-- and which side of it the pane sits on.
local function parent_of(node: any, pane: number, depth: number?): (Axis?, number?, boolean?)
	local d = depth or 0
	if type(node) ~= "table" or d > MAX_TREE_DEPTH + 1 or node.pane ~= nil then
		return nil, nil, false
	end
	for i = 1, 2 do
		local child = node[i]
		if type(child) == "table" and child.pane == pane then
			local axis = node.split
			if axis ~= "right" and axis ~= "down" then
				return nil, nil, false
			end
			local split: Axis = axis
			local ratio = node.ratio
			return split, (if type(ratio) == "number" then ratio else 0.5), i == 1
		end
	end
	for i = 1, 2 do
		local split, ratio, first = parent_of(node[i], pane, d + 1)
		if split then
			return split, ratio, first
		end
	end
	return nil, nil, false
end

-- Locate the split owning a direct-child pair (a, b) in the native tree.
local function split_of_pair(node: any, a: number, b: number, depth: number?): (Axis?, number?, boolean?)
	local d = depth or 0
	if type(node) ~= "table" or d > MAX_TREE_DEPTH + 1 or node.pane ~= nil then
		return nil, nil, false
	end
	local axis = node.split
	if axis == "right" or axis == "down" then
		local c1, c2 = node[1], node[2]
		if type(c1) == "table" and type(c2) == "table" then
			local split: Axis = axis
			local ratio = if type(node.ratio) == "number" then node.ratio else 0.5
			if c1.pane == a and c2.pane == b then
				return split, ratio, true
			elseif c1.pane == b and c2.pane == a then
				return split, ratio, false
			end
		end
	end
	for i = 1, 2 do
		local s, r, first = split_of_pair(node[i], a, b, d + 1)
		if s then
			return s, r, first
		end
	end
	return nil, nil, false
end

local function tree_json(t: Tree): any
	local pane = t.pane
	if pane then
		return { pane = pane }
	end
	local first, second = t.first, t.second
	if not first or not second then
		return nil
	end
	return { axis = t.axis, ratio = t.ratio, first = tree_json(first), second = tree_json(second) }
end

-- Validate a stored tree: ids, axes and ratios only, bounded in depth and size.
local function tree_from(value: any, depth: number?, budget: { number }?, seen: { [number]: boolean }?): Tree?
	local d = depth or 0
	local left = budget or { MAX_TREE_LEAVES }
	local panes = seen or {}
	if type(value) ~= "table" or d > MAX_TREE_DEPTH then
		return nil
	end
	local pane = value.pane
	if type(pane) == "number" then
		if pane <= 0 or pane ~= math.floor(pane) or left[1] <= 0 or panes[pane] then
			return nil
		end
		left[1] -= 1
		panes[pane] = true
		return { pane = pane }
	end
	local axis = value.axis
	if axis ~= "right" and axis ~= "down" then
		return nil
	end
	local split: Axis = axis
	local ratio = value.ratio
	if type(ratio) ~= "number" or not (ratio > 0 and ratio < 1) then
		return nil
	end
	local first = tree_from(value.first, d + 1, left, panes)
	local second = tree_from(value.second, d + 1, left, panes)
	if not first or not second then
		return nil
	end
	return { axis = split, ratio = ratio, first = first, second = second }
end

-- The rail's share of the tab when it is the root split's outer child on `s`.
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

-- Grow `pane` toward `axis` to grow the side of it that holds the first child.
local function toward(axis: Axis, first: boolean): Dir
	if axis == "right" then
		return if first then "right" else "left"
	end
	return if first then "down" else "up"
end

local function away(axis: Axis): Dir
	return if axis == "right" then "left" else "up"
end

--------------------------------------------------------------------------------
-- Panel & Layout State
--------------------------------------------------------------------------------

local slotPane: number? = nil
local lastRailTab: number? = nil
-- The rail's width as this plugin last measured or set it, and the tab that
-- width belongs to: `appliedShare` says nothing about any other tab, so a
-- pending rework must never be mistaken for the user dragging the divider.
local appliedShare: number? = nil
local appliedTab: number? = nil
local share = storedShare()
local warnedIds = false

type PendingFit = {
	mover: number,
	anchor: number,
	axis: Axis,
	ratio: number,
	owner: number,
}

-- The rebuild in flight: the tab being put back, the arrangement to restore and
-- the panes this job parked to do it. It outlives reloads through the journal,
-- and it is the only owner of the native layout while it runs.
type Job = {
	seq: number,
	tab: number,
	session: number,
	side: Side,
	share: number,
	stage: string,
	anchor: number,
	content: Tree?,
	members: { [number]: boolean },
	owned: { [number]: boolean },
	focus: number?,
	name: string?,
	dest: number?,
	pending: PendingFit?,
	warned: { [string]: boolean },
	stuck: { [number]: number },
}

local function set_stage(job: Job, nextStage: string)
	job.stage = nextStage
	if nextStage ~= "grow" then
		job.pending = nil
	end
end

local state = {
	job = nil :: Job?,
	advancing = false,
	resumed = false,
	windowKey = nil :: string?,
	keyReady = false,
	clamped = nil :: { tab: number, side: Side, share: number, tries: number }?,
	journalWarned = false,
	windowSeq = 0,
}

local function is_parked(cx: WindowCx, pane: number): boolean
	local info = cx.session:pane(pane)
	return info ~= nil and info.parked == true
end

local function owned_list(owned: { [number]: boolean }): { number }
	local out: { number } = {}
	for pane in owned do
		table.insert(out, pane)
	end
	table.sort(out)
	return out
end


local function pending_json(p: PendingFit?): any?
	if not p then
		return nil
	end
	return {
		mover = p.mover,
		anchor = p.anchor,
		axis = p.axis,
		ratio = p.ratio,
		owner = p.owner,
	}
end

local function valid_id(value: any): boolean
	return type(value) == "number" and value > 0 and value < math.huge and value == math.floor(value)
end

local function pending_from(doc: any): PendingFit?
	local p = doc.pending
	if type(p) ~= "table" then
		return nil
	end
	local mover, anchor, owner, ratio = tonumber(p.mover), tonumber(p.anchor), tonumber(p.owner), tonumber(p.ratio)
	if not mover or not anchor or mover <= 0 or anchor <= 0 or mover >= math.huge or anchor >= math.huge
		or mover ~= math.floor(mover) or anchor ~= math.floor(anchor) or mover == anchor
		or (owner ~= mover and owner ~= anchor) or not ratio or not (ratio > 0 and ratio < 1) then
		return nil
	end
	if p.axis ~= "right" and p.axis ~= "down" then
		return nil
	end
	return { mover = mover, anchor = anchor, axis = p.axis, ratio = ratio, owner = owner }
end

--------------------------------------------------------------------------------
-- Durable Rebuild Journal
--------------------------------------------------------------------------------
-- A rebuild spans hooks, and pane ids live in the window VM, so a reload, a
-- paused hook or a closed window would strand the panes it parked out of their
-- tab. The job is written before the first pane is parked into one file per
-- window with two alternating slots: an interrupted write costs the newest
-- checkpoint but never the last valid one. tern.kv is shared by every window and
-- its cross-VM read-modify-write is not documented as atomic, so the journal is
-- not kept there.

local JOURNAL_VERSION = 1
local JOURNAL_MAX_BYTES = 256 * 1024
local LAYOUT_STAGES: { [string]: boolean } = {
	attach = true, clear = true, rail = true, grow = true, verify = true, release = true,
}

local function hex_of(text: string): string
	return (string.gsub(text, ".", function(c: string): string
		return string.format("%02x", string.byte(c))
	end))
end

local function journal_dir(): string?
	local data = tern.plugin.data
	if type(data) ~= "string" or data == "" then
		return nil
	end
	return data .. "/layout"
end

-- One window key, one file stem: the key is hex-encoded, so any byte string,
-- including the empty first-window key, maps to exactly one file name.
local function journal_path(key: string, seq: number): string?
	local dir = journal_dir()
	if not dir then
		return nil
	end
	return dir .. "/window-" .. hex_of(key) .. (if seq % 2 == 0 then ".a.json" else ".b.json")
end

local function window_key(cx: WindowCx): string?
	if not state.keyReady then
		state.keyReady = true
		state.windowKey = cx:window_key()
	end
	return state.windowKey
end

local function read_slot(path: string): any?
	local ok, text = pcall(tern.fs.read, path, JOURNAL_MAX_BYTES)
	if not ok or type(text) ~= "string" then
		return nil
	end
	local okDecode, doc = pcall(tern.json.decode, text)
	return if okDecode and type(doc) == "table" then doc else nil
end

local function write_slot(path: string, doc: any): boolean
	local dir = journal_dir()
	if not dir then
		return false
	end
	local ok, err = pcall(function()
		if not tern.fs.exists(dir) then
			tern.fs.mkdir(dir)
		end
		local encoded = tern.json.encode(doc)
		if #encoded > JOURNAL_MAX_BYTES then
			error("journal doc exceeds maximum bytes")
		end
		tern.fs.write(path, encoded)
	end)
	if not ok then
		if not state.journalWarned then
			state.journalWarned = true
			tern.log.warn("Agent Nav: cannot write the layout journal under " .. dir ..
				"; a reload in the middle of a restore will not resume it: " .. tostring(err))
		end
		return false
	end
	return true
end

-- The job as it goes on disk; the tree keeps named members so it decodes back
-- into the shape it was written from.
local function job_json(job: Job, key: string): any?
	local content: any = nil
	if job.content then
		content = tree_json(job.content)
		if not content then
			return nil
		end
	end
	return {
		v = JOURNAL_VERSION,
		key = key,
		seq = job.seq,
		tab = job.tab,
		session = job.session,
		side = job.side,
		share = job.share,
		stage = job.stage,
		anchor = job.anchor,
		content = content,
		members = owned_list(job.members),
		owned = owned_list(job.owned),
		focus = job.focus,
		name = job.name,
		dest = job.dest,
		pending = pending_json(job.pending),
	}
end

-- A stored record becomes a job only when every field this module acts on is
-- present and sane; anything else is dropped at the boundary.
local function job_from(doc: any): Job?
	if type(doc) ~= "table" or doc.v ~= JOURNAL_VERSION or doc.done == true then
		return nil
	end
	local tab, session, anchor, wantShare = tonumber(doc.tab), tonumber(doc.session), tonumber(doc.anchor), tonumber(doc.share)
	local side = doc.side
	local stage = doc.stage
	if not valid_id(tab) or not valid_id(session) or not valid_id(anchor) or not valid_id(doc.seq) or not wantShare then
		return nil
	end
	if side ~= "left" and side ~= "right" then
		return nil
	end
	if not (wantShare > 0 and wantShare < 1) then
		return nil
	end
	if type(stage) ~= "string" or not LAYOUT_STAGES[stage] then
		return nil
	end
	local content: Tree? = nil
	if doc.content ~= nil then
		content = tree_from(doc.content)
		if not content then
			return nil
		end
	end

	if type(doc.members) ~= "table" or #doc.members == 0 or #doc.members > MAX_TREE_LEAVES or type(doc.owned) ~= "table" then
		return nil
	end
	local members: { [number]: boolean } = {}
	for _, pane in doc.members do
		if not valid_id(pane) or members[pane] then
			return nil
		end
		members[pane] = true
	end
	if not members[anchor] then
		return nil
	end
	if content then
		for _, pane in leaves_of(content) do
			if not members[pane] then
				return nil
			end
		end
	end
	local owned: { [number]: boolean } = {}
	for _, pane in doc.owned do
		if not valid_id(pane) or not members[pane] or owned[pane] then
			return nil
		end
		owned[pane] = true
	end
	for _, name in { "focus", "dest" } do
		local pane = doc[name]
		if pane ~= nil and (not valid_id(pane) or not members[pane]) then
			return nil
		end
	end
	local pending = pending_from(doc)
	if doc.pending ~= nil and (not pending or not members[pending.mover] or not members[pending.anchor]) then
		return nil
	end

	return {
		seq = tonumber(doc.seq) or 0,
		tab = tab,
		session = session,
		side = side,
		share = wantShare,
		stage = stage,
		anchor = anchor,
		content = content,
		members = members,
		owned = owned,
		focus = tonumber(doc.focus),
		name = if type(doc.name) == "string" and doc.name ~= "" then doc.name else nil,
		dest = tonumber(doc.dest),
		pending = pending,
		warned = {},
		stuck = {},
	}
end

-- Persist job checkpoint; advances sequence and slot only on success.
-- Keeps previous valid slot intact on repeated failures.
local function persist(job: Job): boolean
	local key = state.windowKey
	if not key then
		return false
	end
	local nextSeq = math.max(state.windowSeq, job.seq) + 1
	local doc = job_json(job, key)
	if not doc then
		return false
	end
	doc.seq = nextSeq
	local path = journal_path(key, nextSeq)
	if not path then
		return false
	end
	local ok = write_slot(path, doc)
	if not ok then
		return false
	end
	job.seq = nextSeq
	state.windowSeq = nextSeq
	return true
end

local function retire_journal(seq: number): boolean
	local key = state.windowKey
	if not key then
		return false
	end
	local nextSeq = math.max(state.windowSeq, seq) + 1
	local path = journal_path(key, nextSeq)
	if not path then
		return false
	end
	local ok = write_slot(path, { v = JOURNAL_VERSION, key = key, seq = nextSeq, done = true })
	if ok then
		state.windowSeq = nextSeq
	end
	return ok
end

-- A completed checkpoint wins even if the user subsequently parks one of its
-- former members. Old ownership must never be resurrected from another slot.
local function journal_load(key: string): any?
	local best: any = nil
	for slotIndex = 0, 1 do
		local path = journal_path(key, slotIndex)
		local doc = if path then read_slot(path) else nil
		local seq = if doc then doc.seq else nil
		if doc and doc.v == JOURNAL_VERSION and doc.key == key and valid_id(seq)
			and seq < 9007199254740991 and seq % 2 == slotIndex
			and (doc.done == true or job_from(doc) ~= nil) then
			if not best or seq > best.seq then
				best = doc
			end
		end
	end
	if best then
		state.windowSeq = math.max(state.windowSeq, best.seq)
	end
	return if best and best.done ~= true then best else nil
end


local function noteDrag(cx: WindowCx, tab: number, rail: number)
	if state.job or not appliedShare or appliedTab ~= tab then
		return
	end
	local layout = cx.session:layout(tab)
	if not layout or not layout.root or layout.root.split ~= "right" then
		return
	end
	local root = layout.root
	local current: number? = nil
	if root[1] and root[1].pane == rail then
		current = root.ratio or 0.5
	elseif root[2] and root[2].pane == rail then
		current = 1 - (root.ratio or 0.5)
	end
	if not current then
		return
	end
	if math.abs(current - appliedShare) > 0.005 then
		share = clampShare(current)
		appliedShare = current
		tern.kv.set(KV_SHARE, share)
	end
end


local SHARE_TOL = 0.01
local RATIO_TOL = 1e-6
local MAX_PUSHES = 4
local MAX_STEPS = 4
local ADVANCE_MS = 40

local function tab_info(cx: WindowCx, tab: number): TabInfo?
	for _, info in cx.session:tabs() do
		if info.id == tab then
			return info
		end
	end
	return nil
end

local function session_of(cx: WindowCx, tab: number): number?
	local info = tab_info(cx, tab)
	return if info then info.session else nil
end

local function content_of(cx: WindowCx, tab: number, rail: number?): Tree?
	local layout = cx.session:layout(tab)
	if not layout or not layout.root then
		return nil
	end
	local nativeRoot = layout.root
	if rail then
		nativeRoot = strip_native_pane(nativeRoot, rail)
		if not nativeRoot then
			return nil
		end
	end
	return tree_of(nativeRoot)
end

local function adopt_destination(cx: WindowCx, job: Job, rail: number?): boolean
	local dest = job.dest
	if not dest or cx.session:layout(job.tab) then
		return false
	end
	local tab = cx.session:tab_of(dest)
	if not tab then
		return false
	end
	local info = tab_info(cx, tab)
	local content = content_of(cx, tab, rail)
	local eligible = info ~= nil and info.session == job.session and content ~= nil
	if content then
		for _, pane in leaves_of(content) do
			if not job.members[pane] then
				eligible = false
				break
			end
		end
	end
	if not eligible then
		job.dest = nil
		persist(job)
		return false
	end
	job.tab, job.anchor = tab, dest
	job.owned[dest] = nil
	set_stage(job, "clear")
	persist(job)
	return true
end


local function parked_owned(cx: WindowCx, job: Job): { number }
	local out: { number } = {}
	for pane in job.owned do
		if is_parked(cx, pane) then
			table.insert(out, pane)
		end
	end
	table.sort(out)
	return out
end

local function choose_anchor(cx: WindowCx, tab: number, content: Tree?, rail: number?): number?
	if not content then
		return nil
	end
	local focused = cx.session:focused()
	if focused and focused ~= rail and has_pane(content, focused) and cx.session:tab_of(focused) == tab then
		return focused
	end
	for _, pane in leaves_of(content) do
		if pane ~= rail and cx.session:tab_of(pane) == tab then
			return pane
		end
	end
	for _, pane in leaves_of(content) do
		if pane ~= rail and cx.session:pane(pane) then
			return pane
		end
	end
	return nil
end

local function warn_once(job: Job, kind: string, message: string)
	if job.warned[kind] then
		return
	end
	job.warned[kind] = true
	tern.log.warn(message)
end

local function complete(job: Job, reason: string)
	if state.job ~= job then
		return
	end
	local hasDebt = false
	for pane in job.owned do
		hasDebt = true
		break
	end
	if hasDebt then
		set_stage(job, "release")
		persist(job)
		return
	end
	state.job = nil
	retire_journal(job.seq)
	tern.log.debug("Agent Nav: layout job finished (" .. reason .. ")")
end

local function release_job(job: Job, why: string): string
	if not job.warned.release then
		job.warned.release = true
		tern.log.warn("Agent Nav: abandoning the saved layout (" .. why .. "); returning every pane it parked")
	end
	job.content = nil
	set_stage(job, "release")
	persist(job)
	return "again"
end

local function empty_job(job: Job): string
	job.content = nil
	set_stage(job, "release")
	persist(job)
	return "again"
end

local function remember_clamp(job: Job)
	local memo = state.clamped
	if memo and memo.tab == job.tab and memo.side == job.side and math.abs(memo.share - job.share) < 1e-9 then
		memo.tries += 1
		return
	end
	state.clamped = { tab = job.tab, side = job.side, share = job.share, tries = 1 }
end

local function is_clamped(tab: number, s: Side, want: number): boolean
	local memo = state.clamped
	return memo ~= nil and memo.tab == tab and memo.side == s and math.abs(memo.share - want) < 1e-9
end

local function fit_share(cx: WindowCx, tab: number, owner: number, axis: Axis, want: number, peer: number?): (string, number, number?)
	local function read_ratio(): (number?, boolean?)
		local layout = cx.session:layout(tab)
		if not layout then
			return nil, nil
		end
		local foundAxis, ratio, first
		if peer then
			foundAxis, ratio, first = split_of_pair(layout.root, owner, peer)
		else
			foundAxis, ratio, first = parent_of(layout.root, owner)
		end
		if foundAxis ~= axis or not ratio then
			return nil, nil
		end
		return if first then ratio else 1 - ratio, first
	end
	local current, first = read_ratio()
	if not current then
		return "lost", 0, nil
	end
	if math.abs(want - current) <= RATIO_TOL then
		return "ok", 0, current
	end
	local dir: Dir = if first then axis else away(axis)
	local cells = if want > current then 1 else -1
	local unit: number? = nil
	local pushes = 0
	for attempt = 1, MAX_PUSHES do
		local before = current
		local moved = cx.layout:resize(owner, dir, cells)
		local after, afterFirst = read_ratio()
		if not after or afterFirst ~= first then
			return "lost", pushes, nil
		end
		current = after
		if not moved or math.abs(current - before) <= 1e-12 then
			if unit then
				return if math.abs(want - current) <= RATIO_TOL then "ok" else "clamped", pushes, current
			end
			-- Probe away from a native bound before continuing the fit.
			if attempt > 1 then
				return "clamped", pushes, current
			end
			cells = -cells
		else
			pushes += 1
			unit = math.abs((current - before) / cells)
			local delta = want - current
			if math.abs(delta) <= RATIO_TOL then
				return "ok", pushes, current
			end
			cells = delta / unit
		end
	end
	return "again", pushes, current
end

local function place_pane(cx: WindowCx, job: Job, mover: number, anchor: number, dir: Dir): string
	if cx.session:tab_of(anchor) ~= job.tab then
		return "retarget"
	end
	if cx.session:tab_of(mover) ~= job.tab then
		local info = cx.session:pane(mover)
		if not info or info.parked ~= true or job.owned[mover] ~= true then
			return "retarget"
		end
		local ok, err = cx.layout:move_to_tab(mover, job.tab, { focus = false })
		if not ok then
			warn_once(job, "admit", "Agent Nav: could not bring a parked pane back into its tab: " .. tostring(err))
			return "wait"
		end
		job.owned[mover] = nil
		persist(job)
	end
	local layout = cx.session:layout(job.tab)
	if layout then
		local axis, _, first = split_of_pair(layout.root, mover, anchor)
		local horizontal = dir == "left" or dir == "right"
		if axis == (if horizontal then "right" else "down") and first == (dir == "left" or dir == "up") then
			return "ok"
		end
	end
	if cx.layout:move(mover, anchor, dir, { focus = false }) then
		return "ok"
	end
	job.stuck[mover] = (job.stuck[mover] or 0) + 1
	job.owned[mover] = true
	if not persist(job) then
		job.owned[mover] = nil
		return "wait"
	end
	cx.layout:park(mover)
	if job.stuck[mover] >= 3 then
		return "retarget"
	end
	return "wait"
end

local function pending_step(cx: WindowCx, job: Job): string
	local p = job.pending
	if not p then
		return "again"
	end
	if not job.content or not has_pane(job.content, p.mover) or not has_pane(job.content, p.anchor) then
		job.pending = nil
		persist(job)
		return "again"
	end
	local layout = cx.session:layout(job.tab)
	if not layout then
		return "wait"
	end
	local peer = if p.owner == p.anchor then p.mover else p.anchor
	local actualAxis, _, first = split_of_pair(layout.root, p.owner, peer)
	if actualAxis ~= p.axis or not first then
		local placed = place_pane(cx, job, p.mover, p.anchor, toward(p.axis, p.owner == p.anchor))
		if placed == "retarget" then
			return release_job(job, "the pending placement changed outside this restore")
		end
		return if placed == "ok" then "acted" else "wait"
	end
	local status, pushes = fit_share(cx, job.tab, p.owner, p.axis, p.ratio, peer)
	if status == "lost" then
		return release_job(job, "the pending divider no longer exists")
	end
	if status == "again" then
		return "acted"
	end
	if status == "clamped" then
		warn_once(job, "fit:" .. tostring(p.owner), "Agent Nav: native pane size limits prevent the saved content ratio")
	end
	job.pending = nil
	if not persist(job) then
		job.pending = p
		return "wait"
	end
	return if pushes > 0 then "acted" else "again"
end

local function grow_walk(cx: WindowCx, job: Job, live: Tree, want: Tree): string
	local wantPane, livePane = want.pane, live.pane
	if wantPane then
		return if livePane == wantPane then "done" else "retarget"
	end
	local axis, first, second = want.axis, want.first, want.second
	if not axis or not first or not second then
		return "retarget"
	end
	if livePane then
		local inFirst = has_pane(first, livePane)
		if not inFirst and not has_pane(second, livePane) then
			return "retarget"
		end
		local mover = first_leaf(if inFirst then second else first)
		if not mover then
			return "retarget"
		end
		job.pending = {
			mover = mover,
			anchor = livePane,
			axis = axis,
			ratio = want.ratio or 0.5,
			owner = if inFirst then livePane else mover,
		}
		if not persist(job) then
			job.pending = nil
			return "wait"
		end
		return "again"
	end
	local liveFirst, liveSecond = live.first, live.second
	if live.axis ~= axis or not liveFirst or not liveSecond then
		return "retarget"
	end
	local result = grow_walk(cx, job, liveFirst, first)
	if result ~= "done" then
		return result
	end
	return grow_walk(cx, job, liveSecond, second)
end

local function gone(cx: WindowCx, job: Job, rail: number?): string
	local parked = parked_owned(cx, job)
	if #parked == 0 then
		complete(job, "tab closed")
		return "again"
	end
	if adopt_destination(cx, job, rail) then
		return "again"
	end
	local pane = parked[1]
	local info = cx.session:pane(pane)
	local session = if info then info.session else job.session

	job.dest = pane
	if not persist(job) then
		job.dest = nil
		return "wait"
	end

	local tab, err = cx.layout:move_to_new_tab(pane, session, { focus = false })
	if not tab then
		job.dest = nil
		persist(job)
		warn_once(job, "recover", "Agent Nav: could not open a tab to recover parked panes: " .. tostring(err))
		return "wait"
	end
	job.tab = tab
	job.anchor = pane
	set_stage(job, "clear")
	job.owned[pane] = nil
	if job.name then
		cx.layout:name_tab(tab, job.name)
	end
	persist(job)
	return "acted"
end

local function release_step(cx: WindowCx, job: Job): string
	local parked = parked_owned(cx, job)
	if #parked == 0 then
		complete(job, "released")
		return "again"
	end
	local pane = parked[1]
	local ok, err = cx.layout:move_to_tab(pane, job.tab, { focus = false })
	if not ok then
		warn_once(job, "release", "Agent Nav: could not return a parked pane to its tab: " .. tostring(err))
		return "wait"
	end
	job.owned[pane] = nil
	persist(job)
	return "acted"
end

local function attach_step(cx: WindowCx, job: Job, rail: number?): string
	if rail and cx.session:tab_of(rail) ~= job.tab then
		local ok, err = cx.layout:move_to_tab(rail, job.tab, { focus = false })
		if not ok then
			job.stuck[rail] = (job.stuck[rail] or 0) + 1
			if job.stuck[rail] >= 3 then
				return release_job(job, "the panel could not be attached to its tab")
			end
			warn_once(job, "attach", "Agent Nav: could not attach the panel to its tab: " .. tostring(err))
			return "wait"
		end
		lastRailTab = job.tab
		return "acted"
	end
	if cx.session:tab_of(job.anchor) ~= job.tab then
		local anchor = choose_anchor(cx, job.tab, job.content, rail)
		if not anchor then
			return empty_job(job)
		end
		job.anchor = anchor
		if cx.session:tab_of(anchor) ~= job.tab then
			if not cx.layout:move_to_tab(anchor, job.tab, { focus = false }) then
				job.stuck[anchor] = (job.stuck[anchor] or 0) + 1
				if job.stuck[anchor] >= 3 then
					return release_job(job, "the pane the restore keeps in place could not be returned to its tab")
				end
				return "wait"
			end
			job.owned[anchor] = nil
			persist(job)
			return "acted"
		end
	end
	set_stage(job, "clear")
	persist(job)
	return "again"
end

local function clear_step(cx: WindowCx, job: Job, rail: number?): string
	local content = job.content
	local live = content_of(cx, job.tab, rail)
	if not content or not live then
		return empty_job(job)
	end
	local focused = cx.session:focused()
	if focused and has_pane(live, focused) and has_pane(content, focused) then
		job.anchor, job.focus = focused, focused
	end
	local panes = leaves_of(live)
	if #panes == 0 then
		return empty_job(job)
	end
	if #panes == 1 then
		local only = panes[1]
		if only == job.anchor or has_pane(content, only) then
			job.anchor = only
			set_stage(job, "rail")
			persist(job)
			return "again"
		end
		return release_job(job, "the tab holds a pane this job never captured")
	end
	local victim: number? = nil
	for _, pane in panes do
		if pane ~= job.anchor then
			victim = pane
			break
		end
	end
	if not victim then
		return "wait"
	end
	if not has_pane(content, victim) then
		return release_job(job, "the tab gained a pane while it was being restored")
	end
	job.owned[victim] = true
	if not persist(job) then
		job.owned[victim] = nil
		warn_once(job, "park_persist", "Agent Nav: could not save ownership before parking; postponing park")
		return "wait"
	end
	local ok, err = cx.layout:park(victim)
	if not ok then
		job.owned[victim] = nil
		job.stuck[victim] = (job.stuck[victim] or 0) + 1
		persist(job)
		if job.stuck[victim] >= 3 then
			return release_job(job, "a pane could not be parked without closing it")
		end
		warn_once(job, "park", "Agent Nav: could not park a pane before restoring: " .. tostring(err))
		return "wait"
	end
	return "acted"
end

local function rail_step(cx: WindowCx, job: Job, rail: number?, layout: TabLayout): string
	if not rail or cx.session:tab_of(rail) ~= job.tab then
		set_stage(job, "grow")
		persist(job)
		return "again"
	end
	local current = railShare(layout.root, rail, job.side)
	if not current then
		local live = content_of(cx, job.tab, rail)
		if not live then
			return empty_job(job)
		end
		local panes = leaves_of(live)
		if #panes ~= 1 then
			set_stage(job, "clear")
			return "again"
		end
		local target = panes[1]
		job.anchor = target
		if not cx.layout:move(rail, target, job.side, { focus = false }) then
			job.stuck[rail] = (job.stuck[rail] or 0) + 1
			if job.stuck[rail] >= 3 then
				return release_job(job, "the panel could not be moved to its edge")
			end
			warn_once(job, "edge", "Agent Nav: could not move the panel to the " .. job.side .. " edge")
			return "wait"
		end
		lastRailTab = job.tab
		return "acted"
	end
	if math.abs(current - job.share) > SHARE_TOL and not is_clamped(job.tab, job.side, job.share) then
		local status, pushes, attained = fit_share(cx, job.tab, rail, "right", job.share)
		if attained then
			appliedShare, appliedTab = attained, job.tab
		end
		if pushes > 0 then
			if status == "clamped" then
				remember_clamp(job)
			end
			return "acted"
		end
		if status == "clamped" then
			remember_clamp(job)
		end
	end
	set_stage(job, "grow")
	persist(job)
	return "again"
end

local function grow_step(cx: WindowCx, job: Job, rail: number?): string
	local content = job.content
	local live = content_of(cx, job.tab, rail)
	if not content or not live then
		return empty_job(job)
	end
	if job.pending then
		return pending_step(cx, job)
	end
	local result = grow_walk(cx, job, live, content)
	if result == "acted" or result == "again" then
		return result
	end
	if result == "done" then
		set_stage(job, "verify")
		persist(job)
		return "again"
	end
	if result == "retarget" then
		return release_job(job, "the tab changed while it was being restored")
	end
	return "wait"
end

local function report_drift(job: Job, live: Tree, want: Tree)
	local worst = 0.0
	local function walk(a: Tree, b: Tree)
		local af, bf, as, bs = a.first, b.first, a.second, b.second
		if not af or not bf or not as or not bs then
			return
		end
		worst = math.max(worst, math.abs((a.ratio or 0.5) - (b.ratio or 0.5)))
		walk(af, bf)
		walk(as, bs)
	end
	walk(live, want)
	if worst > SHARE_TOL and not job.warned.drift then
		job.warned.drift = true
		tern.log.info(string.format(
			"Agent Nav: a restored divider sits %.3f from its saved ratio (native resize reaches only the nearest divider of an axis)",
			worst))
	end
end

local function verify_step(cx: WindowCx, job: Job, rail: number?, layout: TabLayout): string
	local content = job.content
	local live = content_of(cx, job.tab, rail)
	if not content then
		return release_job(job, "nothing left to restore")
	end
	if not live or not same_shape(live, content) then
		set_stage(job, "grow")
		persist(job)
		return "again"
	end
	if #parked_owned(cx, job) > 0 then
		set_stage(job, "grow")
		persist(job)
		return "again"
	end
	if rail and cx.session:tab_of(rail) == job.tab then
		local current = railShare(layout.root, rail, job.side)
		if not current then
			set_stage(job, "clear")
			persist(job)
			return "again"
		end
		if math.abs(current - job.share) > SHARE_TOL and not is_clamped(job.tab, job.side, job.share) then
			local status, pushes, attained = fit_share(cx, job.tab, rail, "right", job.share)
			if attained then
				appliedShare, appliedTab = attained, job.tab
			end
			if pushes > 0 then
				if status == "clamped" then
					remember_clamp(job)
				end
				return "acted"
			end
		end
		appliedShare, appliedTab = railShare(layout.root, rail, job.side) or current, job.tab
	end
	report_drift(job, live, content)
	local wanted = job.focus
	if wanted and cx.session:tab_of(wanted) == job.tab then
		local focused = cx.session:focused()
		local info = if focused then cx.session:pane(focused) else nil
		local genuinelyLost = not focused or not info or info.parked == true or (focused == rail and info.tab == job.tab)
		if genuinelyLost and cx.session:pane(wanted) then
			cx.layout:focus(wanted)
			return "acted"
		end
	end
	complete(job, "restored")
	return "again"
end

local function step(cx: WindowCx, job: Job, rail: number?): string
	local layout = cx.session:layout(job.tab)
	if not layout then
		return gone(cx, job, rail)
	end
	local stage = job.stage
	if stage == "release" then
		return release_step(cx, job)
	end
	if stage == "attach" then
		return attach_step(cx, job, rail)
	end
	if stage == "clear" then
		return clear_step(cx, job, rail)
	end
	if stage == "rail" then
		return rail_step(cx, job, rail, layout)
	end
	if stage == "grow" then
		return grow_step(cx, job, rail)
	end
	return verify_step(cx, job, rail, layout)
end

local function reconcile(cx: WindowCx, job: Job, rail: number?)
	if job.dest and not cx.session:pane(job.dest) then
		job.dest = nil
	end
	adopt_destination(cx, job, rail)

	for pane in job.owned do
		local info = cx.session:pane(pane)
		if not info or info.parked ~= true then
			job.owned[pane] = nil
		end
	end

	local content = job.content
	if content then
		local pruned: Tree? = content
		for _, pane in leaves_of(content) do
			if not pruned then
				break
			end
			local info = cx.session:pane(pane)
			if not info then
				pruned = strip_pane(pruned, pane)
			elseif job.owned[pane] ~= true then
				local tab = cx.session:tab_of(pane)
				if (tab and tab ~= job.tab) or (info.parked == true and not tab) then
					pruned = strip_pane(pruned, pane)
				end
			end
		end
		job.content = pruned
		if pruned and not has_pane(pruned, job.anchor) then
			job.anchor = choose_anchor(cx, job.tab, pruned, rail) or first_leaf(pruned) or job.anchor
		end
	end

	if job.focus and not cx.session:pane(job.focus) then
		job.focus = nil
	end
end

local function step_all(cx: WindowCx, job: Job, rail: number?): boolean
	reconcile(cx, job, rail)
	local ops = 0
	local pure = 0
	local deadline = tern.now() + ADVANCE_MS
	while ops < MAX_STEPS and pure < 16 and tern.now() < deadline do
		if state.job ~= job then
			return false
		end
		local result = step(cx, job, rail)
		if result == "acted" then
			ops += 1
			pure = 0
		elseif result == "again" then
			pure += 1
		else
			return false
		end
	end
	return ops > 0
end

local function layout_apply(cx: WindowCx, rail: number, tab: number, s: Side, wantShare: number)
	window_key(cx)
	local job = state.job
	if job then
		if job.share ~= wantShare or job.side ~= s then
			job.share, job.side = wantShare, s
			if job.stage ~= "attach" then
				set_stage(job, "clear")
			end
			state.clamped = nil
			persist(job)
		end
		return
	end

	local from = cx.session:tab_of(rail)
	if from then
		noteDrag(cx, from, rail)
	end
	share = storedShare()
	wantShare = share

	local layout = cx.session:layout(tab)
	if not layout then
		return
	end
	local content = content_of(cx, tab, rail)
	if not content then
		if layout.root and layout.root.pane == rail then
			cx.layout:park(rail)
			lastRailTab = nil
		else
			tern.log.warn("Agent Nav: layout too large or invalid; refusing to restore")
		end
		return
	end
	local placed = from == tab
	local current = if placed then railShare(layout.root, rail, s) else nil
	if placed and current then
		lastRailTab = tab
		appliedShare, appliedTab = current, tab
		if math.abs(current - wantShare) <= SHARE_TOL or is_clamped(tab, s, wantShare) then
			return
		end
	else
		lastRailTab = from or lastRailTab
	end
	local anchor = choose_anchor(cx, tab, content, rail)
	local session = session_of(cx, tab)
	if not anchor or not session then
		return
	end
	local members: { [number]: boolean } = {}
	for _, p in leaves_of(content) do
		members[p] = true
	end
	members[anchor] = true

	local focused = cx.session:focused()
	local info = tab_info(cx, tab)
	local newJob: Job = {
		seq = state.windowSeq,
		tab = tab,
		session = session,
		side = s,
		share = wantShare,
		stage = "attach",
		anchor = anchor,
		content = content,
		members = members,
		owned = {},
		focus = if focused and focused ~= rail and has_pane(content, focused) then focused else anchor,
		name = if info and info.name and info.name ~= "" then info.name else nil,
		dest = nil,
		pending = nil,
		warned = {},
		stuck = {},
	}
	if not persist(newJob) then
		warn_once(newJob, "init_persist", "Agent Nav: failed to save initial layout goal; aborting restore")
		return
	end
	state.job = newJob
end

local function layout_advance(cx: WindowCx, rail: number?): boolean
	local job = state.job
	if not job or state.advancing then
		return false
	end
	state.advancing = true
	local ok, result = pcall(step_all, cx, job, rail)
	state.advancing = false
	if not ok then
		tern.log.warn("Agent Nav layout: " .. tostring(result))
		return false
	end
	return result == true and state.job ~= nil
end

local function layout_forget(cx: WindowCx, pane: number, rail: number?)
	local job = state.job
	if not job then
		return
	end
	job.owned[pane] = nil
	if job.focus == pane then
		job.focus = nil
	end
	if job.dest == pane then
		job.dest = nil
	end
	if job.pending and (job.pending.mover == pane or job.pending.anchor == pane or job.pending.owner == pane) then
		job.pending = nil
	end
	if job.content then
		local pruned = strip_pane(job.content, pane)
		job.content = pruned
		if not pruned then
			set_stage(job, "release")
		elseif job.anchor == pane then
			job.anchor = choose_anchor(cx, job.tab, pruned, rail) or first_leaf(pruned) or job.anchor
		end
	end
	persist(job)
end

local function layout_resume(cx: WindowCx, rail: number?)
	if state.job or state.resumed then
		return
	end
	state.resumed = true
	local key = window_key(cx)
	if not key then
		return
	end
	local doc = journal_load(key)
	if not doc then
		return
	end
	local job = job_from(doc)
	if not job then
		retire_journal(tonumber(doc.seq) or 0)
		return
	end
	state.job = job
	reconcile(cx, job, rail)
	if not job.content and #parked_owned(cx, job) == 0 then
		complete(job, "nothing left to restore")
		return
	end
	tern.log.info("Agent Nav: resuming the layout of tab " .. tostring(job.tab) .. " (" .. job.stage .. ")")
end

local function layout_busy(): boolean
	return state.job ~= nil
end

local function layout_open(cx: WindowCx, tab: number, view: Node): (number?, string?)
	window_key(cx)
	if state.job then
		return nil, "layout restore in progress"
	end
	local layout = cx.session:layout(tab)
	if not layout then
		return nil, "tab layout not found"
	end
	local content = content_of(cx, tab, nil)
	if not content then
		return nil, "tab layout too large, invalid, or empty"
	end
	local anchor = choose_anchor(cx, tab, content, nil)
	local session = session_of(cx, tab)
	if not anchor or not session then
		return nil, "cannot resolve anchor or session"
	end
	local members: { [number]: boolean } = {}
	for _, p in leaves_of(content) do
		members[p] = true
	end
	members[anchor] = true

	local focused = cx.session:focused()
	local info = tab_info(cx, tab)
	local curSide = side()
	local curShare = storedShare()

	local job: Job = {
		seq = state.windowSeq,
		tab = tab,
		session = session,
		side = curSide,
		share = curShare,
		stage = "attach",
		anchor = anchor,
		content = content,
		members = members,
		owned = {},
		focus = if focused and has_pane(content, focused) then focused else anchor,
		name = if info and info.name and info.name ~= "" then info.name else nil,
		dest = nil,
		pending = nil,
		warned = {},
		stuck = {},
	}

	if not persist(job) then
		return nil, "failed to persist layout journal"
	end
	state.job = job

	local pane, err = cx.canvas:open({
		title = TITLE,
		about = ABOUT,
		view = view,
		how = "beside",
		target = anchor,
		focus = false,
		dir = curSide,
		ratio = curShare,
	})

	if not pane then
		complete(job, "canvas open failed")
		return nil, tostring(err or "canvas open failed")
	end

	return pane, nil
end

-- Persistent state tracking across ticks/events:
local wasRunning: { [number]: boolean } = {}
local unreadPanes: { [number]: boolean } = {}
type SampledPane = {
	is_running: boolean,
	ag_state: string?,
}
local sampledPanes: { [number]: SampledPane } = {}
type QueuedLaunch = {
	session: number,
	tab: number,
	target: number?,
	label: string,
	launch: Launch,
}
local queuedLaunches: { QueuedLaunch } = {}
-- Authoritative agent-block states from cx.agents:list(). Kept across ticks:
-- a failed or oversized list response (daemon frame limit) must degrade to the
-- last known state, not drop every native agent onto screen heuristics.
local agentStates: { [number]: string } = {}
-- Cached screen-state probes. Reading every navigable pane every tick overran
-- Tern's 50 ms plugin hook budget, pausing the hook with backoff and leaving
-- stale panel state. Reads are cached per pane, refreshed
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

local launchPrefix = ""
do
	local config = tern.getenv("TERN_CONFIG_DIR")
	if config ~= nil then
		launchPrefix = "TERN_CONFIG_DIR=" .. shell_quote(config) .. " "
	end
	local socket = tern.getenv("TERN_DAEMON_SOCKET")
	if socket ~= nil then
		launchPrefix ..= "TERN_DAEMON_SOCKET=" .. shell_quote(socket) .. " "
	end
end

local function launch_spec(cx: WindowCx, command: string, cwd: string?): Launch
	return {
		command = if launchPrefix ~= "" and localHost(cx) then launchPrefix .. command else command,
		cwd = cwd,
	}
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

-- Where an open action puts the new block: its own tab, or beside the block the
-- target session's shown tab displays. Missing means a new tab, and it is
-- saved separately from the UI mode above.
local function open_in_tab(): boolean
	return tern.kv.get(KV_OPEN_TAB) ~= false
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

-- True when `pane` is a leaf of the tiled tree `t` (floats are not leaves).
local function in_tree(t: any, pane: number): boolean
	if not t then
		return false
	end
	if t.pane then
		return t.pane == pane
	end
	return in_tree(t[1], pane) or in_tree(t[2], pane)
end

-- The first tiled block of `t` that is not the navigator rail.
local function first_content(t: any, rail: number?): number?
	if not t then
		return nil
	end
	if t.pane then
		return if t.pane ~= rail then t.pane else nil
	end
	return first_content(t[1], rail) or first_content(t[2], rail)
end

-- Use content in the shown tab even when the navigator holds focus.
local function shown_content(cx: WindowCx, session: number): number?
	local tab = shownTab(cx)
	if not tab then
		return nil
	end
	local owner: number? = nil
	for _, info in cx.session:tabs() do
		if info.id == tab then
			owner = info.session
			break
		end
	end
	if owner ~= session then
		return nil
	end
	local layout = cx.session:layout(tab)
	if not layout then
		return nil
	end
	local rail = slotPane
	if layout.focus and layout.focus ~= rail and in_tree(layout.root, layout.focus) then
		return layout.focus
	end
	return first_content(layout.root, rail)
end


local function open_harness(cx: WindowCx, session: number, h: Harness): boolean
	local mode = launch_ui()
	local command = if mode == "tui" then h.tui else h.chat
	if not command then
		return false
	end
	menu = nil
	local in_tab = open_in_tab()
	if cx.sessions:current().id ~= session then
		cx.sessions:switch(session)
	end
	local cwd = session_cwd(cx, session)
	if in_tab then
		local pane = cx.layout:new_tab(launch_spec(cx, command, cwd), { focus = true })
		if not pane then
			cx:toast("error", "Agent Nav: Could not open " .. h.label, "")
		end
		return true
	end

	local tab = shownTab(cx)
	local info = tab and tab_info(cx, tab)
	if not info or info.session ~= session then
		cx:toast("error", "Agent Nav: Could not open " .. h.label, "")
		return true
	end
	local target = shown_content(cx, session)
	local launch = launch_spec(cx, command, cwd)

	if layout_busy() or #queuedLaunches > 0 then
		table.insert(queuedLaunches, {
			session = session,
			tab = info.id,
			target = target,
			label = h.label,
			launch = launch,
		})
		return true
	end

	local pane: number?
	if target then
		pane = cx.layout:split(target, "right", launch, { focus = true })
	end
	if not pane then
		cx:toast("error", "Agent Nav: Could not open " .. h.label, "")
	end
	return true
end

local function flush_queued_launches(cx: WindowCx): boolean
	if layout_busy() or #queuedLaunches == 0 then
		return false
	end
	local item = table.remove(queuedLaunches, 1)
	local info = tab_info(cx, item.tab)
	local layout = if info and info.session == item.session then cx.session:layout(item.tab) else nil
	local target = if layout and item.target and in_tree(layout.root, item.target)
		then item.target
		elseif layout then first_content(layout.root, slotPane)
		else nil
	local pane: number?
	if target then
		if cx.sessions:current().id ~= item.session then
			cx.sessions:switch(item.session)
		end
		pane = cx.layout:split(target, "right", item.launch, { focus = true })
	end
	if not pane then
		cx:toast("error", "Agent Nav: Could not open " .. item.label, "")
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
	place = {
		pattern = "^(%d+):(%a+)$",
		run = function(_cx, session, value)
			if not menu or menu.session ~= session or (value ~= "tab" and value ~= "block") then
				return false
			end
			tern.kv.set(KV_OPEN_TAB, value == "tab")
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
		icon_button(new_key(session), "plus", if open_in_tab() then "New agent tab" else "New agent block"),
		icon_button(menu_key(session), "more", "Choose a harness"),
	})
end

local function switch_row(label: string, key: string, on: boolean): Node
	return ui.el("div", { class = "agent-nav-mode" }, {
		ui.el("span", { text = label }),
		ui.el("button", {
			key = key, actions = { click = key },
			class = "agent-nav-mode-switch" .. (if on then " is-on" else ""),
			attrs = { role = "switch", ["aria-label"] = label, ["aria-checked"] = tostring(on) },
		}, { ui.el("span", { class = "agent-nav-switch-thumb" }) }),
	})
end

local function menu_node(m: Menu): Node
	local selected = launch_ui()
	local enabled = selected == "chat"
	local mode_key = "mode:" .. tostring(m.session) .. ":" .. (if enabled then "tui" else "chat")
	local in_tab = open_in_tab()
	local place_key = "place:" .. tostring(m.session) .. ":" .. (if in_tab then "block" else "tab")
	local rows: { Node } = {
		switch_row("Enable Tern UI", mode_key, enabled),
		switch_row("Open in new tab", place_key, in_tab),
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

local function sample_status(cx: WindowCx)
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

	local freshSampled: { [number]: SampledPane } = {}
	for _, p in cx.session:panes() do
		if is_navigable_pane(p) then
			local is_focused = p.focused == true
			local is_running = false
			local ag_state: string? = agentStates[p.pane]
			local spinning = spinnerTitle(p.title) or spinnerTitleSuffix(p.title)
			local busyWorking = p.busy == true and not p.at_prompt
			if ag_state == "working" or ag_state == "waiting_input" then
				is_running = ag_state == "working"
			else
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

			freshSampled[p.pane] = {
				is_running = is_running,
				ag_state = ag_state,
			}
		end
	end
	sampledPanes = freshSampled
end

local function build_view(cx: WindowCx): Node
	if next(sampledPanes) == nil then
		sample_status(cx)
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

			local sampled = sampledPanes[p.pane]
			local is_running = if sampled then sampled.is_running else false
			local ag_state = if sampled then sampled.ag_state else nil

			-- Status precedence:
			-- 1. Attention (waiting for user input / approval): purple
			-- 2. Running: amber/yellow with text shimmer
			-- 3. Error: red (nonzero native exited or error outranks unread)
			-- 4. Done unread: emerald green
			-- 5. Done read / idle: muted secondary text
			local status = "done-read"
			if ag_state == "waiting_input" then
				status = "attention"
			elseif is_running then
				status = "running"
			elseif p.error or (p.exited and p.exited ~= 0) then
				status = "error"
			elseif not is_focused and (unreadPanes[p.pane] or p.alert) then
				status = "done-unread"
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

-- Parked rows temporarily have no tab; retain the last view while sampling
-- status transitions independently of canvas updates.
local function draw(cx: WindowCx)
	sample_status(cx)
	local pane = slot(cx)
	if not pane then
		return
	end
	if layout_busy() and pane == renderedPane then
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

-- Capture the content goal before opening the canvas changes its split tree.
local function openPanel(cx: WindowCx, tab: number)
	local view = build_view(cx)
	local pane, err = layout_open(cx, tab, view)
	if not pane then
		cx:toast("error", "Agent Nav: Could not open panel", tostring(err))
		return
	end
	slotPane = pane
	rendered, renderedPane = tern.json.encode(view), pane
	lastRailTab = cx.session:tab_of(pane)
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

local following = false
-- Set by the last follow when the controller actually moved something.
local progressed = false
local kickPending = false
local resumed = false

-- Keep the panel in the active tab. Everything that moves a pane is the
-- controller's job: this only decides where the rail belongs and lets the
-- controller advance the restore it owns.
local function follow(cx: WindowCx, tab: number?)
	progressed = false
	if following or not localHost(cx) or not idsResolve(cx) then
		return
	end
	following = true
	local ok, err = pcall(function()
		if not resumed then
			resumed = true
			local ok_res, err_res = pcall(layout_resume, cx, slot(cx))
			if not ok_res then
				tern.log.warn("Agent Nav resume: " .. tostring(err_res))
			end
		end
		if not layout_busy() and #queuedLaunches > 0 then
			progressed = flush_queued_launches(cx)
		end

		local pane = slot(cx)
		local shown = shownTab(cx) or tab
		if not pane then
			if layout_busy() or not wantPanel or not shown then
				progressed = layout_advance(cx, nil)
				return
			end
			-- Reopen if closed with its tab; leave closed if user explicitly closed it.
			for _, info in cx.session:tabs() do
				if info.id == lastRailTab then
					setWantPanel(false)
					lastRailTab = nil
					return
				end
			end
			openPanel(cx, shown)
			pane = slotPane
			if not pane then
				return
			end
		end
		if not wantPanel then
			setWantPanel(true)
		end
		if not shown then
			progressed = layout_advance(cx, pane)
			return
		end
		layout_apply(cx, pane, shown, side(), share)
		progressed = layout_advance(cx, pane)
	end)
	if ok and not layout_busy() and #queuedLaunches > 0 then
		progressed = true
	end
	following = false
	if not ok then
		tern.log.warn("Agent Nav follow: " .. tostring(err))
	end
end

local function followAndDraw(cx: WindowCx?, tab: number?)
	if not cx then
		return
	end
	follow(cx, tab)
	if progressed and not kickPending then
		kickPending = true
		tern.timer(FAST_TICK_MS, function(next_cx: WindowCx?)
			kickPending = false
			followAndDraw(next_cx)
		end)
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
			slotPane, rendered, renderedPane = nil, nil, nil
			menu = nil
			lastRailTab = nil
			-- A job that still owns parked panes keeps them: closing the rail is
			-- not a reason to abandon their tab, and the feature stays off.
			cx.layout:close(pane)
			return
		end
		setWantPanel(true)
		lastRailTab = nil
		appliedShare, appliedTab = nil, nil
		state.clamped = nil
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
		state.clamped = nil
		followAndDraw(cx)
	end,
})

tern.command({
	id = "reset_width",
	title = "Agent Nav: Reset Width",
	run = function(cx)
		tern.kv.set(KV_SHARE, nil)
		share = DEFAULT_SHARE
		appliedShare, appliedTab = nil, nil
		state.clamped = nil
		-- The controller re-fits the rail: a finished tab only re-sizes the root
		-- divider, an unfinished restore carries the new width through.
		followAndDraw(cx)
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

-- A pane the host closed is dropped from the restore's goal and from what the
-- job still owes; the job itself stays until nothing is parked.
tern.on("pane_closed", function(ev: PaneEvent, cx: WindowCx)
	wasRunning[ev.pane] = nil
	unreadPanes[ev.pane] = nil
	sampledPanes[ev.pane] = nil
	layout_forget(cx, ev.pane, slot(cx))
	followAndDraw(cx)
end)

tern.on("tab_closed", function(ev: TabEvent, cx: WindowCx)
	if lastRailTab == ev.tab then
		lastRailTab = nil
	end
	followAndDraw(cx)
end)

-- A session that ended took its panes with it; the controller retires only the
-- members that are actually gone and never launches a program to replace one.
tern.on("session_ended", function(_ev: SessionEndedEvent, cx: WindowCx)
	followAndDraw(cx)
end)

-- Re-render immediately on window events, pane title changes, and agent turn completions.
for _, name in { "tab_created", "pane_created", "title", "agent_finished" } do
	tern.on(name, function(_ev: any, cx: WindowCx)
		followAndDraw(cx)
	end)
end

-- A window that starts again resumes the restore its journal still owns before
-- following the newest placement, so parked panes are never left behind.
tern.on("window_start", function(cx: WindowCx)
	resumed = true
	local ok, err = pcall(layout_resume, cx, slot(cx))
	if not ok then
		tern.log.warn("Agent Nav resume: " .. tostring(err))
	end
	followAndDraw(cx)
end)

local function tick(cx: WindowCx?)
	followAndDraw(cx)
	tern.timer(TICK_MS, tick)
end
tern.timer(TICK_MS, tick)
