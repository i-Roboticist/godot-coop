"""End-to-end test of the real user flow, with real (windowed) editors and screenshots.

The companion app hosts the demo project (installs the plugin and launches Godot), a second app
instance joins from the invite (downloads the project, installs the plugin, launches a second
Godot), and both editors run scripted actions and save screenshots.

    python tests/editor/run_visual_test.py
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import harness  # noqa: E402

HERE = Path(__file__).parent
APP = harness.REPO / "app"


def main() -> int:
    root = Path(tempfile.gettempdir()) / "godot_coop_visual_test"
    if root.exists():
        shutil.rmtree(root, ignore_errors=True)
    shared = root / "shared"
    shared.mkdir(parents=True)
    host = root / "MyGame"
    shutil.copytree(harness.DEMO, host)
    tests = host / "coop_tests"
    tests.mkdir()
    for f in ["test_base.gd", "visual_host.gd", "visual_client.gd"]:
        shutil.copy(HERE / f, tests / f)
    dest = root / "Joined"
    for d in ("data_host", "data_client"):
        (root / d).mkdir()
    (root / "data_host" / "profile.json").write_text(json.dumps({"name": "Hana", "color": "ff6b6b", "uuid": "hana", "email": "hana@example.com"}))
    (root / "data_client" / "profile.json").write_text(json.dumps({"name": "Cole", "color": "4dabf7", "uuid": "cole", "email": "cole@example.com"}))
    for d in ("data_host", "data_client"):
        (root / d / "settings.json").write_text(json.dumps({"use_upnp": False, "relay_host": "", "include_loopback": True, "port": 47850 if d == "data_host" else 47851}))

    base_env = dict(os.environ)
    env_h = dict(base_env, GODOT_COOP_DATA_DIR=str(root / "data_host"), GODOT_COOP_SHARED=str(shared),
                 GODOT_COOP_TEST="res://coop_tests/visual_host.gd")
    env_c = dict(base_env, GODOT_COOP_DATA_DIR=str(root / "data_client"), GODOT_COOP_SHARED=str(shared),
                 GODOT_COOP_TEST="res://coop_tests/visual_client.gd")
    godot = str(harness.GODOT).replace("_console.exe", ".exe")
    env_h["GODOT_COOP_EDITOR_ARGS"] = "--log-file|" + str(root / "editor_host.log")
    env_c["GODOT_COOP_EDITOR_ARGS"] = "--log-file|" + str(root / "editor_client.log")
    # Test the built app if asked (APP_EXE=dist/GodotCoop/GodotCoop.exe), else run it from source.
    app_cmd = [os.environ["APP_EXE"], "--headless"] if os.environ.get("APP_EXE") else [godot, "--headless", "--path", str(APP)]
    print("app:", " ".join(app_cmd[:1]))
    print("app: hosting", host)
    subprocess.run(app_cmd + ["--", "--auto-host", str(host), "--quit-when-done"],
                   env=env_h, timeout=120, stdout=open(root / "app_host.log", "w"), stderr=subprocess.STDOUT)
    if not harness.wait_for_file(shared / "invite.txt", 240):
        print("host editor never produced an invite (see editor window / logs)")
        return 1
    invite = (shared / "invite.txt").read_text().strip()
    print("app: joining with", invite[:24] + "…")
    subprocess.run(app_cmd + ["--", invite, "--auto-join", "--dest", str(dest), "--quit-when-done"],
                   env=env_c, timeout=300, stdout=open(root / "app_join.log", "w"), stderr=subprocess.STDOUT)
    ok = harness.wait_for_file(shared / "host_done", 600) and harness.wait_for_file(shared / "client_done", 120)
    failures = 0
    for who in ("host", "client"):
        rf = shared / f"{who}_results.json"
        if not rf.exists():
            print(f"{who}: no results")
            failures += 1
            continue
        for name, passed in json.loads(rf.read_text(encoding="utf-8"))["results"].items():
            print(f"  {who:6} {'PASS' if passed else 'FAIL'}  {name}")
            failures += 0 if passed else 1
    print("screenshots:", sorted(p.name for p in shared.glob("*.png")))
    print(f"visual test: {failures} failure(s); files in {shared}")
    return 1 if failures or not ok else 0


if __name__ == "__main__":
    sys.exit(main())
