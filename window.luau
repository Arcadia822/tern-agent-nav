-- window.luau
-- Agent-Navigations: Agent Block Navigator across sessions for Tern

local DEFAULT_SIDE = "right"
local DEFAULT_OPEN_MODE = "on_agent" -- "always" | "on_agent" | "manual"
local DEFAULT_WIDTH_COLS = 28        -- Approx 240px in standard terminal font

-- Helper to read settings
local function get_side(): string
    local val = tern.kv.get("agent_nav.side")
    if val == "left" or val == "right" then
        return val
    end
    return DEFAULT_SIDE
end

local function set_side(side: string)
    tern.kv.set("agent_nav.side", side)
end

local function get_open_mode(): string
    local val = tern.kv.get("agent_nav.open_mode")
    if val == "always" or val == "on_agent" or val == "manual" then
        return val
    end
    return DEFAULT_OPEN_MODE
end

local function set_open_mode(mode: string)
    tern.kv.set("agent_nav.open_mode", mode)
end

-- Detect harness from agent command / kind
local function detect_harness(command: string?, model: string?): string
    local harness = "agent"
    if command then
        local lower_cmd = string.lower(command)
        if string.find(lower_cmd, "omp") then
            harness = "omp"
        elseif string.find(lower_cmd, "acp") then
            harness = "acp"
        elseif string.find(lower_cmd, "carly") then
            harness = "carly"
        elseif string.find(lower_cmd, "claude") then
            harness = "claude"
        elseif string.find(lower_cmd, "codex") then
            harness = "codex"
        else
            -- extract first token as binary name
            local first_word = string.match(command, "^%s*([^%s]+)")
            if first_word then
                -- strip directory path
                local bin_name = string.match(first_word, "([^/\\]+)$") or first_word
                harness = bin_name
            end
        end
    end

    if model and model ~= "" then
        -- shorten model name e.g. claude-3-7-sonnet -> sonnet-3.7
        local short_model = model
        if string.find(model, "sonnet") then
            short_model = "sonnet"
        elseif string.find(model, "haiku") then
            short_model = "haiku"
        elseif string.find(model, "opus") then
            short_model = "opus"
        elseif string.find(model, "gpt%-4o") then
            short_model = "gpt-4o"
        elseif string.find(model, "o3") or string.find(model, "o1") then
            short_model = string.match(model, "[%w%-]+") or model
        end
        return string.format("%s • %s", harness, short_model)
    end

    return harness
end

-- Extract agent title
local function get_agent_title(agent_pane: number, cwd: string, cx: WindowCx): string
    local p_info = cx.session:pane(agent_pane)
    if p_info and p_info.title and p_info.title ~= "" and p_info.title ~= "agent" and p_info.title ~= "omp" then
        return p_info.title
    end
    -- Fallback to last folder of cwd
    local folder = string.match(cwd, "([^/]+)$")
    if folder and folder ~= "" then
        return folder
    end
    return string.format("Block #%d", agent_pane)
end

-- Data struct: group agents by session
type AgentItem = {
    pane: number,
    harness: string,
    title: string,
    status: string,
    status_icon: string,
    status_tone: string,
    last_message: string?,
    delivery_error: string?,
    cwd: string,
}

type SessionGroup = {
    id: number,
    name: string,
    current: boolean,
    agents: { AgentItem },
}

