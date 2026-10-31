"""Native regression for tab-switch width memory (run against an isolated Tern GUI).

python3 tests/width_regression.py --control /tmp/navw.sock \
    --config /tmp/navw/config --daemon /tmp/navw/daemon.sock

The supplied sandbox must already have agent-nav installed. No model is invoked.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import sys
import time
from smoke import require_unlocked_desktop


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--control", required=True)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--daemon", required=True)
    parser.add_argument("--tern", default=shutil.which("tern"))
    args = parser.parse_args()
    require_unlocked_desktop()
    env = dict(os.environ, TERN_CONFIG_DIR=str(args.config.resolve()), TERN_DAEMON_SOCKET=args.daemon)

    def cli(*argv):
        return subprocess.check_output([args.tern, *argv], env=env, text=True, timeout=15)

    def ctl(command):
        result = json.loads(cli("ctl", "--control", args.control, command))
        assert result.get("ok"), result
        return result

    def action(name):
        return ctl("plugins run plugin." + name)

    def snapshot():
        return json.loads(cli("ls", "--json"))

    def leaves(node):
        if "Leaf" in node:
            return [node["Leaf"]]
        split = node["Split"]
        return leaves(split["a"]) + leaves(split["b"])

    def without(node, pane):
        if "Leaf" in node:
            return None if node["Leaf"] == pane else node
        split = node["Split"]
        a, b = without(split["a"], pane), without(split["b"], pane)
        if a is None:
            return b
        if b is None:
            return a
        return {"Split": {"axis": split["axis"], "ratio": split["ratio"], "a": a, "b": b}}

    def cell_span(node, metrics):
        if "Leaf" in node:
            block = metrics[node["Leaf"]]
            return block["cols"], block["rows"]
        split = node["Split"]
        ac, ar = cell_span(split["a"], metrics)
        bc, br = cell_span(split["b"], metrics)
        assert split["axis"] in ("Row", "Column"), split
        return (ac + bc, max(ar, br)) if split["axis"] == "Row" else (max(ac, bc), ar + br)

    def same_tree(a, b, metrics):
        if "Leaf" in a or "Leaf" in b:
            return a == b
        x, y = a["Split"], b["Split"]
        cols, rows = cell_span(a, metrics)
        span = cols if x["axis"] == "Row" else rows
        return (x["axis"] == y["axis"]
                and abs(x["ratio"] - y["ratio"]) * span <= 0.5 + 1e-3
                and same_tree(x["a"], y["a"], metrics)
                and same_tree(x["b"], y["b"], metrics))

    def tab_by_id(tab_id):
        return next(t for s in snapshot()["sessions"] for t in s["tabs"] if t["id"] == tab_id)

    kv_path = args.config / "plugin-data/agent-nav/kv.json"
    original_kv = kv_path.read_bytes() if kv_path.exists() else None
    original_focus = ctl("state")["focused"]["id"]
    fixture = args.config / "plugins/nav-width-regression"
    if fixture.exists():
        raise RuntimeError(f"Fixture already exists: {fixture}")
    created = []
    with tempfile.TemporaryDirectory(prefix="nav-width-") as scratch:
        report = Path(scratch) / "report.json"
        fixture.mkdir(parents=True)
        (fixture / "plugin.toml").write_text(
            'schema = 1\nid = "nav-width-regression"\nname = "Nav Width Regression"\n'
            'version = "0.1.0"\nwindow = "window.luau"\n')
        (fixture / "window.luau").write_text('''local function leaf()
    return {launch = {cwd = "/tmp"}}
end
local saved = {panes = {}}
local function collect(node, out)
    if node.pane then
        table.insert(out, node.pane)
    else
        collect(node[1], out)
        collect(node[2], out)
    end
end
local function remember(cx, name, tab)
    saved[name] = tab
    saved.window_key = cx:window_key()
    collect(cx.session:layout(tab).root, saved.panes)
    if name == "deep" then
        saved.deep_panes = {}
        collect(cx.session:layout(tab).root, saved.deep_panes)
    end
    tern.fs.write(REPORT_PATH, tern.json.encode(saved))
end
tern.command({id = "prepare", title = "Width: prepare", run = function(cx)
    local home, err = cx.layout:tab(leaf(), {focus = false})
    assert(home, err)
    remember(cx, "home", home)
    local target, failure = cx.layout:tab({split = "right", ratio = 0.5,
        [1] = {split = "right", ratio = 0.46, [1] = leaf(), [2] = leaf()},
        [2] = {split = "right", ratio = 0.5, [1] = leaf(), [2] = leaf()},
    }, {focus = false})
    assert(target, failure)
    remember(cx, "target", target)
    local deep, deep_err = cx.layout:tab({split = "right", ratio = 0.5,
        [1] = {split = "right", ratio = 0.7335,
            [1] = {split = "right", ratio = 0.512,
                [1] = {split = "down", ratio = 0.4545,
                    [1] = {split = "right", ratio = 0.5, [1] = leaf(),
                        [2] = {split = "down", ratio = 0.5505, [1] = leaf(), [2] = leaf()}},
                    [2] = {split = "right", ratio = 0.5, [1] = leaf(), [2] = leaf()}},
                [2] = leaf()},
            [2] = leaf()},
        [2] = leaf(),
    }, {focus = false})
    assert(deep, deep_err)
    remember(cx, "deep", deep)
end})
tern.command({id = "resize", title = "Width: resize", run = function(cx)
    for _, c in cx.canvas:list() do
        if c.owner == "agent-nav" and c.title == "Agent Navigations" then
            local tab = cx.session:tab_of(c.pane)
            local root = cx.session:layout(tab).root
            local toward = if root[1].pane == c.pane then "right" else "left"
            assert(cx.layout:resize(c.pane, toward, 8))
            return
        end
    end
    error("Navigator missing during native resize")
end})
tern.command({id = "cleanup", title = "Width: cleanup", run = function(cx)
    cx.layout:focus(ORIGINAL_FOCUS)
    for _, pane in saved.panes do
        if cx.session:pane(pane) then cx.layout:close(pane) end
    end
end})
local pending_focus = nil
tern.command({id = "arm_focus", title = "Width: arm focus", run = function(cx)
    saved.focus_injected = nil
    pending_focus = saved.deep_panes[#saved.deep_panes]
    tern.fs.write(REPORT_PATH, tern.json.encode(saved))
end})
tern.on("focus", function(ev, cx)
    local wanted = pending_focus
    if not wanted or ev.tab ~= saved.deep then return end
    local info = cx.session:pane(wanted)
    if not info or info.parked or info.tab ~= saved.deep then return end
    local parked = 0
    for _, pane in saved.deep_panes do
        local member = cx.session:pane(pane)
        if member and member.parked then parked += 1 end
    end
    if parked > 0 then
        pending_focus = nil
        cx.layout:focus(wanted)
        saved.focus_injected = wanted
        saved.focus_debt = parked
        tern.fs.write(REPORT_PATH, tern.json.encode(saved))
    end
end)
'''.replace("REPORT_PATH", json.dumps(str(report))).replace("ORIGINAL_FOCUS", str(original_focus)))
        try:
            cli("plugin", "reload")
            if json.loads(kv_path.read_text()).get("agent_nav.enabled"):
                action("agent-nav.toggle")
            action("nav-width-regression.prepare")
            ids = json.loads(report.read_text())
            home = tab_by_id(ids["home"])
            targets = {ids[name]: tab_by_id(ids[name]) for name in ("target", "deep")}
            created = leaves(home["splits"]) + [p for tab in targets.values() for p in leaves(tab["splits"])]
            golden = {}
            for tab_id, tab in targets.items():
                cli("focus", str(leaves(tab["splits"])[0]), "--window", ids["window_key"])
                deadline = time.monotonic() + 10
                while True:
                    settled = tab_by_id(tab_id)
                    rendered = {p["id"]: p for p in ctl("state")["panes"]}
                    if all(p in rendered and rendered[p]["cols"] > 0 and rendered[p]["rows"] > 0
                           for p in leaves(settled["splits"])):
                        golden[tab_id] = settled["splits"]
                        break
                    assert time.monotonic() < deadline, ("Native pane metrics did not settle", tab_id)
                    time.sleep(0.1)
            home_pane = leaves(home["splits"])[0]
            action("agent-nav.toggle")

            def memory():
                return json.loads(kv_path.read_text()).get("agent_nav.share")

            def settled_tab(tab_id):
                deadline = time.monotonic() + 30
                stem = "window-" + ids["window_key"].encode().hex()
                while True:
                    checkpoints = []
                    for slot in ("a", "b"):
                        path = args.config / "plugin-data/agent-nav/layout" / f"{stem}.{slot}.json"
                        try:
                            checkpoints.append(json.loads(path.read_text()))
                        except (OSError, ValueError):
                            pass
                    latest = max(checkpoints, key=lambda doc: doc["seq"], default={})
                    tab = tab_by_id(tab_id)
                    navs = [b for b in tab["blocks"] if b["title"] == "Agent Navigations"]
                    expected = set(leaves(golden.get(tab_id, home["splits"])))
                    rendered = {p["id"] for p in ctl("state")["panes"]}
                    if latest.get("done") is True and len(navs) == 1 and expected <= rendered:
                        break
                    assert time.monotonic() < deadline, ("Restore did not complete", latest, tab)
                    time.sleep(0.1)
                return tab

            def check(pane, tab_id, want, stored):
                cli("focus", str(pane), "--window", ids["window_key"])
                tab = settled_tab(tab_id)
                navs = [b for b in tab["blocks"] if b["title"] == "Agent Navigations"]
                assert len(navs) == 1, tab
                nav = navs[0]["id"]
                root = tab["splits"]["Split"]
                assert root["axis"] == "Row"
                if root["a"] == {"Leaf": nav}:
                    share = root["ratio"]
                else:
                    assert root["b"] == {"Leaf": nav}, root
                    share = 1 - root["ratio"]
                assert abs(share - want) < 0.01, ("rail width", share, want)
                assert memory() == stored, ("share polluted by placement", memory(), stored)
                assert ctl("state")["focused"]["id"] == pane, "Restoration replaced the latest focused pane"
                if tab_id in golden:
                    metrics = {p["id"]: p for p in ctl("state")["panes"]}
                    actual = without(tab["splits"], nav)
                    assert same_tree(actual, golden[tab_id], metrics), (
                        "Content layout changed by more than half a native cell",
                        {"tab": tab_id, "actual": actual, "expected": golden[tab_id], "metrics": metrics},
                    )
                return share

            cli("focus", str(home_pane), "--window", ids["window_key"])
            time.sleep(1)
            action("agent-nav.reset_width")
            settled_tab(ids["home"])
            action("nav-width-regression.arm_focus")
            cli("focus", str(ids["deep_panes"][0]), "--window", ids["window_key"])
            settled_tab(ids["deep"])
            focus_proof = json.loads(report.read_text())
            wanted_focus = ids["deep_panes"][-1]
            assert focus_proof.get("focus_debt", 0) > 0 and focus_proof.get("focus_injected") == wanted_focus, focus_proof
            assert ctl("state")["focused"]["id"] == wanted_focus, "A later same-tab focus was parked and replaced"
            print("PASS focus: later same-tab selection survives an active restore")
            cli("focus", str(home_pane), "--window", ids["window_key"])
            settled_tab(ids["home"])
            for side in ("left", "right"):
                current_side = json.loads(kv_path.read_text()).get("agent_nav.side", "right")
                if current_side != side:
                    action("agent-nav.toggle_side")
                action("agent-nav.reset_width")
                for _ in range(2):
                    for tab_id in targets:
                        check(leaves(golden[tab_id])[0], tab_id, 0.2, None)
                        check(home_pane, ids["home"], 0.2, None)
                action("nav-width-regression.resize")
                deadline = time.monotonic() + 10
                while True:
                    # A fixed sleep can end before the window processes the divider update.
                    ctl("state")
                    remembered = memory()
                    if remembered is not None and abs(remembered - 0.2) > 0.01:
                        break
                    assert time.monotonic() < deadline, ("Manual divider adjustment was not persisted", remembered)
                    time.sleep(0.1)
                for tab_id in targets:
                    check(leaves(golden[tab_id])[0], tab_id, remembered, remembered)
                check(home_pane, ids["home"], remembered, remembered)
                print(f"PASS {side}: 4/8-block round trips within half a native cell, unchanged default memory, manual resize {remembered:.3f}")
        finally:
            primary_failure = sys.exc_info()[0] is not None
            cleanup_errors = []
            try:
                action("nav-width-regression.cleanup")
            except Exception as exc:
                cleanup_errors.append(f"owned panes: {exc}")
            try:
                shutil.rmtree(fixture)
            except Exception as exc:
                cleanup_errors.append(f"fixture: {exc}")
            try:
                if original_kv is None:
                    kv_path.unlink(missing_ok=True)
                else:
                    kv_path.write_bytes(original_kv)
            except Exception as exc:
                cleanup_errors.append(f"preferences: {exc}")
            try:
                cli("plugin", "reload")
            except Exception as exc:
                cleanup_errors.append(f"reload: {exc}")
            if cleanup_errors:
                message = "; ".join(cleanup_errors)
                if not primary_failure:
                    raise RuntimeError(message)
                print(f"Cleanup errors after primary failure: {message}", file=sys.stderr)


if __name__ == "__main__":
    main()
