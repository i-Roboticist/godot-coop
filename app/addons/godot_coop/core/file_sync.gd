@tool
extends RefCounted
## File synchronisation engine, shared by the host, joined editors and the companion's downloader.
##
## The host's copy of the project is the source of truth. Every peer remembers the hash of the host's
## version of each file it last synced (`base`). That makes reconnects a three-way merge:
## changed only here -> upload, changed only on the host -> download, changed on both -> host wins
## and the local copy is backed up to .coop/conflicts/.
##
## Files go over the FILES channel: small ones in one message, big ones in 48 KB chunks with a 1 MB
## in-flight window per destination. Every transfer lands in a temp file, is verified by SHA-256,
## then moved into place, so a half-received file never appears in the project.

const Util := preload("res://addons/godot_coop/core/util.gd")
const Security := preload("res://addons/godot_coop/core/security.gd")

signal file_applied(rel: String, by: int, deleted: bool)
## Host: a new version of `rel` was accepted (placed, or held back because the file is open). `src`
## holds its contents; `live` means the sender has it open as a live document.
signal file_received(rel: String, by: int, src: String, live: bool)
signal local_change(rel: String, deleted: bool)
signal progress(done_bytes: int, total_bytes: int, current: String)
signal sync_finished(summary: Dictionary)
signal quarantine_changed()
signal deferred_changed()
signal rejected(rel: String, reason: String)
signal plan_preview(plan: Dictionary)
## A version of `rel` was about to be lost (two people changed it at once): a copy is at `backup`.
signal conflict_saved(rel: String, backup: String)

const CHUNK := 48 * 1024
const SMALL := 48 * 1024
const WINDOW := 1024 * 1024
const MAX_FILE := 2 * 1024 * 1024 * 1024
const HOT_SECONDS := 4

var root := ""
var is_host := false
var my_id := 0
var send_fn: Callable            # func(dest: int, msg: Dictionary) -> void
var can_write_fn: Callable       # host only: func(pid: int, rel: String) -> bool
var is_open_fn: Callable         # func(rel: String) -> bool   (open in the local editor => defer write)
var live_fn: Callable            # func(rel: String) -> bool   (a live document here: its edits go live)
var peers_fn: Callable           # host only: func() -> Array[int] of synced remote peers
var manage_project_godot := true
var trust_risky := false
var ignore_patterns := PackedStringArray()

var base := {}                   # rel -> hash of the host's version we last synced
var pending_up := {}             # joiner: rel -> base before our change, until the host confirms it
var deferred := {}               # rel -> {"tmp": abs or "", "hash": h, "disk_hash": h0, "by": pid}
var quarantine := {}             # rel -> {"tmp": abs, "hash": h, "by": pid, "reason": s, "from": pid}
var stats := {"sent": 0, "received": 0}
var conflict_backups := PackedStringArray()
var min_pass_interval_ms := 1000
var _last_pass_end_ms := -100000

var _scan := {}                  # rel -> mtime
var _scan_queue: Array = []
var _scan_seen := {}
var _scan_running := false
var _out := {}                   # dest -> {"queue": [], "active": {}, "inflight": int}
var _in := {}                    # "src:xid" -> transfer record
var _xid := 0
var _expect_total := 0
var _expect_done := 0
var _expect_files := {}          # rel -> true (files we are waiting for during initial sync)
var _syncing := false
var _state_dirty := false
var _state_saved_ms := 0
var _hash_cache := {}            # rel -> [mtime, size, hash], so rescans skip unchanged files
var _replaced: Array = []        # old spellings _place just removed (case-only renames)


func setup(project_root: String, host: bool, my_peer_id: int) -> void:
	root = project_root.trim_suffix("/").trim_suffix("\\").replace("\\", "/")
	is_host = host
	my_id = my_peer_id
	ignore_patterns = Util.read_ignore_patterns(root)
	Util.ensure_dir(_coop("tmp"))
	_clean_tmp()


func _coop(sub := "") -> String:
	var d := root.path_join(Util.COOP_DIR)
	return d if sub.is_empty() else d.path_join(sub)


func abs_path(rel: String) -> String:
	return root.path_join(rel)


func _clean_tmp() -> void:
	var d := _coop("tmp")
	for f in DirAccess.get_files_at(d):
		DirAccess.remove_absolute(d.path_join(f))


func is_synced_path(rel: String) -> bool:
	if Util.is_ignored(rel, ignore_patterns):
		return false
	if rel == "project.godot" and not manage_project_godot:
		return false
	return true


# ---------------------------------------------------------------------------------------------
# Local state

func load_state() -> void:
	var d = Util.read_json(_coop("sync_state.json"), {})
	base = d.get("base", {}) if d is Dictionary else {}
	pending_up = d.get("pending", {}) if d is Dictionary and d.get("pending") is Dictionary else {}


