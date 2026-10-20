"""Native Tern smoke regression: python3 tests/smoke.py --existing-window [--tern /path/to/tern]

Blackbox end-to-end regression driver for tern-agent-nav against an existing running Tern GUI window.
Complies with local://tern-nav-arena-contract.md, local://tern-nav-how.md, and local://tern-nav-why.md.

Design Principles:
1. Live GUI Window Architecture:
   Tern 0.9.2 headless serve cannot dispatch recurring/delayed plugin timers in quiet time.
   Testing therefore requires an existing running Tern GUI window accessed via native `tern ctl`
   with the explicit `--existing-window` opt-in.
   No new foreground GUI windows or headless serve instances are spawned.
2. Pristine Production Code:
   Production Luau modules (*.luau, plugin.toml, styles.css) are linked directly as production source.
   No test instrumentation or coordinator stepping is injected into production code.
3. Isolated Temporary Fixture Plugin:
   A separate temporary fixture plugin (`agent-nav-smoke-fixture`) registers controlled SDK
   fixture commands (inspect public state, split content, resize content, focus/close target pane,
   create fixture agents via `cx.agents:start`, forget test host) without contaminating production.
   Absolute communication paths are embedded as safe quoted literals in the fixture source so the
   already-running GUI process requires no inherited environment variables.
   Unlinking the fixture plugin leaves exactly the 3 production commands of agent-nav.
4. Non-Destructive Session Isolation & Deterministic Restoration:
   Original user sessions, hosts, focused pane, stage viewport, and persisted Nav preferences (kv.json)
   are captured before testing.
   All tests run within isolated, uniquely named fixture sessions.
   In `finally`, only fixture-owned sessions/panes/hosts are closed; original session, host,
   viewport, and touched kv.json settings are restored.
5. No Model Invocation:
   Fixture agents are created strictly via `cx.agents:start({..., command="/bin/cat"})`, which cannot
   call a model. No global `agent-command` override is set.
6. Public State Inspection:
   State inspection operates without calling synchronous `agents:list` (only known created
   agents are queried via bounded per-pane metadata and surface, preventing historical TSP expansion).
"""

from __future__ import annotations

import argparse
import json
import os
import plistlib
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
from typing import Any, Callable, Dict, List, Optional, Set, Tuple, Union


BUDGET_FAILURES = (
    "exceeded its budget",
    "exceeded 50 ms",
    "plugin hook exceeded",
    "plugin handler failed",
    "plugin window entry failed",
    "plugin style sheet has errors",
    "runtime error: pane is not a canvas",
)

FIXTURE_PLUGIN_TOML = """schema = 1
id = "agent-nav-smoke-fixture"
name = "Agent Nav Smoke Fixture"
version = "0.1.0"
window = "window.luau"
"""


def build_fixture_plugin_window(inspect_path: Path, surface_path: Path, target_file: Path, tmp_cwd: Path) -> str:
    """Generate the fixture window.luau embedding absolute target paths as safe literals."""
    inspect_lit = json.dumps(str(inspect_path))
    surface_lit = json.dumps(str(surface_path))
    target_lit = json.dumps(str(target_file))
    cwd_lit = json.dumps(str(tmp_cwd))

    return f"""-- Standalone harmless test fixture plugin.
-- Paths embedded as safe literals to ensure live GUI VM can access them without process env inheritance.

local inspect_path = {inspect_lit}
local surface_path = {surface_lit}
local target_file = {target_lit}
local tmp_cwd = {cwd_lit}

local created_fixture_panes = {{}}
local known_agents = {{}}
local last_created_pane = nil

tern.command({{ id = "inspect_state", title = "Fixture: Inspect State", run = function(cx)
    if not inspect_path then return end
    local panes = cx.session:panes()
    local panes_by_id = {{}}
    for _, info in panes do panes_by_id[info.pane] = info end
    local focused = cx.session:focused()
    local focused_info = focused and panes_by_id[focused]
    local tab = focused_info and focused_info.tab

    local layout = tab and cx.session:layout(tab)

    local canvases = cx.canvas:list()
    local current_host = cx.hosts:current()
    local members = {{}}
    if current_host and current_host.panes then
        for _, pane in current_host.panes do members[pane] = true end
    end
    local nav_canvases = {{}}
    for _, c in canvases do
        if c.owner == "agent-nav" and members[c.pane] then
            local c_info = panes_by_id[c.pane]
            local c_tab = c_info and c_info.tab
            table.insert(nav_canvases, {{
                pane = c.pane,
                tab = c_tab,
                owner = c.owner,
            }})
        end
    end

    -- Inspect agents without synchronous agents:list:
    -- Query only known created agent panes via bounded per-pane metadata and surface,
    -- completely avoiding any call to cx.agents:list() and preventing user history expansion.
    local agents = {{}}
    for pane, _ in pairs(known_agents) do
        local p_info = cx.session:pane(pane)
        if p_info then
            local agent_state = "idle"
            local ok_s, tree = pcall(function()
                return cx.session:surface(pane, {{ depth = 0, nodes = 10, max_chars = 64 }})
            end)
            if ok_s and type(tree) == "table" then
                local dock_id = tree.dock and type(tree.dock) == "table" and tree.dock.id
                local layer_id = tree.layer and type(tree.layer) == "table" and tree.layer.id
                local waiting = false
                local working = false

                local function scan_node(node)
                    if type(node) ~= "table" then return end
                    local props = type(node.p) == "table" and node.p or nil
                    if props and props.hidden == true then return end
                    if props then
                        local role = props.role
                        local st = props.state
                        if st == "waiting" or role == "omp.editor.ask" or role == "omp.editor.ask.approval"
                            or role == "omp.overlay.ask" or role == "omp.overlay.permission"
                            or role == "omp.overlay.approval" then
                            waiting = true
                        elseif st == "working" or role == "omp.working" then
                            working = true
                        end
                    end
                    if type(node.c) == "table" then
                        for _, child in node.c do scan_node(child) end
                    end
                end

                if type(dock_id) == "string" and dock_id ~= "" then
                    local ok_d, dock_tree = pcall(function()
                        return cx.session:surface(pane, {{ root = dock_id, depth = 2, nodes = 32, max_chars = 1024 }})
                    end)
                    if ok_d and type(dock_tree) == "table" and type(dock_tree.main) == "table" then
                        scan_node(dock_tree.main)
                    end
                end

                if type(layer_id) == "string" and layer_id ~= "" then
                    local ok_l, layer_tree = pcall(function()
                        return cx.session:surface(pane, {{ root = layer_id, depth = 2, nodes = 32, max_chars = 1024 }})
                    end)
                    if ok_l and type(layer_tree) == "table" and type(layer_tree.main) == "table" then
                        scan_node(layer_tree.main)
                    end
                end

                if waiting then
                    agent_state = "waiting_input"
                elseif working or p_info.busy == true then
                    agent_state = "working"
                elseif p_info.exited then
                    agent_state = "exited"
                end
            elseif p_info.busy == true then
                agent_state = "working"
            elseif p_info.exited then
                agent_state = "exited"
            end

            table.insert(agents, {{
                pane = pane,
                state = agent_state,
                delivery_error = p_info.error,
            }})
        end
    end

    local layouts = {{}}
    for _, item in cx.session:tabs() do
        layouts[tostring(item.id)] = cx.session:layout(item.id)
    end
    local sessions = cx.session:sessions()
    local current_session
    for _, item in sessions do
        if item.current then current_session = item.id; break end
    end
    local data = {{
        focused = focused,
        current_tab = tab,
        current_session = current_session,
        current_host = current_host,
        hosts = cx.hosts:list(),
        layouts = layouts,
        layout = layout,
        canvases = canvases,
        nav_canvases = nav_canvases,
        agents = agents,
        sessions = sessions,
        tabs = cx.session:tabs(),
        panes = panes,
        last_created_pane = last_created_pane,
    }}
    tern.fs.write(inspect_path, tern.json.encode(data))
end }})

tern.command({{ id = "create_fixture_agent", title = "Fixture: Create Agent", run = function(cx)
    local how = "tab"
    if target_file then
        local content = tern.fs.read(target_file)
        if content then
            local trimmed = string.match(content, "^%s*(.-)%s*$")
            if trimmed == "split" or trimmed == "tab" or trimmed == "replace_if_alone" then
                how = trimmed
            end
        end
    end
    local pane = cx.agents:start({{
        prompt = "native no-model fixture",
        cwd = tmp_cwd,
        command = "/bin/cat",
        how = how,
    }})
    if pane then
        created_fixture_panes[pane] = true
        known_agents[pane] = true
        last_created_pane = pane
        pcall(function() cx.layout:focus(pane) end)
    end
end }})

for _, dir in {{ "down", "right" }} do
    local direction = dir
    tern.command({{ id = "split_content_" .. direction, title = "Fixture: Split " .. direction, run = function(cx)
        local focused = cx.session:focused()
        if focused then
            local p = cx.layout:split(focused, direction, nil, {{ focus = true }})
            if p then
                created_fixture_panes[p] = true
                last_created_pane = p
            end
        end
    end }})
end

tern.command({{ id = "resize_content", title = "Fixture: Resize Content", run = function(cx)
    local text = target_file and tern.fs.read(target_file)
    if not text then return end
    local pane, direction, cells = string.match(text, "^(%d+) ([%a]+) ([%-%d%.]+)$")
    if pane and cx.session:pane(tonumber(pane)) then
        cx.layout:resize(tonumber(pane), direction, tonumber(cells))
    end
end }})

tern.command({{ id = "focus_target_pane", title = "Fixture: Focus Target Pane", run = function(cx)
    if not target_file then return end
    local content = tern.fs.read(target_file)
    if not content then return end
    local target = tonumber(string.match(content, "^%s*(.-)%s*$"))
    if target and cx.session:pane(target) then
        cx.layout:focus(target)
    end
end }})

tern.command({{ id = "close_target_pane", title = "Fixture: Close Target Pane", run = function(cx)
    if not target_file then return end
    local content = tern.fs.read(target_file)
    if not content then return end
    local target = tonumber(string.match(content, "^%s*(.-)%s*$"))
    if target and cx.session:pane(target) then
        cx.layout:close(target)
        created_fixture_panes[target] = nil
        known_agents[target] = nil
    end
end }})

tern.command({{ id = "create_fixture_session", title = "Fixture: Create Session", run = function(cx)
    if not target_file then return end
    local content = tern.fs.read(target_file)
    if not content then return end
    local session_name = string.match(content, "^%s*(.-)%s*$")
    if session_name and session_name ~= "" then
        local ms = cx.sessions:create({{ name = session_name, cwd = tmp_cwd }})
        if ms then
            pcall(function() cx.sessions:switch(ms.id or session_name) end)
            for _, s in cx.session:sessions() do
                if s.id == ms.id or s.name == session_name then
                    if s.tabs and s.tabs[1] then
                        for _, p in cx.session:panes() do
                            if p.tab == s.tabs[1] then
                                pcall(function() cx.layout:focus(p.pane) end)
                                break
                            end
                        end
                    end
                    break
                end
            end
        end
    end
end }})

tern.command({{ id = "switch_fixture_session", title = "Fixture: Switch Session", run = function(cx)
    if not target_file then return end
    local content = tern.fs.read(target_file)
    if not content then return end
    local session_name = string.match(content, "^%s*(.-)%s*$")
    if session_name and session_name ~= "" then
        local sid = tonumber(session_name)
        pcall(function() cx.sessions:switch(sid or session_name) end)
    end
end }})

tern.command({{ id = "close_fixture_session", title = "Fixture: Close Fixture Session", run = function(cx)
    if not target_file then return end
    local content = tern.fs.read(target_file)
    if not content then return end
    local session_name = string.match(content, "^%s*(.-)%s*$")
    if session_name and session_name ~= "" then
        local sid = tonumber(session_name)
        pcall(function() cx.sessions:close(sid or session_name) end)
    end
end }})

tern.command({{ id = "create_fixture_tab", title = "Fixture: Create Tab", run = function(cx)
    local tid = cx.layout:new_tab(nil, {{ focus = true }})
    if tid then
        last_created_pane = tid
    end
end }})

tern.command({{ id = "forget_test_host", title = "Fixture: Forget Test Host", run = function(cx)
    if not target_file then return end
    local content = tern.fs.read(target_file)
    if not content then return end
    local host_spec = string.match(content, "^%s*(.-)%s*$")
    if host_spec and host_spec ~= "" then
        local host_id = tonumber(host_spec)
        pcall(function() cx.hosts:disconnect(host_id or host_spec) end)
    end
end }})

tern.command({{ id = "surface_probe", title = "Fixture: Surface Probe", run = function(cx)
    if not surface_path then return end
    local pane = target_file and tonumber(tern.fs.read(target_file) or "") or cx.session:focused()
    if not pane then return end
    local roots = cx.session:surface(pane, {{ depth = 0, nodes = 10, max_chars = 64 }})
    local res = {{ pane = pane, roots = roots }}
    if type(roots) == "table" then
        for _, region in {{ "dock", "layer" }} do
            local node = roots[region]
            if type(node) == "table" and node.id then
                res[region] = cx.session:surface(pane, {{
                    root = node.id, depth = 3, nodes = 32, max_chars = 1024,
                }})
            end
        end
    end
    tern.fs.write(surface_path, tern.json.encode(res))
end }})
"""


