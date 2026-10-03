"""Helpers for driving real Godot editors in tests (used by run_editor_tests.py)."""
import json
import os
import shutil
import subprocess
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
ADDON = REPO / "app" / "addons" / "godot_coop"
DEMO = REPO / "examples" / "demo_game"
GODOT = Path(os.environ.get("GODOT", r"C:\Users\djdan\Downloads\Godot_v4.7.2-stable_win64\Godot_v4.7.2-stable_win64_console.exe"))


def install_addon(project: Path) -> None:
    dest = project / "addons" / "godot_coop"
    if dest.exists():
        shutil.rmtree(dest)
    shutil.copytree(ADDON, dest, ignore=shutil.ignore_patterns("*.uid"))
    cfg = (project / "project.godot").read_text(encoding="utf-8")
    if "[editor_plugins]" not in cfg:
        cfg = cfg.rstrip() + '\n\n[editor_plugins]\n\nenabled=PackedStringArray("res://addons/godot_coop/plugin.cfg")\n'
        (project / "project.godot").write_text(cfg, encoding="utf-8")


def make_project(dest: Path, with_demo=True) -> Path:
    if dest.exists():
        shutil.rmtree(dest)
    if with_demo:
        shutil.copytree(DEMO, dest)
    else:
        dest.mkdir(parents=True)
    install_addon(dest)
    return dest


def write_launch(project: Path, launch: dict) -> None:
    coop = project / ".coop"
    coop.mkdir(parents=True, exist_ok=True)
    launch = dict(launch)
    launch["created"] = time.time()
    (coop / "launch.json").write_text(json.dumps(launch), encoding="utf-8")


def import_project(project: Path, timeout=180) -> None:
    """First open imports assets; do it once up front so tests don't race the importer."""
    subprocess.run([str(GODOT), "--headless", "--editor", "--quit", "--path", str(project)],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=timeout)


def launch_editor(project: Path, env_extra: dict, headless=True, log: Path = None, extra_args=None):
    env = dict(os.environ)
    env.update(env_extra)
    args = [str(GODOT)]
    if headless:
        args.append("--headless")
    args += ["--editor", "--path", str(project)]
    if extra_args:
        args += extra_args
    out = open(log, "w", encoding="utf-8") if log else subprocess.DEVNULL
    return subprocess.Popen(args, env=env, stdout=out, stderr=subprocess.STDOUT)


def wait_for_file(path: Path, timeout: float) -> bool:
    end = time.time() + timeout
    while time.time() < end:
        if path.exists():
            return True
        time.sleep(0.25)
    return False