func save_state(force := false) -> void:
	if not force and (not _state_dirty or Util.now_ms() - _state_saved_ms < 2000):
		return
	_state_dirty = false
	_state_saved_ms = Util.now_ms()
	if not is_host:
		Util.write_json(_coop("sync_state.json"), {"base": base, "pending": pending_up})
	if force:
		Util.write_json(_coop("hash_cache.json"), _hash_cache)


func _set_base(rel: String, h: String) -> void:
	if h.is_empty():
		base.erase(rel)
	else:
		base[rel] = h
	_state_dirty = true


## Hashes every synced file (blocking). Returns rel -> hash.
func full_scan() -> Dictionary:
	var out := {}
	_scan.clear()
	if _hash_cache.is_empty():
		var hc = Util.read_json(_coop("hash_cache.json"), {})
		_hash_cache = hc if hc is Dictionary else {}
	var stack: Array = [""]
	while not stack.is_empty():
		var d: String = stack.pop_back()
		var abs_dir := root if d.is_empty() else root.path_join(d)
		var da := DirAccess.open(abs_dir)
		if da == null:
			continue
		da.include_hidden = true
		for sub in da.get_directories():
			var rel_dir := sub if d.is_empty() else d + "/" + sub
			if Util.is_ignored(rel_dir + "/x", ignore_patterns):
				continue
			stack.append(rel_dir)
		for f in da.get_files():
			var rel := f if d.is_empty() else d + "/" + f
			if not is_synced_path(rel):
				continue
			var a := abs_path(rel)
			var mt := FileAccess.get_modified_time(a)
			out[rel] = _cached_hash(rel, a, mt)
			_scan[rel] = mt
	return out


## SHA-256 of a file, reusing the last one while its time stamp and size are unchanged (and it
## wasn't modified in the last few seconds, which a one-second time stamp can't tell apart).
func _cached_hash(rel: String, a: String, mt: int) -> String:
	var size := FileAccess.get_size(a)
	var c = _hash_cache.get(rel)
	if c is Array and c.size() == 3 and int(c[0]) == mt and int(c[1]) == size and Util.unix_time() - mt > HOT_SECONDS:
		return String(c[2])
	var h := FileAccess.get_sha256(a)
	_hash_cache[rel] = [mt, size, h]
	return h


## Host: become the source of truth for the current disk contents.
func init_host_manifest() -> void:
	base = full_scan()


func _disk_hash(rel: String) -> String:
	return Util.file_hash(abs_path(rel))


## Where to read the host's current version of a file from (deferred writes live in temp files).
func _source_path(rel: String) -> String:
	if deferred.has(rel) and not String(deferred[rel].tmp).is_empty():
		return deferred[rel].tmp
	return abs_path(rel)


# ---------------------------------------------------------------------------------------------
# Incremental change detection (call scan_step every frame)

func scan_step(budget_usec := 2500) -> void:
	var t0 := Time.get_ticks_usec()
	if not _scan_running:
		if Util.now_ms() - _last_pass_end_ms < min_pass_interval_ms:
			return
		_scan_queue = [""]
		_scan_seen = {}
		_scan_running = true
	while Time.get_ticks_usec() - t0 < budget_usec:
		if _scan_queue.is_empty():
			for rel in _scan.keys():
				if not _scan_seen.has(rel):
					_scan.erase(rel)
					_on_local_missing(rel)
			_scan_running = false
			_last_pass_end_ms = Util.now_ms()
			return
		var d: String = _scan_queue.pop_back()
		var abs_dir := root if d.is_empty() else root.path_join(d)
		var da := DirAccess.open(abs_dir)
		if da == null:
			continue
		da.include_hidden = true
		for sub in da.get_directories():
			var rel_dir := sub if d.is_empty() else d + "/" + sub
			if not Util.is_ignored(rel_dir + "/x", ignore_patterns):
				_scan_queue.append(rel_dir)
		for f in da.get_files():
			var rel := f if d.is_empty() else d + "/" + f
			if not is_synced_path(rel):
				continue
			_scan_seen[rel] = true
			check_path(rel)


## Re-examines one path right now (used by editor save hooks too).
func check_path(rel: String) -> void:
	if not is_synced_path(rel) or quarantine.has(rel):
		return
	var a := abs_path(rel)
	if not FileAccess.file_exists(a):
		if _scan.has(rel):
			_scan.erase(rel)
			_on_local_missing(rel)
		return
	var mt := FileAccess.get_modified_time(a)
	var hot := Util.unix_time() - mt < HOT_SECONDS and FileAccess.get_size(a) < 2 * 1024 * 1024
	if _scan.get(rel, -1) == mt and not hot:
		return
	_scan[rel] = mt
	var h := FileAccess.get_sha256(a)
	if h.is_empty():
		return
	_hash_cache[rel] = [mt, FileAccess.get_size(a), h]
	if deferred.has(rel):
		if h == String(deferred[rel].disk_hash):
			return
		# The user saved over a deferred incoming version: their save wins from here on.
		_drop_deferred(rel)
	if h != String(base.get(rel, "")):
		_on_local_change(rel, h)


