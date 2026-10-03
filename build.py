"""Build Godot Co-op.

    python build.py                 # Windows app -> dist/GodotCoop/GodotCoop.exe
    python build.py --linux         # also a Linux build (the relay runs fine on a Linux server)
    python build.py --test          # run the automated test suites first

Needs a Godot 4.7.x editor with export templates installed. Set GODOT=path\\to\\Godot.exe if it
isn't found automatically.
"""
import os
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parent
APP = REPO / "app"
ADDON = APP / "addons" / "godot_coop"
DIST = REPO / "dist"


def find_godot() -> str:
    env = os.environ.get("GODOT")
    if env and Path(env).exists():
        return env
    home = Path.home()
    for base in [home / "Downloads", home / "Desktop", Path("C:/Godot"), Path("C:/Program Files")]:
        if base.exists():
            for p in sorted(base.rglob("Godot_v4*_console.exe"), reverse=True):
                return str(p)
            for p in sorted(base.rglob("Godot_v4*.exe"), reverse=True):
                return str(p)
    sys.exit("Couldn't find Godot. Set the GODOT environment variable to your Godot 4.7 editor executable.")


def run(args, **kw):
    print(">", " ".join(str(a) for a in args))
    r = subprocess.run([str(a) for a in args], stdin=subprocess.DEVNULL, **kw)
    if r.returncode != 0:
        sys.exit(f"command failed ({r.returncode})")


def zip_addon(dest: Path, prefix: str) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(dest, "w", zipfile.ZIP_DEFLATED) as z:
        for f in sorted(ADDON.rglob("*")):
            if f.is_file() and f.suffix not in (".uid", ".import"):
                z.write(f, prefix + f.relative_to(ADDON).as_posix())
    print("wrote", dest)


def main() -> None:
    godot = find_godot()
    print("using", godot)
    if "--test" in sys.argv:
        for t in ("unit_tests", "app_tests", "net_tests"):
            run([godot, "--headless", "--path", APP, "-s", f"res://tests/{t}.gd"])
        run([sys.executable, REPO / "tests" / "editor" / "run_editor_tests.py"])
    # 1. The plugin travels inside the app as a zip so the app can install it into projects.
    zip_addon(APP / "payload" / "godot_coop_addon.zip", "")
    # 2. Icon.
    if not (APP / "icon.ico").exists():
        run([godot, "--headless", "--path", APP, "-s", REPO / "tools" / "make_icon.gd"])
    # 3. Import + export.
    run([godot, "--headless", "--editor", "--quit", "--path", APP])
    out = DIST / "GodotCoop"
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    run([godot, "--headless", "--path", APP, "--export-release", "Windows Desktop", out / "GodotCoop.exe"])
    if "--linux" in sys.argv:
        lout = DIST / "GodotCoop-linux"
        lout.mkdir(parents=True, exist_ok=True)
        run([godot, "--headless", "--path", APP, "--export-release", "Linux", lout / "GodotCoop.x86_64"])
    # 4. Extras next to the exe.
    zip_addon(DIST / "godot_coop_plugin.zip", "addons/godot_coop/")
    shutil.copy(REPO / "README.md", out / "README.md")
    shutil.copytree(REPO / "web", out / "web", dirs_exist_ok=True)
    (out / "Run relay server.cmd").write_text(
        '@echo off\r\necho Godot Co-op relay - forward UDP 47600-47601 to this PC\r\n'
        '"%~dp0GodotCoop.console.exe" --headless -- --relay --port 47600\r\npause\r\n', encoding="ascii")
    print("\nBuilt:", out / "GodotCoop.exe")


if __name__ == "__main__":
    main()
