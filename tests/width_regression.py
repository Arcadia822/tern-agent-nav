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
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--control", required=True)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--daemon", required=True)
    parser.add_argument("--tern", default=shutil.which("tern"))
    args = parser.parse_args()
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

    def same_tree(a, b):
        if "Leaf" in a or "Leaf" in b:
            return a == b
        x, y = a["Split"], b["Split"]
        return (x["axis"] == y["axis"] and abs(x["ratio"] - y["ratio"]) < 0.02
                and same_tree(x["a"], y["a"]) and same_tree(x["b"], y["b"]))

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
    return {launch = {cwd = "/tmp", command = "/bin/cat"}}
end
tern.command({id = "prepare", title = "Width: prepare", run = function(cx)
    local home, err = cx.layout:tab(leaf(), {focus = false})
    assert(home, err)
    local target, failure = cx.layout:tab({split = "right", ratio = 0.5,
        [1] = {split = "right", ratio = 0.46, [1] = leaf(), [2] = leaf()},
        [2] = {split = "right", ratio = 0.5, [1] = leaf(), [2] = leaf()},
    }, {focus = false})
    assert(target, failure)
    tern.fs.write(REPORT_PATH, tern.json.encode({home = home, target = target}))
end})
tern.command({id = "resize", title = "Width: resize", run = function(cx)
    for _, c in cx.canvas:list() do
        if c.owner == "agent-nav" and c.title == "Agent Navigations" then
            local tab = cx.session:tab_of(c.pane)
            local root = cx.session:layout(tab).root
            local toward = if root[1].pane == c.pane then "right" else "left"
            assert(cx.layout:resize(c.pane, toward, 8))
        end
    end
end})
'''.replace("REPORT_PATH", json.dumps(str(report))))
        try:
            cli("plugin", "reload")
            if not json.loads(kv_path.read_text()).get("agent_nav.enabled"):
                action("agent-nav.toggle")
            action("nav-width-regression.prepare")
            ids = json.loads(report.read_text())
            home, target = tab_by_id(ids["home"]), tab_by_id(ids["target"])
            created = leaves(home["splits"]) + leaves(target["splits"])
            golden = target["splits"]
            home_pane, target_pane = leaves(home["splits"])[0], leaves(golden)[0]

            def memory():
                return json.loads(kv_path.read_text()).get("agent_nav.share")

            def check(pane, tab_id, want, stored):
                cli("focus", str(pane))
                # More than two restore ticks: a transiently correct first frame
                # must not hide a later noteDrag write of the rebuild's 50% share.
                time.sleep(2.5)
                tab = tab_by_id(tab_id)
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
                if tab_id == ids["target"]:
                    assert same_tree(without(tab["splits"], nav), golden), "Content layout changed"
                return share

            cli("focus", str(home_pane))
            time.sleep(1)
            for side in ("left", "right"):
                current_side = json.loads(kv_path.read_text()).get("agent_nav.side", "right")
                if current_side != side:
                    action("agent-nav.toggle_side")
                action("agent-nav.reset_width")
                for _ in range(2):
                    check(target_pane, ids["target"], 0.2, None)
                    check(home_pane, ids["home"], 0.2, None)
                action("nav-width-regression.resize")
                time.sleep(2)
                remembered = memory()
                assert remembered is not None and abs(remembered - 0.2) > 0.01, remembered
                check(target_pane, ids["target"], remembered, remembered)
                check(home_pane, ids["home"], remembered, remembered)
                print(f"PASS {side}: 4-block round trips, unchanged default memory, manual resize {remembered:.3f}")
        finally:
            cli("focus", str(original_focus))
            for pane in created:
                cli("close", str(pane))
            shutil.rmtree(fixture)
            if original_kv is None:
                kv_path.unlink(missing_ok=True)
            else:
                kv_path.write_bytes(original_kv)
            cli("plugin", "reload")


if __name__ == "__main__":
    main()