func _on_local_change(rel: String, h: String) -> void:
	var b := String(base.get(rel, ""))
	_set_base(rel, h)
	if is_host:
		for pid in _remote_peers():
			queue_put(pid, rel, my_id, b)
	else:
		# Remember what the host had until it confirms ours, so a drop or a quit can't lose it.
		if not pending_up.has(rel):
			pending_up[rel] = b
		queue_put(1, rel, my_id, String(pending_up[rel]), live_fn.is_valid() and live_fn.call(rel))
	local_change.emit(rel, false)


func _on_local_missing(rel: String) -> void:
	if deferred.has(rel) or not base.has(rel):
		return
	if _case_insensitive_fs() and FileAccess.file_exists(abs_path(rel)):
		# Only the case of the name changed ("Player.gd" -> "player.gd"): not a deletion.
		base.erase(rel)
		_state_dirty = true
		return
	var b := String(base[rel])
	_set_base(rel, "")
	if is_host:
		for pid in _remote_peers():
			queue_del(pid, rel, my_id, b)
	else:
		if not pending_up.has(rel):
			pending_up[rel] = b
		queue_del(1, rel, my_id, String(pending_up[rel]))
	local_change.emit(rel, true)


static func _case_insensitive_fs() -> bool:
	return OS.get_name() in ["Windows", "macOS"]


## True if `rel` exists with exactly this spelling (on Windows "player.gd" also opens "Player.gd").
func _exact_name(rel: String) -> bool:
	return DirAccess.get_files_at(abs_path(rel).get_base_dir()).has(rel.get_file())


func _remote_peers() -> Array:
	return peers_fn.call() if peers_fn.is_valid() else []


# ---------------------------------------------------------------------------------------------
# Initial sync / reconnect (three-way)

func begin_sync(preview := false) -> void:
	var cur := full_scan()
	var files := {}
	# For changes the host hasn't confirmed, report the version we started from, so the planner
	# sees them as ours (upload) rather than the host's (download over them).
	for rel in cur:
		files[rel] = [cur[rel], String(pending_up.get(rel, base.get(rel, "")))]
	for rel in base:
		if not files.has(rel) and is_synced_path(rel):
			files[rel] = ["", String(pending_up.get(rel, base[rel]))]
	for rel in pending_up:
		if not files.has(rel) and is_synced_path(rel):
			files[rel] = ["", String(pending_up[rel])]
	_syncing = not preview
	send_fn.call(1, {"t": "sync_begin", "files": files, "preview": preview, "project_godot": manage_project_godot})


## Pure three-way planner (host side). client_files: rel -> [current_hash, base_hash].
static func plan_sync(host_files: Dictionary, client_files: Dictionary, allow_upload: Callable) -> Dictionary:
	var send := []
	var delete := []
	var upload := []
	var host_delete := []
	var conflicts := []
	var keys := {}
	for k in host_files:
		keys[k] = true
	for k in client_files:
		keys[k] = true
	for rel in keys:
		var h := String(host_files.get(rel, ""))
		var c := ""
		var b := ""
		if client_files.has(rel):
			var e = client_files[rel]
			if e is Array and e.size() == 2:
				c = String(e[0])
				b = String(e[1])
		if c == h:
			continue
		if c == b:
			# Only the host changed (or the client never had it).
			if h.is_empty():
				delete.append(rel)
			else:
				send.append(rel)
		elif h == b and allow_upload.call(rel):
			# Only the client changed while it was away.
			if c.is_empty():
				host_delete.append(rel)
			else:
				upload.append(rel)
		else:
			# Both changed (or the client may not write here): the host's version wins.
			if not c.is_empty():
				conflicts.append(rel)
			if h.is_empty():
				delete.append(rel)
			else:
				send.append(rel)
	return {"send": send, "delete": delete, "upload": upload, "host_delete": host_delete, "conflicts": conflicts}


