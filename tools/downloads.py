"""Download counts for every Godot Co-op release (from GitHub's public API, no login needed).

    python tools/downloads.py
"""
import json
import urllib.request

REPO = "i-Roboticist/godot-coop"

releases = json.load(urllib.request.urlopen(f"https://api.github.com/repos/{REPO}/releases?per_page=100"))
total = 0
for r in releases:
    print(f"{r['tag_name']}  ({r['published_at'][:10]})")
    for a in r["assets"]:
        print(f"    {a['download_count']:>7}  {a['name']}")
        total += a["download_count"]
print(f"\n{total} downloads in total")