def text_content(node: Dict[str, Any]) -> str:
    return (node.get("text") or "").strip()


def project_content_tree(tree: Optional[Dict[str, Any]], nav_pane: int) -> Optional[Dict[str, Any]]:
    """Extract the content subtree excluding the navigator pane."""
    if not tree:
        return None
    if "pane" in tree:
        return {"pane": tree["pane"]} if tree["pane"] != nav_pane else None
    first = project_content_tree(tree.get("1") or tree.get("first"), nav_pane)
    second = project_content_tree(tree.get("2") or tree.get("second"), nav_pane)
    if not first:
        return second
    if not second:
        return first
    return {
        "split": tree.get("split"),
        "ratio": tree.get("ratio", 0.5),
        "first": first,
        "second": second,
    }


def same_content_tree(first: Optional[Dict[str, Any]], second: Optional[Dict[str, Any]]) -> bool:
    """Compare two projected content trees by pane IDs, split orientations, and ratios with 1e-3 precision."""
    if not first or not second:
        return first == second
    if "pane" in first or "pane" in second:
        return first.get("pane") == second.get("pane")
    return (
        first.get("split") == second.get("split")
        and abs(first.get("ratio", 0.5) - second.get("ratio", 0.5)) < 1e-3
        and same_content_tree(first.get("first"), second.get("first"))
        and same_content_tree(first.get("second"), second.get("second"))
    )