## Host: answer a peer's sync_begin.
func host_handle_sync_begin(pid: int, msg: Dictionary) -> void:
	var files: Dictionary = msg.get("files", {})
	var include_pg := bool(msg.get("project_godot", true))
	var host_files := {}
	for rel in base:
		if rel == "project.godot" and not include_pg:
			continue
		host_files[rel] = base[rel]
	var clean := {}
	for rel in files:
		if typeof(rel) == TYPE_STRING and Util.is_safe_rel_path(rel) and is_synced_path(rel):
			if rel == "project.godot" and not include_pg:
				continue
			clean[rel] = files[rel]
	var allow := func(rel): return can_write_fn.call(pid, rel) if can_write_fn.is_valid() else false
	var plan := plan_sync(host_files, clean, allow)
	var total := 0
	var risky := []
	for rel in plan.send:
		var a := _source_path(rel)
		total += FileAccess.get_size(a)
		var reason := Security.risk_reason(rel, a)
		if not reason.is_empty():
			risky.append([rel, reason])
	var reply := plan.duplicate()
	reply["t"] = "sync_plan"
	reply["total"] = total
	reply["risky"] = risky
	reply["count"] = plan.send.size()
	reply["preview"] = bool(msg.get("preview", false))
	send_fn.call(pid, reply)
	if reply.preview:
		return
	for rel in plan.host_delete:
		if base.has(rel):
			var b := String(base[rel])
			_apply_delete_local(rel, pid)
			for other in _remote_peers():
				if other != pid:
					queue_del(other, rel, pid, b)
	for rel in plan.send:
		queue_put(pid, rel, 1, String(base.get(rel, "")))
	for rel in plan.delete:
		queue_del(pid, rel, 1, "")
	_queue_msg(pid, {"t": "sync_done"})


func _client_handle_plan(msg: Dictionary) -> void:
	if msg.get("preview", false):
		plan_preview.emit(msg)
		return
	var stamp := Time.get_datetime_string_from_system().replace(":", "-")
	for rel in msg.get("conflicts", []):
		if typeof(rel) == TYPE_STRING and Util.is_safe_rel_path(rel) and FileAccess.file_exists(abs_path(rel)):
			var backup := _coop("conflicts").path_join(stamp).path_join(rel)
			Util.ensure_dir(backup.get_base_dir())
			DirAccess.copy_absolute(abs_path(rel), backup)
			conflict_backups.append(backup)
	var uploading := {}
	for rel in msg.get("upload", []):
		# Only files we actually sync: the host can't make us send anything else.
		if typeof(rel) == TYPE_STRING and Util.is_safe_rel_path(rel) and is_synced_path(rel):
			var was := String(pending_up.get(rel, base.get(rel, "")))
			_set_base(rel, _disk_hash(rel))
			pending_up[rel] = was
			uploading[rel] = true
			queue_put(1, rel, my_id, was)
	for rel in msg.get("host_delete", []):
		if typeof(rel) == TYPE_STRING:
			_set_base(rel, "")
	# Everything else the host has now settled.
	for rel in pending_up.keys():
		if not uploading.has(rel):
			pending_up.erase(rel)
	_state_dirty = true
	_expect_total = int(msg.get("total", 0))
	_expect_done = 0
	_expect_files.clear()
	for rel in msg.get("send", []):
		_expect_files[rel] = true
	progress.emit(0, _expect_total, "")


func _outq(dest: int) -> Dictionary:
	if not _out.has(dest):
		_out[dest] = {"queue": [], "active": {}, "inflight": 0}
	return _out[dest]


func queue_put(dest: int, rel: String, by: int, base_hash: String, live := false) -> void:
	var q := _outq(dest)
	# Drop an older pending put of the same file - only the latest content matters.
	for i in range(q.queue.size() - 1, -1, -1):
		var j: Dictionary = q.queue[i]
		if j.kind == "put" and j.rel == rel:
			q.queue.remove_at(i)
	var job := {"kind": "put", "rel": rel, "by": by, "base": base_hash, "live": live}
	# A file's .import / .uid go before the file itself, so the receiving editor imports it with
	# the sender's settings and UID instead of making up its own (and sending those back).
	if rel.ends_with(".import") or rel.ends_with(".uid"):
		var main_rel := rel.trim_suffix(".import") if rel.ends_with(".import") else rel.trim_suffix(".uid")
		for i in q.queue.size():
			var j: Dictionary = q.queue[i]
			if j.kind == "put" and j.rel == main_rel:
				q.queue.insert(i, job)
				return
	q.queue.append(job)


func queue_del(dest: int, rel: String, by: int, base_hash: String) -> void:
	var q := _outq(dest)
	for i in range(q.queue.size() - 1, -1, -1):
		var j: Dictionary = q.queue[i]
		if j.kind == "put" and j.rel == rel:
			q.queue.remove_at(i)
	q.queue.append({"kind": "del", "rel": rel, "by": by, "base": base_hash})


func _queue_msg(dest: int, msg: Dictionary) -> void:
	_outq(dest).queue.append({"kind": "msg", "msg": msg})