local function collect_session_groups(cx: WindowCx): ({ SessionGroup }, number, number)
    local all_agents = cx.agents:list()
    local sessions = cx.session:sessions()
    local tabs = cx.session:tabs()

    -- map tab_id -> session_id
    local tab_to_session = {}
    for _, t in tabs do
        tab_to_session[t.id] = t.session
    end

    -- map session_id -> SessionGroup
    local session_order = {}
    local session_map = {}
    for _, s in sessions do
        local grp: SessionGroup = {
            id = s.id,
            name = s.name,
            current = s.current,
            agents = {},
        }
        session_map[s.id] = grp
        table.insert(session_order, grp)
    end

    local total_agents = #all_agents
    local waiting_count = 0

    for _, a in all_agents do
        local tab_id = cx.session:tab_of(a.pane)
        local s_id = tab_id and tab_to_session[tab_id]
        local grp = s_id and session_map[s_id]

        if not grp then
            -- Fallback to current session
            local cur = cx.sessions:current()
            grp = session_map[cur.id]
        end

        local harness = detect_harness(a.command, a.model)
        local title = get_agent_title(a.pane, a.cwd, cx)

        local status_text = a.state
        local status_icon = "⚪"
        local status_tone = "neutral"

        if a.state == "working" then
            status_text = "Working"
            status_icon = "🟡"
            status_tone = "warn"
        elseif a.state == "waiting_input" then
            status_text = "Waiting Input"
            status_icon = "❓"
            status_tone = "bad"
            waiting_count = waiting_count + 1
        elseif a.state == "idle" then
            status_text = "Idle"
            status_icon = "🟢"
            status_tone = "good"
        elseif a.state == "exited" then
            status_text = "Exited"
            status_icon = "⚪"
            status_tone = "neutral"
        end

        local item: AgentItem = {
            pane = a.pane,
            harness = harness,
            title = title,
            status = status_text,
            status_icon = status_icon,
            status_tone = status_tone,
            last_message = a.last_message,
            delivery_error = a.delivery_error,
            cwd = a.cwd,
        }

        if grp then
            table.insert(grp.agents, item)
        end
    end

    return session_order, total_agents, waiting_count
end