class SmokeRunner:
    """Regression runner operating in isolated fixture sessions against an existing Tern GUI window."""

    TOUCHED_KEYS = ("agent_nav.enabled", "agent_nav.side", "agent_nav.width")

    def __init__(self, args: argparse.Namespace):
        if sys.platform == "darwin":
            state = plistlib.loads(subprocess.check_output(
                ["ioreg", "-n", "Root", "-d1", "-a"], timeout=5,
            ))

            def locked(value):
                if isinstance(value, dict):
                    return value.get("IOConsoleLocked") is True or any(locked(item) for item in value.values())
                if isinstance(value, list):
                    return any(locked(item) for item in value)
                return False

            if locked(state):
                raise RuntimeError("macOS desktop is locked. Unlock it before running the existing-window GUI regression.")

        self.args = args
        self.tern_bin = Path(args.tern).resolve()
        self.package_dir = Path(args.plugin).resolve()
        self.artifacts_dir = Path(args.artifacts).resolve() if args.artifacts else None
        self.soak_seconds = float(args.soak_seconds)
        self.click_only = bool(args.click_only)

        self.run_id = f"{int(time.time())}_{os.urandom(3).hex()}"
        self.alpha_session_name = f"Smoke Alpha {self.run_id}"
        self.beta_session_name = f"Smoke Beta {self.run_id}"
        self.gamma_session_name = f"Disposable Gamma {self.run_id}"

        self.fixture_sessions: Set[str] = set()
        self.fixture_panes: Set[int] = set()
        self.fixture_hosts: Set[str] = set()
        self.agent_panes: Dict[str, int] = {}

        self.tmp_dir: Optional[tempfile.TemporaryDirectory] = None
        self.base: Optional[Path] = None
        self.inspect_path: Optional[Path] = None
        self.surface_path: Optional[Path] = None
        self.target_file: Optional[Path] = None

        self.original_session_id: Optional[int] = None
        self.original_session_name: Optional[str] = None
        self.original_host: Optional[Dict[str, Any]] = None
        self.original_focused_pane: Optional[int] = None
        self.original_viewport: Optional[Tuple[int, int]] = None
        self.kv_path: Optional[Path] = None
        self.original_kv_bytes: Optional[bytes] = None
        self.original_kv_data: Dict[str, Any] = {}
        self.original_linked_source: Optional[Path] = None
        self.log_path: Optional[Path] = None
        self.log_start_offset: int = 0

    def find_linked_source(self) -> Optional[Path]:
        """Find the currently linked directory for the agent-nav plugin."""
        candidates = [
            Path.home() / "Library" / "Application Support" / "Tern" / "plugins" / "agent-nav.path",
            Path.home() / ".config" / "tern" / "plugins" / "agent-nav.path",
        ]
        for c in candidates:
            if c.exists():
                try:
                    target = c.read_text().strip()
                    if target:
                        return Path(target).resolve()
                except Exception:
                    pass
        return None

    def find_kv_path(self) -> Path:
        """Find the real kv.json file for the installed agent-nav plugin."""
        candidates = []
        if "TERN_PLUGIN_DATA" in os.environ:
            candidates.append(Path(os.environ["TERN_PLUGIN_DATA"]) / "agent-nav" / "kv.json")
        candidates.append(Path.home() / "Library" / "Application Support" / "Tern" / "plugin-data" / "agent-nav" / "kv.json")
        candidates.append(Path.home() / ".config" / "tern" / "plugin-data" / "agent-nav" / "kv.json")
        if "TERN_CONFIG_DIR" in os.environ:
            candidates.append(Path(os.environ["TERN_CONFIG_DIR"]) / "plugin-data" / "agent-nav" / "kv.json")
        for p in candidates:
            if p.exists():
                return p.resolve()
        app_support = Path.home() / "Library" / "Application Support" / "Tern"
        if app_support.exists():
            matches = list(app_support.glob("**/agent-nav/kv.json"))
            if matches:
                return matches[0].resolve()
        return candidates[1]

    def find_log_path(self) -> Optional[Path]:
        """Locate the main tern.log file."""
        candidates = [
            Path.home() / "Library" / "Logs" / "Tern" / "tern.log",
            Path.home() / ".local" / "share" / "tern" / "tern.log",
        ]
        for p in candidates:
            if p.exists():
                return p.resolve()
        return None

    def setup(self):
        print(f"\nSetting up isolated test environment in existing GUI window (run {self.run_id})...")

        if not self.tern_bin.exists():
            raise FileNotFoundError(f"Tern binary not found at {self.tern_bin}")

        if self.artifacts_dir:
            self.artifacts_dir.mkdir(parents=True, exist_ok=True)

        # 0. Check and link production package if --plugin specifies an alternate path (e.g. for red/green testing)
        self.original_linked_source = self.find_linked_source()
        if self.original_linked_source and self.package_dir != self.original_linked_source:
            print(f"Switching agent-nav link from {self.original_linked_source} to {self.package_dir}...")
            subprocess.run(
                [str(self.tern_bin), "plugin", "link", str(self.package_dir)],
                check=True,
                capture_output=True,
                text=True,
            )
            self.ctl("wait", "300")
        # 1. Create temporary directory for fixture plugin & communication files
        self.tmp_dir = tempfile.TemporaryDirectory(prefix="tern-nav-smoke-fixture-", dir="/tmp")
        self.base = Path(self.tmp_dir.name)
        self.inspect_path = self.base / "fixture_inspect.json"
        self.surface_path = self.base / "fixture_surface.json"
        self.target_file = self.base / "fixture_target.txt"

        fixture_dir = self.base / "fixture-plugin"
        fixture_dir.mkdir()
        (fixture_dir / "plugin.toml").write_text(FIXTURE_PLUGIN_TOML)
        # Embed absolute target paths directly in Lua source so live GUI process needs no env injection
        fixture_source = build_fixture_plugin_window(
            self.inspect_path, self.surface_path, self.target_file, self.base,
        )
        (fixture_dir / "window.luau").write_text(fixture_source)

        # 2. Record log file start offset
        self.log_path = self.find_log_path()
        if self.log_path and self.log_path.exists():
            self.log_start_offset = self.log_path.stat().st_size

        # 3. Capture persisted kv.json settings before linking fixture
        self.kv_path = self.find_kv_path()
        if self.kv_path and self.kv_path.exists():
            self.original_kv_bytes = self.kv_path.read_bytes()
            try:
                self.original_kv_data = json.loads(self.original_kv_bytes)
            except Exception:
                self.original_kv_data = {}
        else:
            self.original_kv_bytes = None
            self.original_kv_data = {}

        # Capture viewport before linking fixture
        try:
            viewport = self.ctl("dump", ".tn-stage")["header"]["viewport"]
            self.original_viewport = (int(viewport["width"]), int(viewport["height"]))
        except Exception:
            self.original_viewport = None

        # 4. Link temporary fixture plugin (triggers live plugin reload)
        subprocess.run(
            [str(self.tern_bin), "plugin", "link", str(fixture_dir)],
            check=True,
            capture_output=True,
            text=True,
        )
        self.ctl("wait", "300")

        # 5. Capture caller's original live state IMMEDIATELY upon linking fixture plugin,
        # BEFORE creating any session, mutating focus, or toggling nav
        initial_state = self.inspect_sdk_state()
        self.original_session_id = initial_state.get("current_session")
        sessions = initial_state.get("sessions", [])
        orig_s = next((s for s in sessions if s.get("id") == self.original_session_id), None)
        self.original_session_name = orig_s.get("name") if orig_s else None
        self.original_host = initial_state.get("current_host")
        self.original_focused_pane = initial_state.get("focused")
        # Ensure we operate on the local host for all fixture sessions, cats, and tmp_cwd
        hosts = initial_state.get("hosts", [])
        local_host = next((h for h in hosts if h.get("kind") == "local"), None)
        if local_host and self.original_host and self.original_host.get("id") != local_host.get("id"):
            print(f"Switching from remote host {self.original_host.get('name')} to local host {local_host.get('name')} for fixture execution...")
            self.ctl("remote", "switch", local_host["name"])
            self.ctl("wait", "200")

        # 6. Create isolated fixture session for test execution on local host via window SDK
        self.create_session(self.alpha_session_name)
        # 7. Ensure clean navigator baseline in test session (enabled, pinned right, 220px)
        self.ensure_initial_nav_state()
        state = self.inspect_sdk_state()
        current = next((s for s in state.get("sessions", []) if s.get("current")), None)
        assert current and current.get("name") == self.alpha_session_name, (
            "Navigator startup changed the active fixture session: "
            f"{current.get('name') if current else None}"
        )
        print("Isolated fixture session online and baseline verified.")

    def ensure_initial_nav_state(self):
        """Ensure navigator is enabled, on the right side, and settles at default 220px."""
        if len(self.visible(".agent-nav-root")) == 0:
            self.ctl("key", "ctrl+alt+n")
            self.ctl("wait", "250")
        self.ctl("palette", "Agent Nav: Reset Width")
        self.ctl("wait", "150")
        self.ctl("key", "enter")
        self.ctl("wait", "250")
        if len(self.visible(".agent-nav-root")) == 1:
            rx, _, rw, _ = self.nav_bounds()
            sx, _, sw, _ = self.visible(".tn-stage")[0]["rect"]
            if abs((rx + rw) - (sx + sw)) > 10.0:
                self.ctl("palette", "Agent Nav: Toggle left / right")
                self.ctl("wait", "150")
                self.ctl("key", "enter")
                self.ctl("wait", "250")
    def teardown(self):
        print("\nTearing down test environment and restoring caller state...")

        # 1. Disconnect and forget any fixture-created remote hosts
        for host in list(self.fixture_hosts):
            try:
                self.target_file.write_text(str(host))
                self.ctl("plugins", "run", "plugin.agent-nav-smoke-fixture.forget_test_host")
            except Exception:
                pass
        self.fixture_hosts.clear()

        # 2. Close ONLY local fixture-created sessions while still on local host
        for session_name in list(self.fixture_sessions):
            try:
                self.close_session(session_name)
            except Exception:
                pass
        self.fixture_sessions.clear()

        # 3. Return to caller's original host if remote switch occurred
        if self.original_host and self.original_host.get("name"):
            try:
                state = self.inspect_sdk_state()
                if state.get("current_host", {}).get("name") != self.original_host["name"]:
                    print(f"Restoring caller host back to {self.original_host['name']}...")
                    self.ctl("remote", "switch", self.original_host["name"])
                    self.ctl("wait", "200")
            except Exception:
                pass

        # 4. Switch back to original session on that host
        if self.original_session_name:
            try:
                self.switch_session(self.original_session_id or self.original_session_name)
            except Exception:
                pass

        # 5. Restore original focused pane
        if self.original_focused_pane:
            try:
                self.focus_pane(self.original_focused_pane)
            except Exception:
                pass

        # 6. Restore window viewport if resized
        if self.original_viewport:
            try:
                cur_v = self.ctl("dump", ".tn-stage")["header"]["viewport"]
                if (int(cur_v["width"]), int(cur_v["height"])) != self.original_viewport:
                    self.ctl("resize", str(self.original_viewport[0]), str(self.original_viewport[1]))
                    self.ctl("wait", "150")
            except Exception:
                pass

        # 7. Restore touched kv.json settings (preserving unrelated keys, handling absent file)
        self.restore_kv_settings()

        # 8. Unlink fixture plugin (triggers live plugin reload, syncing restored settings)
        try:
            subprocess.run(
                [str(self.tern_bin), "plugin", "unlink", "agent-nav-smoke-fixture"],
                check=False,
                capture_output=True,
                text=True,
            )
        except Exception:
            pass

        # 9. Clean up temp directory
        if self.tmp_dir:
            try:
                self.tmp_dir.cleanup()
            except Exception:
                pass

        # 10. Restore original linked production package if switched
        if self.original_linked_source and self.package_dir != self.original_linked_source:
            try:
                print(f"Restoring agent-nav link back to {self.original_linked_source}...")
                subprocess.run(
                    [str(self.tern_bin), "plugin", "link", str(self.original_linked_source)],
                    check=False,
                    capture_output=True,
                    text=True,
                )
            except Exception:
                pass

    def restore_kv_settings(self):
        """Restore exact original agent-nav settings in kv.json while preserving unrelated keys."""
        if not self.kv_path:
            return
        try:
            current_data = {}
            if self.kv_path.exists():
                try:
                    current_data = json.loads(self.kv_path.read_text())
                except Exception:
                    current_data = {}

            if self.original_kv_bytes is not None:
                # kv.json originally existed: restore touched keys to their original values or remove if absent
                for key in self.TOUCHED_KEYS:
                    if key in self.original_kv_data:
                        current_data[key] = self.original_kv_data[key]
                    else:
                        current_data.pop(key, None)
                self.kv_path.write_text(json.dumps(current_data, indent=2))
            else:
                # kv.json did NOT exist originally: remove touched keys
                for key in self.TOUCHED_KEYS:
                    current_data.pop(key, None)
                if current_data:
                    self.kv_path.write_text(json.dumps(current_data, indent=2))
                elif self.kv_path.exists():
                    self.kv_path.unlink(missing_ok=True)
        except Exception as exc:
            print(f"Warning: Failed to restore kv settings: {exc}")

    def ctl(self, *words: str) -> Dict[str, Any]:
        """Execute a control command via native tern ctl directly to the running window."""
        command = " ".join(words) if words[0] in ("dump", "tree") else " ".join(
            word if re.fullmatch(r"[A-Za-z0-9_.:/-]+", word) else json.dumps(word) for word in words
        )
        output = subprocess.run(
            [str(self.tern_bin), "ctl", command],
            capture_output=True,
            text=True,
            timeout=30,
        )
        if output.returncode != 0:
            raise RuntimeError(f"ctl command failed ({command}): {output.stderr or output.stdout}")
        value = json.loads(output.stdout)
        if not value.get("ok"):
            raise RuntimeError(f"ctl command returned non-ok ({command}): {value}")
        return value
    def create_session(self, name: str) -> int:
        """Create and switch to an isolated fixture session using the window SDK cx.sessions:create."""
        self.target_file.write_text(name)
        self.ctl("plugins", "run", "plugin.agent-nav-smoke-fixture.create_fixture_session")
        self.fixture_sessions.add(name)

        def session_ready():
            state = self.inspect_sdk_state()
            sessions = state.get("sessions", [])
            cur_s = next((s for s in sessions if s.get("id") == state.get("current_session")), None)
            if not cur_s or cur_s.get("name") != name:
                return False
            focused = state.get("focused")
            return focused is not None and state.get("current_tab") is not None

        self.wait_until(session_ready, f"Session {name} did not become current in the window SDK", timeout=10.0)
        state = self.inspect_sdk_state()
        self.focus_pane(state["focused"])
        state = self.inspect_sdk_state()
        return state.get("current_session")

    def switch_session(self, target: Union[int, str]):
        """Switch to a session using the window SDK cx.sessions:switch."""
        self.target_file.write_text(str(target))
        self.ctl("plugins", "run", "plugin.agent-nav-smoke-fixture.switch_fixture_session")

        def session_switched():
            state = self.inspect_sdk_state()
            sessions = state.get("sessions", [])
            cur_s = next((s for s in sessions if s.get("id") == state.get("current_session")), None)
            matches_name = cur_s and cur_s.get("name") == str(target)
            matches_id = cur_s and str(cur_s.get("id")) == str(target)
            return (matches_name or matches_id) and state.get("current_tab") is not None

        self.wait_until(session_switched, f"Failed to switch to session {target} via window SDK", timeout=10.0)

    def close_session(self, target: Optional[Union[int, str]] = None):
        """Close a session using the window SDK cx.sessions:close."""
        val = str(target) if target is not None else ""
        self.target_file.write_text(val)
        self.ctl("plugins", "run", "plugin.agent-nav-smoke-fixture.close_fixture_session")
        self.ctl("wait", "200")

    def create_tab(self) -> int:
        """Create a new tab using window SDK cx.layout:new_tab."""
        self.ctl("plugins", "run", "plugin.agent-nav-smoke-fixture.create_fixture_tab")
        self.ctl("wait", "200")
        state = self.inspect_sdk_state()
        return state.get("current_tab")


    def wait_until(self, fn: Callable[[], Any], message: str, timeout: float = 20.0, interval: float = 0.05) -> Any:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            res = fn()
            if res:
                return res
            time.sleep(interval)
        raise AssertionError(f"Timeout ({timeout}s): {message}")

    def visible(self, selector: str) -> List[Dict[str, Any]]:
        return self.ctl("tree", selector).get("nodes", [])

    def dump(self, selector: str) -> List[Dict[str, Any]]:
        return self.ctl("dump", selector).get("elements", [])

    def inspect_sdk_state(self) -> Dict[str, Any]:
        self.inspect_path.unlink(missing_ok=True)
        self.ctl("plugins", "run", "plugin.agent-nav-smoke-fixture.inspect_state")
        self.wait_until(lambda: self.inspect_path.exists(), "inspect_state did not write result", timeout=5)
        return json.loads(self.inspect_path.read_text())

    def nav_panel(self) -> Dict[str, Any]:
        roots = self.visible(".agent-nav-root")
        assert len(roots) == 1, f"Expected exactly 1 visible navigator, found {len(roots)}: {roots}"
        return roots[0]

    def nav_rows(self) -> List[Dict[str, Any]]:
        return self.visible(".agent-nav-agent")

    def nav_bounds(self) -> Tuple[float, float, float, float]:
        rx, ry, rw, _ = self.nav_panel()["rect"]
        panes = []
        for pane in self.visible(".tn-pane"):
            px, py, pw, ph = pane["rect"]
            if pw > 0 and ph > 0 and px <= rx + rw / 2 <= px + pw and py <= ry + 1 <= py + ph:
                panes.append(tuple(float(value) for value in pane["rect"]))
        assert panes, "Navigator has no enclosing visible native pane"
        return min(panes, key=lambda rect: rect[2] * rect[3])

    def nav_physical_width(self) -> Optional[float]:
        """Measure the native pane bounded by the divider, including Canvas insets."""
        if len(self.visible(".agent-nav-root")) != 1:
            return None
        return self.nav_bounds()[2]

    def wait_visible_width(self, target: Union[float, Callable[[float], bool]], message: str, timeout: float = 20.0) -> float:
        def check():
            w = self.nav_physical_width()
            if w is None:
                return None
            if callable(target):
                return w if target(w) else None
            return w if abs(w - target) < 1.0 else None

        return self.wait_until(check, message, timeout=timeout)

    def is_singleton(self, sdk_state: Optional[Dict[str, Any]] = None) -> bool:
        """Enforces true singleton invariant and tab membership."""
        roots = self.visible(".agent-nav-root")
        if len(roots) != 1:
            return False
        state = sdk_state or self.inspect_sdk_state()
        nav_canvases = state.get("nav_canvases", [])
        if len(nav_canvases) != 1:
            return False
        current_tab = state.get("current_tab")
        nav = nav_canvases[0]
        if nav.get("tab") != current_tab:
            return False
        nav_pane = nav.get("pane")
        if nav_pane is None:
            return False
        pane_ids = {p.get("pane") for p in state.get("panes", [])}
        return nav_pane in pane_ids

    def get_nav_pane_id(self) -> int:
        state = self.inspect_sdk_state()
        nav_canvases = state.get("nav_canvases", [])
        assert len(nav_canvases) == 1, f"Expected 1 nav canvas, found: {nav_canvases}"
        return nav_canvases[0]["pane"]

    def focus_pane(self, pane_id: int):
        self.target_file.write_text(str(pane_id))
        self.ctl("plugins", "run", "plugin.agent-nav-smoke-fixture.focus_target_pane")
        self.ctl("wait", "100")

    def click_element(self, node: Dict[str, Any], token: Optional[str] = None) -> Dict[str, Any]:
        x, y, w, h = node["rect"]
        assert w > 0 and h > 0, f"Element rect must be positive: {node}"
        cx, cy = round(x + w / 2), round(y + h / 2)
        hit = self.ctl("pick", str(cx), str(cy))
        if token:
            assert token in hit.get("path", ""), f"Click point ({cx}, {cy}) not on expected element {token}: {hit}"
        self.ctl("click", str(cx), str(cy))
        self.ctl("wait", "150")
        return hit

    def create_agent(self, title: str, how: str = "tab") -> int:
        """Create a fixture agent running /bin/cat (no model invocation) using cx.agents:start."""
        self.target_file.write_text(how)
        self.ctl("plugins", "run", "plugin.agent-nav-smoke-fixture.create_fixture_agent")
        self.ctl("wait", "200")
        state = self.inspect_sdk_state()
        pane = state.get("last_created_pane") or state.get("focused")
        assert pane is not None, "Failed to create fixture agent pane"
        self.fixture_panes.add(pane)

        # Set title via standard OSC 2 sequence directed to the fixture agent pane
        feed_file = self.base / f"title_feed_{pane}.txt"
        feed_file.write_text(f"\x1b]2;{title}\x1b\\")
        self.focus_pane(pane)
        self.ctl("feed", str(feed_file))
        self.ctl("wait", "200")

        state = self.inspect_sdk_state()
        assert any(p["pane"] == pane and p["kind"] == "agent" for p in state["panes"]), f"Pane {pane} not registered as agent"
        self.agent_panes[title] = pane
        return pane

    # =========================================================================
    # Test Cases
    # =========================================================================

    def test_default_startup_and_geometry(self):
        self.wait_until(lambda: len(self.visible(".agent-nav-root")) == 1,
                        "Default navigator did not appear in starting shell tab")
        assert self.is_singleton(), "Must have exactly 1 navigator canvas in active tab"
        state = self.inspect_sdk_state()
        root = (state.get("layout") or {}).get("root")
        assert root and root.get("split") == "right", f"Native split layout unavailable: {state.get('layout')}"
        edge = root.get("2") or root.get("second") or {}
        assert edge.get("pane") == state["nav_canvases"][0]["pane"], f"Navigator absent from native right edge: {root}"
        assert project_content_tree(root, edge["pane"]), "Native split lost the original content panes"
        w = self.wait_visible_width(220.0, "Default navigator did not settle at 220px")
        sx, _, sw, _ = self.visible(".tn-stage")[0]["rect"]
        rx, _, rw, _ = self.nav_bounds()
        assert abs((rx + rw) - (sx + sw)) < 3.0, f"Navigator not pinned to stage right edge: rail={rx, rw}, stage={sx, sw}"

    def test_public_commands_palette_and_chords(self):
        # 1. Keyboard chord: ctrl+alt+n (Toggle off)
        self.ctl("key", "ctrl+alt+n")
        self.wait_until(lambda: len(self.visible(".agent-nav-root")) == 0,
                        "Key chord ctrl+alt+n did not toggle off navigator")

        # 2. Keyboard chord: ctrl+alt+n (Toggle on)
        self.ctl("key", "ctrl+alt+n")
        self.wait_until(lambda: len(self.visible(".agent-nav-root")) == 1,
                        "Key chord ctrl+alt+n did not toggle on navigator")
        self.wait_visible_width(220.0, "Navigator restored via chord did not measure 220px")

        # 3. Native Command Palette: Agent Nav: Toggle left / right
        root_before = self.nav_panel()
        bx, _, _, _ = root_before["rect"]
        self.ctl("palette", "Agent Nav: Toggle left / right")
        self.ctl("wait", "150")
        self.ctl("key", "enter")
        self.ctl("wait", "250")

        root_left = self.nav_panel()
        lx, _, _, _ = root_left["rect"]
        assert lx < bx, f"Command palette toggle_side did not move left: before x={bx}, after x={lx}"
        self.wait_visible_width(220.0, "Navigator altered width when moved to left side")

        # Palette toggle back to right side
        self.ctl("palette", "Agent Nav: Toggle left / right")
        self.ctl("wait", "150")
        self.ctl("key", "enter")
        self.ctl("wait", "250")

        root_right = self.nav_panel()
        rx, _, _, _ = root_right["rect"]
        assert rx > lx, f"Command palette toggle_side did not return right: left x={lx}, right x={rx}"
        self.wait_visible_width(220.0, "Navigator altered width when moved back to right side")

    def test_viewport_resize_stability(self):
        stage = self.ctl("dump", ".tn-stage")["header"]["viewport"]
        orig_w, orig_h = int(stage["width"]), int(stage["height"])

        for target_w in (orig_w + 240, orig_w):
            self.ctl("resize", str(target_w), str(orig_h))
            self.wait_visible_width(220.0, f"Resizing viewport to {target_w}px caused navigator width drift")
            cur_stage_w = int(self.ctl("dump", ".tn-stage")["header"]["viewport"]["width"])
            assert cur_stage_w == target_w, f"Viewport width mismatch: {cur_stage_w} != {target_w}"

    def test_real_divider_drag_and_memory(self):
        rx, ry, _, rh = self.nav_bounds()
        divider_x = round(rx - 1)
        divider_y = round(ry + rh / 2)
        self.ctl("down", str(divider_x), str(divider_y))
        self.ctl("move", str(divider_x - 50), str(divider_y))
        self.ctl("up")

        dragged_width = self.wait_visible_width(
            lambda width: abs(width - 220.0) > 3.0,
            "Real divider drag did not adjust navigator width from 220px",
            timeout=10,
        )

        def remembered_width():
            if self.kv_path and self.kv_path.exists():
                try:
                    data = json.loads(self.kv_path.read_text())
                    width = data.get("agent_nav.width")
                    if isinstance(width, (int, float)) and abs(width - dragged_width) < 1.0:
                        return True
                except Exception:
                    pass
            return False

        self.wait_until(remembered_width, "Dragged width was not saved as the user preference")

        # Viewport resize must remember user's dragged width
        stage = self.ctl("dump", ".tn-stage")["header"]["viewport"]
        orig_w, orig_h = int(stage["width"]), int(stage["height"])
        self.ctl("resize", str(orig_w + 200), str(orig_h))
        self.wait_visible_width(dragged_width, "Manual width not preserved across viewport resize")
        self.ctl("resize", str(orig_w), str(orig_h))
        self.wait_visible_width(dragged_width, "Manual width not preserved after restoring viewport")

        # Palette: Agent Nav: Reset Width restores 220px
        self.ctl("palette", "Agent Nav: Reset Width")
        self.ctl("wait", "150")
        self.ctl("key", "enter")
        self.ctl("wait", "250")
        self.wait_visible_width(220.0, "Reset Width command did not restore 220px")

    def test_tabs_and_sessions_exact_mapping(self):
        # In isolated self.alpha_session_name:
        # Tab 1: add first agent
        agent1 = self.create_agent("Alpha Main", how="tab")

        # Tab 1: split content down with agent
        agent2 = self.create_agent("Alpha Split", how="split")

        # Tab 2: create new tab with agent
        agent3 = self.create_agent("Alpha Tab2", how="tab")

        # Tab 3: create new tab with agent
        agent4 = self.create_agent("Alpha Tab3", how="tab")

        # Session 2: create new isolated session via window SDK
        self.create_session(self.beta_session_name)
        agent5 = self.create_agent("Beta Agent", how="tab")

        # 1. Enforce strict singleton invariant across tabs and sessions
        assert self.is_singleton(), "Must maintain exactly 1 navigator canvas in active tab across tabs and sessions"

        # 2. Exact group and row match for fixture-created sessions
        expected_groups = [
            (self.alpha_session_name, ["Alpha Main", "Alpha Split", "Alpha Tab2", "Alpha Tab3"]),
            (self.beta_session_name, ["Beta Agent"]),
        ]
        expected_flat = [(g, title) for g, titles in expected_groups for title in titles]

        def check_exact_rows():
            rendered_rows = self.nav_rows()
            titles = [text_content(row) for row in rendered_rows]
            if [t for t in titles if any(exp == t for exp in [title for _, title in expected_flat])] != [title for _, title in expected_flat]:
                return False
            sections = self.visible(".agent-nav-group")
            expected_sections = [group + "".join(titles) for group, titles in expected_groups]
            rendered_sections = [text_content(section) for section in sections]
            return all(exp in rendered_sections for exp in expected_sections)

        self.wait_until(check_exact_rows, "Navigator rows did not match expected groups and titles", timeout=10)

        # 3. Focus & Title preservation
        sdk_state = self.inspect_sdk_state()
        cur_focused = sdk_state.get("focused")
        nav_pane = self.get_nav_pane_id()
        assert cur_focused != nav_pane, f"Navigator canvas hijacked focus: {cur_focused}"

        visible_tab_titles = [text_content(n) for n in self.visible(".tt") if text_content(n) and text_content(n) != "+"]
        for t in visible_tab_titles:
            assert "Agent Navigations" not in t, f"Tab title hijacked by navigator: {t}"

        # 4. Active row highlighted
        current_rows = self.visible(".agent-nav-agent.is-current")
        assert len(current_rows) == 1, f"Expected 1 highlighted row, found {len(current_rows)}"
        assert "Beta Agent" in text_content(current_rows[0]), f"Active row title mismatch: {current_rows[0]}"

    def test_real_pointer_click_jump(self):
        # Currently in Beta session. Locate row for Alpha Main in Alpha session
        rows = self.nav_rows()
        target_row = None
        for row in rows:
            if "Alpha Main" in text_content(row):
                target_row = row
                break
        assert target_row is not None, "Could not find row for 'Alpha Main' in rows"

        nav_pane_before = self.get_nav_pane_id()
        source = self.inspect_sdk_state()
        source_tab = source["current_tab"]
        source_title = next(t["title"] for t in source["tabs"] if t["id"] == source_tab)

        # Perform real pointer click
        self.click_element(target_row, token="agent-nav-agent")
        self.ctl("wait", "300")

        # Verify cross-session jump occurred to Alpha session
        def check_jump():
            state = self.inspect_sdk_state()
            sessions = state.get("sessions", [])
            cur_s = next((s for s in sessions if s.get("id") == state.get("current_session")), None)
            return cur_s and cur_s["name"] == self.alpha_session_name and state["focused"] == self.agent_panes["Alpha Main"]

        self.wait_until(check_jump, f"Pointer click did not jump across sessions to {self.alpha_session_name}", timeout=10)
        assert self.is_singleton(), "Singleton navigator preserved after cross-session jump"
        assert self.get_nav_pane_id() == nav_pane_before, "Navigator pane ID mutated during jump"
        after = self.inspect_sdk_state()
        assert after["layouts"][str(source_tab)]["focus"] == self.agent_panes["Beta Agent"]
        assert next(t["title"] for t in after["tabs"] if t["id"] == source_tab) == source_title

        # Verify highlighted row updated to Alpha Main
        current_rows = self.visible(".agent-nav-agent.is-current")
        assert len(current_rows) == 1
        assert "Alpha Main" in text_content(current_rows[0]), f"Active row title mismatch: {current_rows[0]}"

    def test_split_content_preservation(self):
        nav = self.get_nav_pane_id()
        initial = self.inspect_sdk_state()
        origin_tab = initial["current_tab"]
        origin_session = initial["current_session"]

        def content(state):
            return project_content_tree(state["layout"]["root"], nav)

        def leaves(tree):
            return {tree["pane"]} if "pane" in tree else leaves(tree["first"]) | leaves(tree["second"])

        def focus(pane):
            self.focus_pane(pane)

        def split(target, direction, navigation_focused=False):
            focus(target)
            before = {p["pane"] for p in self.inspect_sdk_state()["panes"]}
            if navigation_focused:
                focus(nav)
                assert self.inspect_sdk_state()["focused"] == nav
            command = f"split_{direction}" if navigation_focused else f"plugin.agent-nav-smoke-fixture.split_content_{direction}"
            self.ctl("plugins", "run", command)

            def created():
                state = self.inspect_sdk_state()
                added = {p["pane"] for p in state["panes"]} - before
                if len(added) != 1 or not self.is_singleton(state):
                    return False
                pane = next(iter(added))
                return pane if pane in leaves(content(state)) and state["focused"] == pane else False

            p = self.wait_until(created, f"Native {direction} split did not target content")
            self.fixture_panes.add(p)
            return p

        baseline = content(initial)
        first = min(leaves(baseline))
        created = []
        lower = split(first, "down")
        created.append(lower)
        right = split(first, "right")
        created.append(right)
        created.append(split(lower, "right"))
        created.append(split(right, "down"))
        for direction in ("right", "down"):
            created.append(split(first, direction, navigation_focused=True))

        # Adjust multiple internal dividers so at least 3 internal nodes have distinct ratios
        self.target_file.write_text(f"{first} right 3")
        self.ctl("plugins", "run", "plugin.agent-nav-smoke-fixture.resize_content")
        self.target_file.write_text(f"{lower} down -2")
        self.ctl("plugins", "run", "plugin.agent-nav-smoke-fixture.resize_content")
        self.target_file.write_text(f"{right} down 2")
        self.ctl("plugins", "run", "plugin.agent-nav-smoke-fixture.resize_content")

        focus(first)
        settled = self.inspect_sdk_state()
        golden = content(settled)
        assert len(leaves(golden)) >= 6 and leaves(baseline) <= leaves(golden)

        def splits(tree):
            if "pane" in tree:
                return []
            return [(tree["split"], tree["ratio"])] + splits(tree["first"]) + splits(tree["second"])

        assert {direction for direction, _ in splits(golden)} == {"right", "down"}
        assert any(abs(ratio - 0.5) > 1e-3 for _, ratio in splits(golden))
        titles = {p["pane"]: p["title"] for p in settled["panes"] if p["pane"] in leaves(golden)}
        tab_title = next(t["title"] for t in settled["tabs"] if t["id"] == origin_tab)

        def preserved():
            state = self.inspect_sdk_state()
            if state["current_tab"] != origin_tab or not self.is_singleton(state):
                return False
            root = state["layout"]["root"]
            children = [root.get("1", {}), root.get("2", {})]
            if root.get("split") != "right" or not any(child.get("pane") == nav for child in children):
                return False
            if not same_content_tree(golden, content(state)) or state["focused"] != first:
                return False
            assert {p["pane"]: p["title"] for p in state["panes"] if p["pane"] in titles} == titles
            assert next(t["title"] for t in state["tabs"] if t["id"] == origin_tab) == tab_title
            return True

        for _ in range(2):
            self.ctl("palette", "Agent Nav: Toggle left / right")
            self.ctl("key", "enter")
            self.wait_visible_width(220.0, "Mixed content attachment changed navigator width")

        # Edit internal divider after settled then side-toggle: verify latest tree preserved
        self.target_file.write_text(f"{first} right -2")
        self.ctl("plugins", "run", "plugin.agent-nav-smoke-fixture.resize_content")
        focus(first)
        settled_updated = self.inspect_sdk_state()
        golden = content(settled_updated)
        self.ctl("palette", "Agent Nav: Toggle left / right")
        self.ctl("key", "enter")
        self.wait_until(preserved, "Side toggle after internal divider edit did not preserve latest tree")
        self.ctl("palette", "Agent Nav: Toggle left / right")
        self.ctl("key", "enter")
        self.wait_until(preserved, "Side toggle restore did not preserve latest tree")

        # Focus non-first content leaf: verify start/reload/toggle preserves non-first focus and titles
        non_first = right
        focus(non_first)
        assert self.inspect_sdk_state()["focused"] == non_first, f"Failed to focus non-first leaf {non_first}"
        subprocess.run([str(self.tern_bin), "plugin", "reload"], check=True, capture_output=True)
        self.ctl("wait", "300")
        self.wait_until(lambda: self.inspect_sdk_state()["focused"] == non_first,
                        "Reload when non-first content leaf focused stole focus")
        state_after_reload = self.inspect_sdk_state()
        assert {p["pane"]: p["title"] for p in state_after_reload["panes"] if p["pane"] in titles} == titles
        focus(first)

        # Tab round trip
        origin = next(t for t in settled["tabs"] if t["id"] == origin_tab)
        other_tab = next(t for t in settled["tabs"] if t["session"] == origin_session and t["id"] != origin_tab)
        self.ctl("tab", str(other_tab["position"]))
        self.wait_until(self.is_singleton, "Navigator did not follow another tab")
        self.ctl("tab", str(origin["position"]))
        self.wait_until(preserved, "Tab round trip changed mixed content")

        # Session round trip
        other_session = next(s for s in settled["sessions"] if s["id"] != origin_session and s["name"] in self.fixture_sessions)
        origin_name = next(s["name"] for s in settled["sessions"] if s["id"] == origin_session)
        self.switch_session(other_session["name"])
        self.wait_until(self.is_singleton, "Navigator did not follow another session")
        self.switch_session(origin_name)
        self.wait_until(preserved, "Session round trip changed mixed content")

        # Close fixture-created splits and verify original content restored
        for pane in reversed(created):
            self.target_file.write_text(str(pane))
            self.ctl("plugins", "run", "plugin.agent-nav-smoke-fixture.close_target_pane")
            self.fixture_panes.discard(pane)

        self.wait_until(lambda: same_content_tree(baseline, content(self.inspect_sdk_state())),
                        "Closing fixture-created splits did not restore original content")
        self.wait_until(self.is_singleton, "Fixture cleanup lost navigator")

    def test_manual_close_disables(self):
        nav_pane = self.get_nav_pane_id()

        # 1. Focus navigator pane and trigger native close
        self.focus_pane(nav_pane)
        assert self.inspect_sdk_state().get("focused") == nav_pane, "Could not focus navigator pane"

        self.ctl("close")
        self.wait_until(lambda: len(self.visible(".agent-nav-root")) == 0, "Native close did not close navigator")

        # Wallclock wait: ensure stays closed across ticks
        time.sleep(1.2)
        self.ctl("wait", "100")
        assert len(self.visible(".agent-nav-root")) == 0, "Closed navigator resurrected automatically"

        # New tab stays closed
        self.create_tab()
        self.ctl("wait", "250")
        assert len(self.visible(".agent-nav-root")) == 0, "New tab opened navigator while disabled"

        # Re-enable via chord
        self.ctl("key", "ctrl+alt+n")
        self.wait_until(lambda: len(self.visible(".agent-nav-root")) == 1, "Chord did not re-enable navigator")
        self.wait_visible_width(220.0, "Re-enabled navigator did not adopt 220px")

    def test_parent_tab_close_recreates(self):
        tabs_before = len(self.inspect_sdk_state().get("tabs", []))
        self.ctl("tab", "close")
        self.ctl("wait", "300")
        tabs_after = len(self.inspect_sdk_state().get("tabs", []))
        assert tabs_after == tabs_before - 1, f"tab close failed: {tabs_before} -> {tabs_after}"

        # Navigator must be adopted/recreated on surviving tab
        assert self.is_singleton(), "Navigator was not recreated/adopted on surviving tab after tab close"
        self.wait_visible_width(220.0, "Navigator on surviving tab did not maintain 220px")

    def test_parent_session_close_recreates(self):
        before = self.inspect_sdk_state()
        surviving_ids = {pane["pane"] for pane in before["panes"] if pane["pane"] != before["nav_canvases"][0]["pane"]}
        self.create_session(self.gamma_session_name)
        self.create_agent("Gamma Agent", how="tab")
        self.wait_until(self.is_singleton, "Navigator did not follow disposable session")
        gamma_id = self.inspect_sdk_state()["current_session"]
        self.wait_visible_width(220.0, "Navigator in disposable session did not settle at 220px")

        # Close session
        self.close_session(self.gamma_session_name)
        self.fixture_sessions.discard(self.gamma_session_name)

        def survivor():
            state = self.inspect_sdk_state()
            if state["current_session"] == gamma_id or any(s["id"] == gamma_id for s in state["sessions"]):
                return False
            if not self.is_singleton(state):
                return False
            return state

        after = self.wait_until(survivor, "Closing parent session did not restore navigator on survivor")
        assert surviving_ids <= {pane["pane"] for pane in after["panes"]}, "Session close removed surviving content"
        assert after["focused"] != self.get_nav_pane_id(), "Navigator took survivor content focus"
        self.wait_visible_width(220.0, "Survivor navigator did not maintain 220px")

    def test_plugin_reload_adoption(self):
        nav_pane_before = self.get_nav_pane_id()
        subprocess.run([str(self.tern_bin), "plugin", "reload"], check=True, capture_output=True)
        self.ctl("wait", "300")
        assert self.is_singleton(), "Singleton violated after plugin reload"
        assert self.get_nav_pane_id() == nav_pane_before, "Reload failed to adopt existing canvas pane ID"

    def test_event_storms_reconciliation(self):
        for _ in range(3):
            self.ctl("tab", "next")
            self.ctl("palette", "Agent Nav: Toggle left / right")
            self.ctl("key", "enter")
            self.ctl("focus", "next")

        time.sleep(0.3)
        self.ctl("wait", "200")
        assert self.is_singleton(), "Event storm left invalid canvas state"
        self.wait_visible_width(220.0, "Event storm corrupted navigator width")

    def test_native_tsp_five_state_fixture(self):
        wire_path = self.base / "status-wire.bin"
        title = "Native State Fixture"
        pane = self.create_agent(title, how="tab")
        native = self.inspect_sdk_state()
        other = next(p["pane"] for p in native["panes"] if p["tab"] == native["current_tab"] and p["pane"] not in (pane, native["nav_canvases"][0]["pane"]))
        sequence = 0

        def focus(target):
            self.focus_pane(target)

        def emit(payload):
            focus(pane)
            wire_path.write_bytes(payload)
            self.ctl("feed", str(wire_path))
            focus(other)

        def apc(verb, payload):
            return b"\x1b_tsp;" + verb.encode() + b";" + json.dumps(payload).encode() + b"\x1b\\"

        def frame(ops):
            nonlocal sequence
            sequence += 1
            return apc("f", {"sf": "state-fixture", "s": sequence, "ops": ops})

        def osc(state):
            return f"\x1b]7501;state={state}:app=omp\x1b\\".encode()

        def expect(status):
            def matched():
                rows = [row for row in self.visible(f".agent-nav-agent.status-{status}") if title in text_content(row)]
                return rows[0] if len(rows) == 1 else False
            self.wait_until(matched, f"Fixture pane {pane} did not render status-{status}")

        nodes = [
            ("main", "state-fixture", {}), ("dock", "state-fixture", {}),
            ("layer", "state-fixture", {}),
            ("composer", "dock", {"role": "omp.editor", "state": "working"}),
            ("hidden_wrap", "layer", {"hidden": True}),
            ("hidden_question", "hidden_wrap", {"role": "omp.editor", "state": "waiting"}),
        ]
        ops = [["add", key, parent, None, {"id": key, "k": "col", "p": props}] for key, parent, props in nodes]
        emit(apc("o", {"id": "state-fixture", "mode": "inline", "title": title}) + frame(ops) + osc("working"))
        expect("running")

        self.target_file.write_text(str(pane))
        self.surface_path.unlink(missing_ok=True)
        self.ctl("plugins", "run", "plugin.agent-nav-smoke-fixture.surface_probe")
        self.wait_until(self.surface_path.exists, "Populated surface inspection did not complete")
        sample = json.loads(self.surface_path.read_text())
        roots = sample.get("roots")
        assert sample["pane"] == pane and isinstance(roots, dict), "Fixture must expose a real TSP surface"
        for region in ("dock", "layer"):
            assert roots[region]["more"] > 0 and "c" not in roots[region], "Root discovery must cap descendants"
            exact = sample[region]["main"]
            assert exact["id"] == roots[region]["id"] and exact.get("c"), "Discovered exact root must resolve"

        emit(frame([["set", "hidden_wrap", {"hidden": False}]]))
        expect("attention")
        emit(frame([["set", "hidden_wrap", {"hidden": True}]]))
        expect("running")
        emit(frame([["set", "composer", {"state": "waiting"}]]))
        emit(osc("blocked:kind=question"))
        expect("attention")
        native = self.inspect_sdk_state()
        assert any(a["pane"] == pane and a["state"] == "waiting_input" for a in native["agents"])

        focus(other)
        emit(frame([["set", "composer", {"state": "idle"}]]))
        emit(osc("done") + b"\x07")
        expect("done-unread")
        focus(pane)
        expect("done-read")
        emit(osc("error"))
        expect("error")
        emit(frame([["set", "composer", {"state": "working"}]]))
        emit(osc("working"))
        expect("running")
        focus(pane)
        self.ctl("alert", "exited", "1")
        focus(other)
        expect("error")

    def test_native_tsp_latency_batch_fixture(self):
        """Bounded-round state-only NativeTSP latency test covering at least 8 known fixture agents.

        Asserts that waiting->working transitions render within a bounded timeout without private calls
        or status-changing SDK events.
        """
        wire_path = self.base / "latency-wire.bin"
        batch_count = 8
        batch_panes: List[int] = []
        batch_titles: List[str] = [f"Latency Agent {i} {self.run_id}" for i in range(batch_count)]

        print(f"\n--- Bounded NativeTSP Latency Test ({batch_count} agents) ---")
        for i in range(batch_count):
            pane = self.create_agent(batch_titles[i], how="tab")
            batch_panes.append(pane)

        def apc(verb, payload):
            return b"\x1b_tsp;" + verb.encode() + b";" + json.dumps(payload).encode() + b"\x1b\\"

        def frame(ops, key):
            return apc("f", {"sf": key, "s": 1, "ops": ops})

        def osc(state):
            return f"\x1b]7501;state={state}:app=omp\x1b\\".encode()

        # 1. Initialize all 8 agents to waiting (attention) via state-only NativeTSP feed
        for i, pane in enumerate(batch_panes):
            sf_key = f"latency-{pane}"
            ops = [
                ["add", "main", sf_key, None, {"id": "main", "k": "col"}],
                ["add", "dock", sf_key, None, {"id": "dock", "k": "col"}],
                ["add", "composer", "dock", None, {"id": "composer", "k": "col", "p": {"role": "omp.editor", "state": "waiting"}}],
            ]
            payload = (
                apc("o", {"id": sf_key, "mode": "inline", "title": batch_titles[i]})
                + frame(ops, sf_key)
                + osc("blocked:kind=question")
            )
            self.focus_pane(pane)
            wire_path.write_bytes(payload)
            self.ctl("feed", str(wire_path))

        def all_attention():
            rows = self.visible(".agent-nav-agent.status-attention")
            rendered = " ".join(text_content(r) for r in rows)
            return all(title in rendered for title in batch_titles)

        # Keep initialization wait long enough for old 1-agent/s branch to settle cleanly
        self.wait_until(all_attention, "Batch agents did not settle into waiting/attention state", timeout=20.0)

        # 2. Transition all 8 agents from waiting to working via non-focused addressed PTY input (tern send)
        # Cat echoes raw PTY input to Native output without focus cycling or triggering focus SDK events
        focused_before = self.inspect_sdk_state()["focused"]

        # Measure elapsed time starting FROM BEFORE batch injection
        t0 = time.monotonic()

        # Concurrently send addressed PTY input to all 8 panes without changing focus
        procs = []
        for pane in batch_panes:
            sf_key = f"latency-{pane}"
            ops = [["set", "composer", {"state": "working"}]]
            payload = (frame(ops, sf_key) + osc("working")).decode("ascii") + "\r"
            p = subprocess.Popen(
                [str(self.tern_bin), "send", str(pane), "text", payload],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            procs.append(p)

        for p in procs:
            p.wait(timeout=1.0)

        def all_running():
            rows = self.visible(".agent-nav-agent.status-running")
            rendered = " ".join(text_content(r) for r in rows)
            return all(title in rendered for title in batch_titles)

        # Total budget for injection + observation strictly capped at 3.0s total
        remaining = max(0.1, 3.0 - (time.monotonic() - t0))
        self.wait_until(
            all_running,
            "Batch waiting->working TSP transitions did not render within 3.0s total timeout",
            timeout=remaining,
        )
        elapsed = time.monotonic() - t0
        print(f"Batch NativeTSP waiting->working rendered for {batch_count} agents in {elapsed:.2f}s (budget <= 3.0s).")

        # Assert focus remained stationary and was not changed or hijacked during addressed injection
        assert self.inspect_sdk_state()["focused"] == focused_before, "Focus changed during addressed PTY injection"

    def test_remote_state_reconnect_defense(self):
        origin = self.inspect_sdk_state()["current_host"]
        origin_canvas = self.get_nav_pane_id()
        origin_panes = {p["pane"] for p in self.inspect_sdk_state()["panes"]}
        origin_content_panes = origin_panes - {origin_canvas}

        remote_host_addr = f"smoke_{self.run_id}@127.0.0.1:22"
        self.ctl("remote", "loopback", remote_host_addr)

        def remote_ready():
            state = self.inspect_sdk_state()
            host = state["current_host"]
            return state if host["kind"] == "remote" and host["state"] == "connected" and self.is_singleton(state) else False

        remote = self.wait_until(remote_ready, "Loopback did not establish an active connected remote host")
        remote_name = remote["current_host"]["name"]
        remote_id = remote["current_host"]["id"]
        self.fixture_hosts.add(remote_name)

        self.wait_visible_width(220.0, "Remote navigator did not settle at 220px")

        # Verify old host canvas was retired on host switch
        cur_canvases = [c["pane"] for c in self.inspect_sdk_state().get("nav_canvases", [])]
        assert origin_canvas not in cur_canvases, "Old host canvas was not retired on host switch"

        for link_state in ("connecting", "reconnecting", "connected"):
            args = ["remote", "state", remote_name, link_state]
            if link_state == "reconnecting":
                args.append("fixture link interrupted")
            self.ctl(*args)
            self.wait_until(lambda: self.inspect_sdk_state()["current_host"]["state"] == link_state,
                            f"Remote host never entered {link_state}")

        self.wait_until(self.is_singleton, "Navigator did not recover after reconnect")
        self.wait_visible_width(220.0, "Reconnect changed navigator width")
        self.ctl("remote", "identity", remote_name, "fixture-peer", "ssh-key", "127.0.0.1", "smoke")
        self.wait_until(self.is_singleton, "Identity replacement left an invalid remote navigator")
        self.ctl("remote", "switch", origin["name"])

        def returned():
            state = self.inspect_sdk_state()
            return state["current_host"]["id"] == origin["id"] and self.is_singleton(state)

        self.wait_until(returned, "Returning to local host lost its navigator")

        # Verify content panes survived and singleton navigator maintained (origin canvas may be newly created)
        after = self.inspect_sdk_state()
        after_panes = {p["pane"] for p in after["panes"]}
        assert origin_content_panes <= after_panes, "Host round trip lost origin content panes"
        assert self.is_singleton(), "Singleton navigator not maintained on returned host"
        self.wait_visible_width(220.0, "Host round trip changed remembered width")

        # Forget the test host using cx.hosts:disconnect
        self.target_file.write_text(str(remote_id))
        self.ctl("plugins", "run", "plugin.agent-nav-smoke-fixture.forget_test_host")
        self.fixture_hosts.discard(remote_name)

    def test_bounded_soak(self):
        if self.soak_seconds <= 0:
            return
        print(f"\n--- Bounded Soak Testing ({self.soak_seconds}s) ---")
        start = time.monotonic()
        cycles = 0
        while time.monotonic() - start < self.soak_seconds:
            self.ctl("tab", "next")
            self.ctl("wait", "50")
            self.ctl("tab", "prev")
            self.ctl("wait", "50")
            self.ctl("key", "ctrl+alt+n")
            self.ctl("wait", "50")
            self.ctl("key", "ctrl+alt+n")
            self.ctl("wait", "50")
            cycles += 1

        self.ctl("wait", "200")
        assert self.is_singleton(), "Navigator lost singleton during soak run"
        self.wait_visible_width(220.0, "Navigator width drifted during soak run")
        print(f"Soak completed: {cycles} cycles with zero state drift.")

    def verify_no_budget_or_handler_failures(self):
        if not self.log_path or not self.log_path.exists():
            return
        try:
            with self.log_path.open("r", errors="replace") as f:
                f.seek(self.log_start_offset)
                new_logs = f.read()
        except Exception:
            return

        failures = []
        for line in new_logs.splitlines():
            for pat in BUDGET_FAILURES:
                if pat in line and ("agent-nav" in line or "fixture" in line):
                    failures.append((pat, line.strip()))

        if failures:
            for pat, line in failures[:20]:
                print(f"  [{pat}]: {line}")
            raise AssertionError(f"Detected {len(failures)} budget/handler violations in logs during smoke run")

    def run(self):
        try:
            self.setup()
            self.test_default_startup_and_geometry()
            self.test_public_commands_palette_and_chords()
            self.test_viewport_resize_stability()
            self.test_real_divider_drag_and_memory()
            self.test_tabs_and_sessions_exact_mapping()

            if self.click_only:
                self.test_real_pointer_click_jump()
                self.verify_no_budget_or_handler_failures()
                return

            self.test_real_pointer_click_jump()
            self.test_split_content_preservation()
            self.test_manual_close_disables()
            self.test_parent_tab_close_recreates()
            self.test_parent_session_close_recreates()
            self.test_plugin_reload_adoption()
            self.test_event_storms_reconciliation()
            self.test_native_tsp_five_state_fixture()
            self.test_native_tsp_latency_batch_fixture()
            self.test_remote_state_reconnect_defense()
            self.test_bounded_soak()

            if self.artifacts_dir:
                try:
                    tree = self.ctl("tree", ".agent-nav-root")
                    (self.artifacts_dir / "tree.json").write_text(json.dumps(tree, indent=2))
                    shot_res = self.ctl("shot", "navigator")
                    candidates = []
                    for key in ("png", "file", "path", "shot"):
                        val = shot_res.get(key)
                        if isinstance(val, str):
                            p = Path(val)
                            candidates.append(p if p.is_absolute() else Path.cwd() / p)
                            candidates.append(Path.home() / p)
                    candidates.append(Path("/Users/arcadia/target/shots/tern/live/navigator.png"))
                    candidates.append(Path.cwd() / "target" / "shots" / "tern" / "live" / "navigator.png")
                    candidates.append(Path.home() / "target" / "shots" / "tern" / "live" / "navigator.png")
                    candidates.extend(self.base.rglob("*.png"))
                    for cand in candidates:
                        if cand.exists():
                            shutil.copy(cand, self.artifacts_dir / cand.name)
                            break
                except Exception:
                    pass

            self.verify_no_budget_or_handler_failures()
            print("\nALL BEHAVIOR-BASED BLACKBOX REGRESSION CHECKS PASSED.")
        except Exception as exc:
            print(f"\nREGRESSION FAILURE: {exc}")
            if self.artifacts_dir and self.base:
                try:
                    state = self.inspect_sdk_state()
                    (self.artifacts_dir / "failure_state.json").write_text(json.dumps(state, indent=2))
                except Exception:
                    pass
            raise
        finally:
            self.teardown()


def main():
    root = Path(__file__).resolve().parents[1]

    parser = argparse.ArgumentParser(
        description="Tern Agent Nav Blackbox Smoke Test (Live GUI Window Mode)",
        epilog=(
            "Actionable Requirement:\n"
            "Tern 0.9.2 headless serve cannot dispatch recurring/delayed plugin timers in quiet time.\n"
            "This smoke regression suite validates real wallclock plugin timers and UI behavior\n"
            "against an existing running Tern GUI window. Use --existing-window to execute."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--existing-window",
        action="store_true",
        help=(
            "Opt in to running against an existing running Tern GUI window. "
            "Required: Tern 0.9.2 headless serve cannot dispatch recurring/delayed "
            "plugin timers in quiet time, so blackbox smoke testing requires a live GUI window."
        ),
    )
    parser.add_argument(
        "--tern",
        default=shutil.which("tern") or "/Applications/Tern.app/Contents/MacOS/tern",
        help="Path to tern executable",
    )
    parser.add_argument(
        "--plugin",
        "--package",
        dest="plugin",
        type=Path,
        default=root,
        help="Path to tern-agent-nav plugin package. If different from currently linked source, links it for testing and restores original source in teardown.",
    )
    parser.add_argument("--artifacts", type=Path, help="Directory to save screenshots, dumps, and logs")
    parser.add_argument(
        "--soak-seconds",
        type=float,
        default=0.0,
        help="Duration in seconds for bounded soak testing (default: 0 = disabled)",
    )
    parser.add_argument(
        "--click-only",
        action="store_true",
        help="Stop after real pointer click jump assertion",
    )

    args = parser.parse_args()

    if not args.existing_window:
        parser.error(
            "Tern 0.9.2 headless serve cannot dispatch recurring/delayed plugin timers in quiet time.\n"
            "Smoke regression must be run against an existing running Tern GUI window with --existing-window."
        )

    try:
        runner = SmokeRunner(args)
    except RuntimeError as error:
        parser.error(str(error))
    runner.run()


if __name__ == "__main__":
    main()