func drop_peer(dest: int) -> void:
	if _out.has(dest):
		var a: Dictionary = _out[dest].active
		if a.has("file") and a.file != null:
			a.file.close()
		_out.erase(dest)
	for key in _in.keys():
		if key.begins_with(str(dest) + ":"):
			var t: Dictionary = _in[key]
			if t.file != null:
				t.file.close()
			DirAccess.remove_absolute(t.tmp)
			_in.erase(key)


func pending_out_bytes() -> int:
	var n := 0
	for d in _out:
		n += int(_out[d].inflight) + _out[d].queue.size()
	return n


func is_idle() -> bool:
	for d in _out:
		var q: Dictionary = _out[d]
		if not q.queue.is_empty() or not q.active.is_empty():
			return false
	return _in.is_empty()


func poll() -> void:
	for dest in _out.keys():
		_pump(dest)
	save_state()


func _pump(dest: int) -> void:
	var q: Dictionary = _out[dest]
	var guard := 0
	while q.inflight < WINDOW and guard < 64:
		guard += 1
		if q.active.is_empty():
			if q.queue.is_empty():
				return
			var job: Dictionary = q.queue.pop_front()
			if job.kind == "msg":
				send_fn.call(dest, job.msg)
				continue
			if job.kind == "del":
				send_fn.call(dest, {"t": "file_del", "rel": job.rel, "by": job.by, "base": job.base})
				continue
			_start_put(dest, q, job)
			continue
		var a: Dictionary = q.active
		if a.off >= a.size:
			send_fn.call(dest, {"t": "file_end", "xid": a.xid})
			a.file.close()
			q.active = {}
			continue
		var n := mini(CHUNK, a.size - a.off)
		var data: PackedByteArray = a.file.get_buffer(n)
		if data.size() != n:
			# File shrank while sending; the receiver will notice the hash mismatch and ask again.
			data.resize(n)
		send_fn.call(dest, {"t": "file_chunk", "xid": a.xid, "off": a.off, "data": data})
		a.off += n
		q.inflight += n
		stats.sent += n


func _start_put(dest: int, q: Dictionary, job: Dictionary) -> void:
	var src := _source_path(job.rel)
	if not FileAccess.file_exists(src):
		return
	var size := FileAccess.get_size(src)
	if size > MAX_FILE:
		push_warning("Godot Co-op: skipping %s (too large)" % job.rel)
		return
	var h := FileAccess.get_sha256(src)
	_xid += 1
	if size <= SMALL:
		var data := FileAccess.get_file_as_bytes(src)
		send_fn.call(dest, {"t": "file_put", "xid": _xid, "rel": job.rel, "hash": h, "data": data, "by": job.by, "base": job.base, "live": bool(job.get("live", false))})
		q.inflight += maxi(size, 1)
		stats.sent += size
		return
	var f := FileAccess.open(src, FileAccess.READ)
	if f == null:
		return
	send_fn.call(dest, {"t": "file_begin", "xid": _xid, "rel": job.rel, "hash": h, "size": size, "by": job.by, "base": job.base, "live": bool(job.get("live", false))})
	q.active = {"xid": _xid, "file": f, "size": size, "off": 0}


func _on_ack(dest: int, msg: Dictionary) -> void:
	if _out.has(dest):
		_out[dest].inflight = maxi(0, int(_out[dest].inflight) - int(msg.get("n", 0)))


# ---------------------------------------------------------------------------------------------
# Incoming

## Routes a file-channel message. `from` is the sender's peer id (1 = host).
func handle(from: int, msg: Dictionary) -> void:
	match String(msg.get("t", "")):
		"file_ack":
			_on_ack(from, msg)
		"sync_begin":
			if is_host:
				host_handle_sync_begin(from, msg)
		"sync_plan":
			if not is_host:
				_client_handle_plan(msg)
		"sync_done":
			if not is_host:
				_syncing = false
				save_state(true)
				sync_finished.emit({"bytes": _expect_done})
		"file_put":
			_recv_put(from, msg)
		"file_begin":
			_recv_begin(from, msg)
		"file_chunk":
			_recv_chunk(from, msg)
		"file_end":
			_recv_end(from, msg)
		"file_del":
			_recv_del(from, msg)
		"file_get":
			if is_host:
				for rel in msg.get("rels", []):
					if typeof(rel) == TYPE_STRING and base.has(rel):
						queue_put(from, rel, 1, "")
		"file_ok":
			# The host has our change (or our delete): it's safe now.
			if not is_host:
				var rel := String(msg.get("rel", ""))
				if pending_up.has(rel) and String(base.get(rel, "")) == String(msg.get("hash", "")):
					pending_up.erase(rel)
					_state_dirty = true
		"file_reject":
			if not is_host:
				pending_up.erase(String(msg.get("rel", "")))
				rejected.emit(String(msg.get("rel", "")), String(msg.get("reason", "")))