-- Build the UI Node tree
local function build_view(session_groups: { SessionGroup }, total_agents: number, waiting_count: number): Node
    local rows = {}

    -- Overview header
    local summary_text = string.format("Total: %d agent%s", total_agents, total_agents == 1 and "" or "s")
    if waiting_count > 0 then
        summary_text = summary_text .. string.format(" • %d waiting input!", waiting_count)
    end

    table.insert(rows, tern.ui.text({
        tern.ui.span("Agent Radar ", "bold"),
        tern.ui.span(summary_text, waiting_count > 0 and "bad" or "dim"),
    }))
    table.insert(rows, tern.ui.rule({}))

    if #session_groups == 0 or total_agents == 0 then
        table.insert(rows, tern.ui.text({
            tern.ui.span("No active agents found.", "dim"),
        }))
        return tern.ui.col(rows)
    end

    for _, s in session_groups do
        local session_header_spans = {
            tern.ui.span(string.format("Session: %s", s.name), s.current and "bold" or "normal"),
        }
        if s.current then
            table.insert(session_header_spans, tern.ui.span(" [Current]", "accent"))
        end
        table.insert(session_header_spans, tern.ui.span(string.format(" (%d)", #s.agents), "dim"))

        local agent_nodes = {}
        if #s.agents == 0 then
            table.insert(agent_nodes, tern.ui.text({
                tern.ui.span("  No agents in this session", "dim"),
            }))
        else
            for _, a in s.agents do
                local card_children = {}

                -- Line 1: Harness + Status Badge
                table.insert(card_children, tern.ui.row({
                    tern.ui.badge(string.format("%s %s", a.status_icon, a.status), a.status_tone),
                    tern.ui.text({ tern.ui.span(" " .. a.harness, "accent") }),
                }))

                -- Line 2: Title (Project / CWD / Command)
                table.insert(card_children, tern.ui.text({
                    tern.ui.span("📌 " .. a.title, "bold"),
                }))

                -- Line 3: Delivery error if present
                if a.delivery_error and a.delivery_error ~= "" then
                    table.insert(card_children, tern.ui.text({
                        tern.ui.span("⚠️ " .. a.delivery_error, "bad"),
                    }))
                end

                -- Line 4: Last message snippet
                if a.last_message and a.last_message ~= "" then
                    local snippet = a.last_message
                    if #snippet > 80 then
                        snippet = string.sub(snippet, 1, 77) .. "..."
                    end
                    table.insert(card_children, tern.ui.text({
                        tern.ui.span(snippet, "dim"),
                    }))
                end

                -- Action button to jump
                local jump_key = string.format("jump:%d:%d", s.id, a.pane)
                table.insert(card_children, tern.ui.el("button", {
                    key = jump_key,
                    class = "jump-btn",
                    text = "Focus Agent →",
                }))

                local card = tern.ui.card({}, card_children)
                table.insert(agent_nodes, card)
            end
        end

        table.insert(rows, tern.ui.section(session_header_spans, agent_nodes))
    end

    return tern.ui.col(rows)
end

-- Build the bottom dock controls
local function build_dock(): Node
    local side = get_side()
    local mode = get_open_mode()

    local side_label = (side == "left") and "Side: ⬅ Left" or "Side: ➡ Right"
    local mode_label = string.format("Mode: %s", mode)

    return tern.ui.row({
        tern.ui.el("button", {
            key = "cfg:toggle_side",
            text = side_label,
        }),
        tern.ui.el("button", {
            key = "cfg:toggle_mode",
            text = mode_label,
        }),
        tern.ui.el("button", {
            key = "action:refresh",
            text = "↻",
        }),
    })
end

-- Manage open canvas pane ID
local active_canvas_pane: number? = nil

-- Check if canvas exists in current tab
local function find_existing_canvas(cx: WindowCx): number?
    local canvases = cx.canvas:list()
    for _, c in canvases do
        if c.owner == "plugin:agent-nav" then
            return c.pane
        end
    end
    return nil
end

-- Update existing canvas
local function update_canvas(pane: number, cx: WindowCx)
    local groups, total, waiting = collect_session_groups(cx)
    local view_node = build_view(groups, total, waiting)
    local dock_node = build_dock()

    cx.canvas:set(pane, {
        title = "Agent Nav",
        view = view_node,
        dock = dock_node,
    })
end

-- Open canvas in the configured side
local function open_or_refresh_canvas(cx: WindowCx): number?
    local existing = find_existing_canvas(cx)
    if existing then
        active_canvas_pane = existing
        update_canvas(existing, cx)
        return existing
    end

    local side = get_side()
    local groups, total, waiting = collect_session_groups(cx)
    local view_node = build_view(groups, total, waiting)
    local dock_node = build_dock()

    local pane, err = cx.canvas:open({
        title = "Agent Nav",
        view = view_node,
        dock = dock_node,
        about = "Agent Navigator across sessions",
        how = "beside",
        focus = false,
    })

    if not pane then
        tern.log.error("Failed to open Agent Nav canvas: " .. tostring(err))
        return nil
    end

    active_canvas_pane = pane

    -- Position left or right
    local focused_pane = cx.session:focused()
    if focused_pane and focused_pane ~= pane then
        if side == "left" then
            cx.layout:move(pane, focused_pane, "left", { focus = false })
        else
            cx.layout:move(pane, focused_pane, "right", { focus = false })
        end
    end

    -- Resize to ~240px (~28 columns)
    local pane_info = cx.session:pane(pane)
    if pane_info and pane_info.cols then
        local delta = pane_info.cols - DEFAULT_WIDTH_COLS
        if delta > 0 then
            cx.layout:resize(pane, side == "left" and "right" or "left", -delta)
        end
    end

    return pane
end

-- Check auto-open based on setting
local function check_auto_open(cx: WindowCx)
    local mode = get_open_mode()
    if mode == "manual" then
        local existing = find_existing_canvas(cx)
        if existing then
            update_canvas(existing, cx)
        end
        return
    end

    if mode == "always" then
        open_or_refresh_canvas(cx)
        return
    end

    if mode == "on_agent" then
        local agents = cx.agents:list()
        if #agents > 0 then
            open_or_refresh_canvas(cx)
        else
            local existing = find_existing_canvas(cx)
            if existing then
                update_canvas(existing, cx)
            end
        end
    end
end

-- Event: canvas action
tern.on("canvas_action", function(ev: CanvasAction, cx: WindowCx): boolean?
    local node = ev.node or ""

    -- Jump to agent: jump:<session_id>:<pane_id>
    if string.sub(node, 1, 5) == "jump:" then
        local s_id_str, p_id_str = string.match(node, "^jump:(%d+):(%d+)$")
        local s_id = s_id_str and tonumber(s_id_str)
        local p_id = p_id_str and tonumber(p_id_str)

        if s_id then
            cx.sessions:switch(s_id)
        end
        if p_id then
            cx.layout:focus(p_id)
        end
        return true
    end

    -- Toggle side
    if node == "cfg:toggle_side" then
        local current_side = get_side()
        local new_side = (current_side == "left") and "right" or "left"
        set_side(new_side)

        if active_canvas_pane then
            local focused_pane = cx.session:focused()
            if focused_pane and focused_pane ~= active_canvas_pane then
                cx.layout:move(active_canvas_pane, focused_pane, new_side, { focus = false })
            end
            update_canvas(active_canvas_pane, cx)
        end
        cx:toast("info", "Agent Nav: Position set to " .. new_side)
        return true
    end

    -- Toggle open mode: on_agent -> always -> manual -> on_agent
    if node == "cfg:toggle_mode" then
        local current_mode = get_open_mode()
        local new_mode = "on_agent"
        if current_mode == "on_agent" then
            new_mode = "always"
        elseif current_mode == "always" then
            new_mode = "manual"
        else
            new_mode = "on_agent"
        end
        set_open_mode(new_mode)

        if active_canvas_pane then
            update_canvas(active_canvas_pane, cx)
        end
        cx:toast("info", "Agent Nav: Mode set to " .. new_mode)
        return true
    end

    -- Refresh button
    if node == "action:refresh" then
        if active_canvas_pane then
            update_canvas(active_canvas_pane, cx)
        else
            open_or_refresh_canvas(cx)
        end
        return true
    end

    return nil
end)

-- Event: agent finished / progress
tern.on("agent_finished", function(ev: AgentFinishedEvent, cx: WindowCx)
    check_auto_open(cx)
end)

-- Event: focus change
tern.on("focus", function(ev: FocusEvent, cx: WindowCx)
    check_auto_open(cx)
end)

-- Event: pane lifecycle
tern.on("pane_created", function(ev: PaneEvent, cx: WindowCx)
    check_auto_open(cx)
end)

tern.on("pane_closed", function(ev: PaneEvent, cx: WindowCx)
    if active_canvas_pane and ev.pane == active_canvas_pane then
        active_canvas_pane = nil
    end
    check_auto_open(cx)
end)

-- Event: window start
tern.on("window_start", function(cx: WindowCx)
    check_auto_open(cx)
end)

-- Periodic timer (every 3 seconds) for state sync
tern.timer(3000, function(cx: WindowCx?)
    if cx then
        check_auto_open(cx)
    end
end)

-- Command palette actions
tern.command({
    id = "toggle",
    title = "Agent Nav: Toggle Panel",
    keys = { "ctrl+alt+n" },
    run = function(cx: WindowCx)
        local existing = find_existing_canvas(cx)
        if existing then
            cx.layout:close(existing)
            active_canvas_pane = nil
        else
            open_or_refresh_canvas(cx)
        end
    end,
})

tern.command({
    id = "set_side_left",
    title = "Agent Nav: Position Left",
    run = function(cx: WindowCx)
        set_side("left")
        if active_canvas_pane then
            local focused_pane = cx.session:focused()
            if focused_pane and focused_pane ~= active_canvas_pane then
                cx.layout:move(active_canvas_pane, focused_pane, "left", { focus = false })
            end
            update_canvas(active_canvas_pane, cx)
        end
        cx:toast("info", "Agent Nav: Position set to left")
    end,
})

tern.command({
    id = "set_side_right",
    title = "Agent Nav: Position Right",
    run = function(cx: WindowCx)
        set_side("right")
        if active_canvas_pane then
            local focused_pane = cx.session:focused()
            if focused_pane and focused_pane ~= active_canvas_pane then
                cx.layout:move(active_canvas_pane, focused_pane, "right", { focus = false })
            end
            update_canvas(active_canvas_pane, cx)
        end
        cx:toast("info", "Agent Nav: Position set to right")
    end,
})

tern.command({
    id = "quick_jump",
    title = "Agent Nav: Quick Jump (Picker)",
    keys = { "ctrl+cmd+a" },
    run = function(cx: WindowCx)
        local groups = collect_session_groups(cx)
        local items = {}

        for _, s in groups do
            for _, a in s.agents do
                table.insert(items, {
                    label = string.format("[%s] %s  %s", s.name, a.status_icon, a.title),
                    detail = string.format("%s • %s", a.harness, a.status),
                    pane = a.pane,
                    session = s.id,
                })
            end
        end

        if #items == 0 then
            cx:toast("info", "No active agents found")
            return
        end

        cx:pick({
            items = items,
            placeholder = "Jump to Agent...",
        }):next(function(chosen, err, cx)
            if chosen and cx then
                cx.sessions:switch(chosen.session)
                cx.layout:focus(chosen.pane)
            end
        end)
    end,
})
