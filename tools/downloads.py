"""Download counts for every Godot Co-op release (from GitHub's public API, no login needed).

    python tools/downloads.py             current totals per release
    python tools/downloads.py --history   totals over time, from the hourly snapshots that
                                          .github/workflows/download-stats.yml records
"""
import csv
import io
import json
import sys
import urllib.request

REPO = "i-Roboticist/godot-coop"


def current() -> None:
    releases = json.load(urllib.request.urlopen(f"https://api.github.com/repos/{REPO}/releases?per_page=100"))
    total = 0
    for r in releases:
        print(f"{r['tag_name']}  ({r['published_at'][:10]})")
        for a in r["assets"]:
            print(f"    {a['download_count']:>7}  {a['name']}")
            total += a["download_count"]
    print(f"\n{total} downloads in total")


def history() -> None:
    url = f"https://raw.githubusercontent.com/{REPO}/stats/stats/downloads.csv"
    try:
        text = urllib.request.urlopen(url).read().decode("utf-8")
    except Exception as e:
        sys.exit(f"No history yet ({e}). The workflow records a snapshot every hour.")
    totals: dict[str, list[int]] = {}
    for row in csv.DictReader(io.StringIO(text)):
        t = totals.setdefault(row["time"], [0, 0])
        t[0] += int(row["downloads"])
        if row["asset"] == "GodotCoop-windows.zip":
            t[1] += int(row["downloads"])
    prev = None
    print(f"{'time (UTC)':<18} {'total':>6} {'new':>5} {'app':>6}")
    for time, (total, app) in totals.items():
        new = "" if prev is None else f"+{total - prev}"
        print(f"{time:<18} {total:>6} {new:>5} {app:>6}")
        prev = total


if __name__ == "__main__":
    history() if "--history" in sys.argv else current()