## On the host, the sender is always the author (a client can't claim to be someone else).
func _author(from: int, msg: Dictionary) -> int:
	return from if is_host else int(msg.get("by", from))


func _valid_incoming(from: int, rel, msg: Dictionary) -> bool:
	if typeof(rel) != TYPE_STRING or not Util.is_safe_rel_path(rel) or not is_synced_path(rel):
		return false
	if is_host and rel == "project.godot":
		# Project settings go through the settings sync, where autoloads and plugins wait for review.
		send_fn.call(from, {"t": "file_reject", "rel": rel, "reason": "Project settings are synced separately."})
		return false
	if is_host and not (can_write_fn.is_valid() and can_write_fn.call(from, rel)):
		send_fn.call(from, {"t": "file_reject", "rel": rel, "reason": "You don't have write access to this file."})
		# Restore the sender's copy to the host's version.
		if base.has(rel):
			queue_put(from, rel, 1, "")
		else:
			queue_del(from, rel, 1, "")
		return false
	return true


func _recv_put(from: int, msg: Dictionary) -> void:
	var rel = msg.get("rel")
	var data = msg.get("data")
	send_fn.call(from, {"t": "file_ack", "xid": msg.get("xid", 0), "n": maxi(1, data.size() if data is PackedByteArray else 1)})
	if not (data is PackedByteArray) or not _valid_incoming(from, rel, msg):
		return
	stats.received += data.size()
	if Util.sha256_hex(data) != String(msg.get("hash", "")):
		if not is_host:
			send_fn.call(1, {"t": "file_get", "rels": [rel]})
		return
	var tmp := _coop("tmp").path_join("%d_%s.part" % [from, Util.random_hex(4)])
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return
	f.store_buffer(data)
	f.close()
	_commit(from, rel, tmp, String(msg.hash), _author(from, msg), data.size(), bool(msg.get("live", false)), String(msg.get("base", "")))


func _recv_begin(from: int, msg: Dictionary) -> void:
	var rel = msg.get("rel")
	var size := int(msg.get("size", 0))
	if not _valid_incoming(from, rel, msg) or size < 0 or size > MAX_FILE:
		_in["%d:%d" % [from, int(msg.get("xid", 0))]] = {"skip": true, "file": null, "tmp": ""}
		return
	var tmp := _coop("tmp").path_join("%d_%d.part" % [from, int(msg.get("xid", 0))])
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	_in["%d:%d" % [from, int(msg.xid)]] = {
		"rel": rel, "hash": String(msg.get("hash", "")), "size": size, "file": f, "tmp": tmp,
		"got": 0, "by": _author(from, msg), "skip": f == null, "live": bool(msg.get("live", false)),
		"base": String(msg.get("base", "")),
	}


func _recv_chunk(from: int, msg: Dictionary) -> void:
	var key := "%d:%d" % [from, int(msg.get("xid", 0))]
	var data = msg.get("data")
	var n: int = data.size() if data is PackedByteArray else 0
	send_fn.call(from, {"t": "file_ack", "xid": msg.get("xid", 0), "n": n})
	if not _in.has(key):
		return
	var t: Dictionary = _in[key]
	if t.skip or n == 0:
		return
	if int(msg.get("off", -1)) != t.got or t.got + n > t.size:
		t.skip = true
		return
	t.file.store_buffer(data)
	t.got += n
	stats.received += n
	if _expect_files.has(t.rel):
		progress.emit(_expect_done + t.got, _expect_total, t.rel)


func _recv_end(from: int, msg: Dictionary) -> void:
	var key := "%d:%d" % [from, int(msg.get("xid", 0))]
	if not _in.has(key):
		return
	var t: Dictionary = _in[key]
	_in.erase(key)
	if t.file != null:
		t.file.close()
	if t.skip:
		if not String(t.tmp).is_empty():
			DirAccess.remove_absolute(t.tmp)
		if t.has("rel") and not is_host:
			send_fn.call(1, {"t": "file_get", "rels": [t.rel]})
		return
	if FileAccess.get_sha256(t.tmp) != t.hash:
		DirAccess.remove_absolute(t.tmp)
		if not is_host:
			send_fn.call(1, {"t": "file_get", "rels": [t.rel]})
		return
	_commit(from, t.rel, t.tmp, t.hash, t.by, t.size, bool(t.get("live", false)), String(t.get("base", "")))


func _recv_del(from: int, msg: Dictionary) -> void:
	var rel = msg.get("rel")
	if not _valid_incoming(from, rel, msg):
		return
	if is_host and not base.has(rel):
		_confirm(from, rel, "")
		return
	if is_host:
		var b := String(base.get(rel, ""))
		_apply_delete_local(rel, _author(from, msg))
		for pid in _remote_peers():
			if pid != from:
				queue_del(pid, rel, _author(from, msg), b)
		_confirm(from, rel, "")
	else:
		_apply_delete_local(rel, _author(from, msg))


