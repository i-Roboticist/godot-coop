@tool
extends RefCounted
## Thin wrapper around the git CLI (optional - everything works without git installed).

static func _run(dir: String, args: Array) -> Dictionary:
	var out := []
	var full := PackedStringArray(["-C", dir])
	for a in args:
		full.append(String(a))
	var code := OS.execute("git", full, out, true)
	return {"code": code, "out": String(out[0]).strip_edges() if not out.is_empty() else ""}


static func available() -> bool:
	var out := []
	return OS.execute("git", ["--version"], out, true) == 0


static func is_repo(dir: String) -> bool:
	return DirAccess.dir_exists_absolute(dir.path_join(".git")) or FileAccess.file_exists(dir.path_join(".git"))


## {head, branch, remote, dirty, ok}
static func info(dir: String) -> Dictionary:
	if not is_repo(dir) or not available():
		return {"ok": false}
	var head := _run(dir, ["rev-parse", "HEAD"])
	if head.code != 0:
		return {"ok": false}
	var branch := _run(dir, ["rev-parse", "--abbrev-ref", "HEAD"])
	var remote := _run(dir, ["config", "--get", "remote.origin.url"])
	var status := _run(dir, ["status", "--porcelain"])
	return {
		"ok": true, "head": head.out, "branch": branch.out,
		"remote": _strip_credentials(remote.out) if remote.code == 0 else "",
		"dirty": not String(status.out).is_empty(),
	}


## Never pass tokens embedded in remote URLs (https://user:token@host/...) to teammates.
static func _strip_credentials(url: String) -> String:
	var i := url.find("://")
	var at := url.find("@")
	if i != -1 and at > i:
		return url.substr(0, i + 3) + url.substr(at + 1)
	return url


static func compare(host: Dictionary, mine: Dictionary) -> String:
	if not host.get("ok", false):
		return ""
	if not mine.get("ok", false):
		return "The host's project is a git repo (%s @ %s) but your copy isn't." % [host.get("branch", "?"), String(host.get("head", "")).substr(0, 8)]
	if host.head != mine.head:
		return "Different commits: host is on %s @ %s, you are on %s @ %s. Files are synced live, but commit history differs." % [
			host.branch, String(host.head).substr(0, 8), mine.branch, String(mine.head).substr(0, 8)]
	return ""


static func commit_all(dir: String, message: String, coauthors: Array) -> Dictionary:
	var add := _run(dir, ["add", "-A"])
	if add.code != 0:
		return {"ok": false, "out": add.out}
	var msg := message.strip_edges()
	if not coauthors.is_empty():
		msg += "\n\n"
		for c in coauthors:
			msg += "Co-authored-by: %s <%s>\n" % [c.name, c.email]
	var f := dir.path_join(".coop").path_join("COMMIT_MSG.txt")
	var fa := FileAccess.open(f, FileAccess.WRITE)
	if fa == null:
		return {"ok": false, "out": "Couldn't write the commit message file"}
	fa.store_string(msg)
	fa.close()
	var res := _run(dir, ["commit", "-F", f])
	DirAccess.remove_absolute(f)
	return {"ok": res.code == 0, "out": res.out}


static func clone(url: String, dest: String, commit: String) -> Dictionary:
	var out := []
	var code := OS.execute("git", ["clone", url, dest], out, true)
	if code != 0:
		return {"ok": false, "out": String(out[0]) if not out.is_empty() else ""}
	if not commit.is_empty():
		var r := _run(dest, ["checkout", commit])
		if r.code != 0:
			return {"ok": false, "out": r.out}
	return {"ok": true, "out": ""}
