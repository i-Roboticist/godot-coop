"""Two real Godot editors (headless) collaborate on the demo project; both report PASS/FAIL.

    python tests/editor/run_editor_tests.py [--windowed] [--suite edge]

The default suite walks through every feature; "edge" covers the tricky cases (reopening,
saving mid-edit, Godot's own undo, new files, conflicting scene edits...).
"""
import json
import shutil
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import harness  # noqa: E402

HERE = Path(__file__).parent


def prepare(project: Path) -> None:
    tests = project / "coop_tests"
    tests.mkdir(exist_ok=True)
    for f in ["test_base.gd", "host_test.gd", "client_test.gd", "host_edge.gd", "client_edge.gd"]:
        shutil.copy(HERE / f, tests / f)
    (project / ".coopignore").write_text("coop_tests/\n", encoding="utf-8")


def main() -> int:
    windowed = "--windowed" in sys.argv
    suite = sys.argv[sys.argv.index("--suite") + 1] if "--suite" in sys.argv else "main"
    scripts = {"main": ("host_test", "client_test"), "edge": ("host_edge", "client_edge")}[suite]
    root = Path(tempfile.gettempdir()) / ("godot_coop_editor_test" if suite == "main" else "godot_coop_editor_test_" + suite)
    if root.exists():
        shutil.rmtree(root, ignore_errors=True)
    shared = root / "shared"
    shared.mkdir(parents=True)
    host = harness.make_project(root / "host")
    client = harness.make_project(root / "client")
    for p in (host, client):
        prepare(p)
    # The joiner has a stale local edit and an extra file: the initial sync must sort that out.
    (client / "player.gd").write_text("extends CharacterBody2D\n# LOCAL EDIT\n", encoding="utf-8")
    print("importing projects…")
    harness.import_project(host)
    harness.import_project(client)
    harness.write_launch(host, {"mode": "host", "profile": {"name": "Hana", "color": "ff6b6b", "uuid": "hana"},
                                "settings": {"use_upnp": False, "port": 47830 if suite == "main" else 47832, "auto_accept_all": True, "include_loopback": True, "relay_host": ""}})
    (client / ".coop").mkdir(exist_ok=True)
    (client / ".coop" / "prefs.json").write_text(json.dumps({"relay_host": ""}), encoding="utf-8")
    import os
    os.environ["GODOT_COOP_DATA_DIR"] = str(root / "data_client")
    env_c = {"GODOT_COOP_TEST": "res://coop_tests/%s.gd" % scripts[1], "GODOT_COOP_SHARED": str(shared),
             "GODOT_COOP_DATA_DIR": str(root / "data_client")}
    env_h = {"GODOT_COOP_TEST": "res://coop_tests/%s.gd" % scripts[0], "GODOT_COOP_SHARED": str(shared),
             "GODOT_COOP_DATA_DIR": str(root / "data_host")}
    for d in ("data_client", "data_host"):
        (root / d).mkdir(exist_ok=True)
    (root / "data_client" / "profile.json").write_text(json.dumps({"name": "Cole", "color": "4dabf7", "uuid": "cole", "email": "cole@example.com"}))
    (root / "data_host" / "profile.json").write_text(json.dumps({"name": "Hana", "color": "ff6b6b", "uuid": "hana", "email": "hana@example.com"}))
    print("launching editors…")
    ph = harness.launch_editor(host, env_h, headless=not windowed, log=root / "host.log")
    time.sleep(2)
    pc = harness.launch_editor(client, env_c, headless=not windowed, log=root / "client.log")
    deadline = time.time() + 420
    while time.time() < deadline and (ph.poll() is None or pc.poll() is None):
        time.sleep(1)
    for p in (ph, pc):
        if p.poll() is None:
            p.kill()
    failures = 0
    for who in ("host", "client"):
        rf = shared / f"{who}_results.json"
        if not rf.exists():
            print(f"{who}: NO RESULTS (see {root / (who + '.log')})")
            failures += 1
            continue
        data = json.loads(rf.read_text(encoding="utf-8"))
        for name, ok in data["results"].items():
            print(f"  {who:6} {'PASS' if ok else 'FAIL'}  {name}")
            if not ok:
                failures += 1
    print(f"\neditor tests ({suite}): {failures} failure(s). Logs: {root}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