## Host: tell the sender its change got here. Queued behind anything already on its way to them,
## so a version the host had before theirs arrives first (and they know to keep their own).
func _confirm(from: int, rel: String, h: String) -> void:
	if is_host and from != my_id:
		_queue_msg(from, {"t": "file_ok", "rel": rel, "hash": h})


func _save_conflict_copy(rel: String, src: String, tag := "") -> void:
	if not FileAccess.file_exists(src):
		return
	var stamp := Time.get_datetime_string_from_system().replace(":", "-")
	var name := rel
	if not tag.is_empty():
		name = rel.get_basename() + "." + tag + ("." + rel.get_extension() if not rel.get_extension().is_empty() else "")
	var backup := _coop("conflicts").path_join(stamp).path_join(name)
	Util.ensure_dir(backup.get_base_dir())
	DirAccess.copy_absolute(src, backup)
	conflict_backups.append(backup)
	conflict_saved.emit(rel, backup)


## A verified file has arrived in `tmp`; decide whether it goes in place, waits for review, or is deferred.
func _commit(from: int, rel: String, tmp: String, h: String, by: int, size: int, live := false, sender_base := "") -> void:
	if _expect_files.has(rel):
		_expect_files.erase(rel)
		_expect_done += size
		progress.emit(_expect_done, _expect_total, rel)
	var unchanged := String(base.get(rel, "")) == h and _disk_hash(rel) == h and not deferred.has(rel)
	if unchanged:
		DirAccess.remove_absolute(tmp)
		_confirm(from, rel, h)
		return
	if not trust_risky:
		var reason := Security.risk_reason(rel, tmp)
		if not reason.is_empty():
			var qtmp := _coop("quarantine").path_join(Util.random_hex(6) + "_" + rel.get_file())
			Util.move_file(tmp, qtmp)
			if quarantine.has(rel):
				DirAccess.remove_absolute(quarantine[rel].tmp)
			quarantine[rel] = {"tmp": qtmp, "hash": h, "by": by, "from": from, "reason": reason, "live": live, "sbase": sender_base}
			quarantine_changed.emit()
			_confirm(from, rel, h)
			return
	_accept(from, rel, tmp, h, by, live, sender_base)


func _accept(from: int, rel: String, tmp: String, h: String, by: int, live := false, sender_base := "") -> void:
	var prev_base := String(base.get(rel, ""))
	var dest := abs_path(rel)
	if not is_host:
		if pending_up.has(rel):
			# Our own change to this file is on its way to the host, which got this version first
			# and will replace it with ours: keep ours (and a copy of this one, just in case).
			_save_conflict_copy(rel, tmp, "theirs")
			DirAccess.remove_absolute(tmp)
			return
		if FileAccess.file_exists(dest):
			var cur := _disk_hash(rel)
			if cur != h and cur != prev_base:
				# Changed here and not sent yet: keep a copy before it's replaced.
				_save_conflict_copy(rel, dest)
	elif from != my_id and prev_base != h and sender_base != prev_base and FileAccess.file_exists(dest):
		# Two people saved it at once and the sender edited an older version: keep the host's copy.
		_save_conflict_copy(rel, dest)
	if is_open_fn.is_valid() and is_open_fn.call(rel):
		var qtmp := _coop("deferred").path_join(Util.random_hex(6) + "_" + rel.get_file())
		Util.move_file(tmp, qtmp)
		if deferred.has(rel) and not String(deferred[rel].tmp).is_empty():
			DirAccess.remove_absolute(deferred[rel].tmp)
		deferred[rel] = {"tmp": qtmp, "hash": h, "disk_hash": _disk_hash(rel), "by": by}
		deferred_changed.emit()
		if is_host:
			# The host's list of versions moves on now. A joiner's only once the file is written
			# (flush_deferred): until then its disk still has the old one.
			_set_base(rel, h)
			file_received.emit(rel, by, qtmp, live)
	else:
		_replaced.clear()
		if not _place(rel, tmp):
			rejected.emit(rel, "it couldn't be written here (is it open in another program?)")
			return
		_set_base(rel, h)
		if is_host:
			file_received.emit(rel, by, dest, live)
		file_applied.emit(rel, by, false)
	if is_host:
		_confirm(from, rel, h)
		for pid in _remote_peers():
			if pid != from:
				queue_put(pid, rel, by, prev_base)
	# A case-only rename replaced the old spelling: forget it, and tell peers whose file systems
	# keep both spellings apart.
	for old in _replaced:
		if base.has(old):
			var b := String(base[old])
			_set_base(old, "")
			if is_host:
				for pid in _remote_peers():
					if pid != from:
						queue_del(pid, old, by, b)
	_replaced.clear()


## Moves a received file into place. False if it couldn't be written.
func _place(rel: String, tmp: String) -> bool:
	var dest := abs_path(rel)
	var dir := dest.get_base_dir()
	Util.ensure_dir(dir)
	if _case_insensitive_fs():
		# A case-only rename ("Player.gd" -> "player.gd") on a file system that ignores case:
		# remove the old spelling first, or the file would keep it.
		var want := rel.get_file()
		for f in DirAccess.get_files_at(dir):
			if f != want and f.to_lower() == want.to_lower():
				DirAccess.remove_absolute(dir.path_join(f))
				var old := (rel.get_base_dir() + "/" + f).trim_prefix("/")
				_scan.erase(old)
				_replaced.append(old)
	if DirAccess.rename_absolute(tmp, dest) != OK:
		# Target locked (e.g. open in another program): fall back to copying.
		DirAccess.copy_absolute(tmp, dest)
		DirAccess.remove_absolute(tmp)
	if not FileAccess.file_exists(dest):
		_scan.erase(rel)
		return false
	_scan[rel] = FileAccess.get_modified_time(dest)
	return true


func _apply_delete_local(rel: String, by: int) -> void:
	if not is_host and pending_up.has(rel):
		# We changed it and the host will get our version after this delete: keep it.
		return
	if is_open_fn.is_valid() and is_open_fn.call(rel):
		if is_host:
			_set_base(rel, "")
		deferred[rel] = {"tmp": "", "hash": "", "disk_hash": _disk_hash(rel), "by": by}
		deferred_changed.emit()
		return
	var prev := String(base.get(rel, ""))
	_set_base(rel, "")
	var a := abs_path(rel)
	if FileAccess.file_exists(a) and _exact_name(rel):
		if not is_host and _disk_hash(rel) != prev:
			_save_conflict_copy(rel, a)
		DirAccess.remove_absolute(a)
	_scan.erase(rel)
	file_applied.emit(rel, by, true)


## Call when the editor closes `rel`: writes the newest incoming version in place.
func flush_deferred(rel: String) -> void:
	if not deferred.has(rel):
		return
	var d: Dictionary = deferred[rel]
	deferred.erase(rel)
	if _disk_hash(rel) != String(d.disk_hash):
		# Saved locally after the deferral; check_path will upload it.
		if not String(d.tmp).is_empty():
			DirAccess.remove_absolute(d.tmp)
		deferred_changed.emit()
		check_path(rel)
		return
	if String(d.tmp).is_empty():
		var a := abs_path(rel)
		if FileAccess.file_exists(a) and _exact_name(rel):
			DirAccess.remove_absolute(a)
		_scan.erase(rel)
		if not is_host:
			_set_base(rel, "")
		file_applied.emit(rel, int(d.by), true)
	elif _place(rel, d.tmp):
		if not is_host:
			_set_base(rel, String(d.hash))
		file_applied.emit(rel, int(d.by), false)
	else:
		rejected.emit(rel, "it couldn't be written here (is it open in another program?)")
	deferred_changed.emit()


func _drop_deferred(rel: String) -> void:
	var d: Dictionary = deferred[rel]
	if not String(d.tmp).is_empty():
		DirAccess.remove_absolute(d.tmp)
	deferred.erase(rel)
	deferred_changed.emit()


func accept_quarantined(rel: String) -> void:
	if not quarantine.has(rel):
		return
	var q: Dictionary = quarantine[rel]
	quarantine.erase(rel)
	var tmp := _coop("tmp").path_join(Util.random_hex(6) + ".part")
	Util.move_file(q.tmp, tmp)
	_accept(int(q.from), rel, tmp, String(q.hash), int(q.by), bool(q.get("live", false)), String(q.get("sbase", "")))
	quarantine_changed.emit()


func reject_quarantined(rel: String) -> void:
	if not quarantine.has(rel):
		return
	var q: Dictionary = quarantine[rel]
	quarantine.erase(rel)
	DirAccess.remove_absolute(q.tmp)
	if is_host and int(q.from) != my_id:
		# Put the sender's copy back to the host's version.
		send_fn.call(int(q.from), {"t": "file_reject", "rel": rel, "reason": "The host declined this change after review."})
		if base.has(rel):
			queue_put(int(q.from), rel, 1, "")
		else:
			queue_del(int(q.from), rel, 1, "")
	quarantine_changed.emit()


func quarantined_text(rel: String) -> String:
	if not quarantine.has(rel):
		return ""
	var f := FileAccess.open(quarantine[rel].tmp, FileAccess.READ)
	if f == null:
		return ""
	return f.get_buffer(mini(200000, f.get_length())).get_string_from_utf8()


func is_syncing() -> bool:
	return _syncing
