@tool
extends RefCounted
## Host-side referee for live documents: scenes (node/property ops) and scripts (text OT), plus
## per-scene edit locks. All peers - including the host's own editor - go through here.

const Util := preload("res://addons/godot_coop/core/util.gd")
const OT := preload("res://addons/godot_coop/core/ot.gd")
const SceneDoc := preload("res://addons/godot_coop/core/scene_doc.gd")
const TextDoc := preload("res://addons/godot_coop/core/text_doc.gd")
const Wire := preload("res://addons/godot_coop/core/wire.gd")

var project_dir := ""
var send_fn: Callable        # func(pid, msg)
var can_write_fn: Callable   # func(pid, rel) -> bool
var activity_fn: Callable    # func(pid, text, link, key)
var uuid_fn: Callable        # func(pid) -> String
var name_fn: Callable        # func(pid) -> String

var scenes := {}             # res path -> SceneDoc
var texts := {}              # res path -> TextDoc
var _file_cseq := 0

## A script document whose editors all dropped off (rather than closing it) is kept this long, so
## they resume it when they reconnect instead of starting over from the file on disk.
const ORPHAN_KEEP_MS := 10 * 60 * 1000


static func _valid_scene_path(p) -> bool:
	return typeof(p) == TYPE_STRING and Util.is_safe_res_path(p) and p.begins_with("res://") and p.get_extension() in ["tscn", "scn"]


static func _valid_text_path(p) -> bool:
	return typeof(p) == TYPE_STRING and Util.is_safe_res_path(p) and p.begins_with("res://")


func _send(pid: int, msg: Dictionary) -> void:
	send_fn.call(pid, msg)


func _to_watchers(watchers: Dictionary, msg: Dictionary, except := -1) -> void:
	for pid in watchers:
		if pid != except:
			_send(pid, msg)


func handle(pid: int, msg: Dictionary) -> void:
	var t := String(msg.get("t", ""))
	if t.begins_with("sc_") or t.begins_with("lock"):
		if not _valid_scene_path(msg.get("path")):
			return
	elif t.begins_with("tx_"):
		if not _valid_text_path(msg.get("path")):
			return
	match t:
		"sc_open":
			_sc_open(pid, msg.path)
		"sc_snapshot":
			_sc_snapshot(pid, msg)
		"sc_close":
			_sc_close(pid, msg.path)
		"sc_ops":
			_sc_ops(pid, msg)
		"sc_get":
			if scenes.has(msg.path) and not scenes[msg.path].root_id.is_empty():
				_send_state(pid, scenes[msg.path])
		"lock":
			_lock(pid, msg.path, bool(msg.get("on", false)))
		"lock_req":
			var doc = scenes.get(msg.path)
			if doc != null and doc.lock_holder != 0 and doc.lock_holder != pid:
				_send(doc.lock_holder, {"t": "lock_req", "path": msg.path, "from": pid})
		"lock_give":
			var doc = scenes.get(msg.path)
			var to := int(msg.get("to", 0))
			if doc != null and doc.lock_holder == pid and doc.watchers.has(to):
				doc.lock_holder = to
				_broadcast_lock(doc)
		"tx_open":
			_tx_open(pid, msg)
		"tx_close":
			_tx_close(pid, msg.path)
		"tx_op":
			_tx_op(pid, msg)
		"tx_cursor":
			var doc = texts.get(msg.path)
			if doc != null and doc.watchers.has(pid):
				_to_watchers(doc.watchers, {"t": "tx_cursor", "path": msg.path, "by": pid, "sel": msg.get("sel", [])}, pid)


func peer_left(pid: int) -> void:
	for path in scenes.keys():
		var doc = scenes[path]
		doc.waiting.erase(pid)
		if doc.lock_holder == pid:
			doc.lock_holder = 0
			_broadcast_lock(doc)
		if doc.watchers.has(pid):
			_sc_close(pid, path)
		elif doc.creator == pid:
			_reassign_creator(doc)
	for path in texts.keys():
		if texts[path].watchers.has(pid):
			_tx_close(pid, path, true)


## Drops script documents nobody came back to.
func prune() -> void:
	var now := Util.now_ms()
	for path in texts.keys():
		var doc = texts[path]
		if doc.watchers.is_empty() and doc.orphaned_ms > 0 and now - doc.orphaned_ms > ORPHAN_KEEP_MS:
			texts.erase(path)


func is_watching(pid: int, rel: String) -> bool:
	var doc = texts.get(Util.rel_to_res(rel))
	return doc != null and doc.watchers.has(pid)


# --- scenes ----------------------------------------------------------------------------------

func _send_state(pid: int, doc) -> void:
	_send(pid, {"t": "sc_state", "path": doc.path, "epoch": doc.epoch, "rev": doc.rev, "nodes": doc.snapshot(), "lock": doc.lock_holder})


func _sc_open(pid: int, path: String) -> void:
	var doc = scenes.get(path)
	if doc == null:
		doc = SceneDoc.new(path)
		scenes[path] = doc
	doc.watchers[pid] = true
	if not doc.root_id.is_empty():
		_send_state(pid, doc)
	elif doc.creator == 0:
		doc.creator = pid
		_send(pid, {"t": "sc_need_snapshot", "path": path})
	elif doc.creator != pid and not doc.waiting.has(pid):
		doc.waiting.append(pid)


func _reassign_creator(doc) -> void:
	doc.creator = 0
	while not doc.waiting.is_empty():
		var next: int = doc.waiting.pop_front()
		if doc.watchers.has(next):
			doc.creator = next
			_send(next, {"t": "sc_need_snapshot", "path": doc.path})
			return


func _sc_snapshot(pid: int, msg: Dictionary) -> void:
	var doc = scenes.get(msg.path)
	if doc == null or doc.creator != pid:
		return
	if not doc.load_snapshot(msg.get("nodes")):
		_reassign_creator(doc)
		return
	doc.creator = 0
	_send_state(pid, doc)
	for w in doc.waiting:
		if doc.watchers.has(w):
			_send_state(w, doc)
	doc.waiting.clear()


func _sc_close(pid: int, path: String) -> void:
	var doc = scenes.get(path)
	if doc == null:
		return
	doc.watchers.erase(pid)
	doc.waiting.erase(pid)
	if doc.lock_holder == pid:
		doc.lock_holder = 0
		_broadcast_lock(doc)
	if doc.creator == pid:
		_reassign_creator(doc)
	if doc.watchers.is_empty():
		scenes.erase(path)


func _sc_ops(pid: int, msg: Dictionary) -> void:
	var path: String = msg.path
	var doc = scenes.get(path)
	var cseq := int(msg.get("cseq", 0))
	if doc == null or doc.root_id.is_empty() or not doc.watchers.has(pid):
		_send(pid, {"t": "sc_reject", "path": path, "cseq": cseq, "reason": "not_open"})
		return
	if not can_write_fn.call(pid, Util.res_to_rel(path)):
		_send(pid, {"t": "sc_reject", "path": path, "cseq": cseq, "reason": "read_only"})
		return
	if doc.lock_holder != 0 and doc.lock_holder != pid:
		_send(pid, {"t": "sc_reject", "path": path, "cseq": cseq, "reason": "locked"})
		return
	var ops = msg.get("ops", [])
	if not (ops is Array):
		return
	var applied := []
	var descriptions := []
	var bad := false
	for op in ops:
		if not (op is Dictionary):
			bad = true
			continue
		var before := _describe_before(doc, op)
		var res = doc.apply(op)
		if res == null:
			bad = true
			continue
		applied.append(res)
		descriptions.append([before, res])
	if not applied.is_empty():
		doc.rev += 1
		_to_watchers(doc.watchers, {"t": "sc_ops", "path": path, "rev": doc.rev, "by": pid, "cseq": cseq, "ops": applied})
		_activity_for_ops(pid, doc, descriptions)
	if bad:
		_send(pid, {"t": "sc_reject", "path": path, "cseq": cseq, "reason": "conflict"})
	elif applied.is_empty():
		_send(pid, {"t": "sc_ops", "path": path, "rev": doc.rev, "by": pid, "cseq": cseq, "ops": []})


func _lock(pid: int, path: String, on: bool) -> void:
	var doc = scenes.get(path)
	if doc == null or not doc.watchers.has(pid):
		return
	if on:
		if (doc.lock_holder == 0 or doc.lock_holder == pid) and can_write_fn.call(pid, Util.res_to_rel(path)):
			doc.lock_holder = pid
	elif doc.lock_holder == pid or pid == 1:
		doc.lock_holder = 0
	_broadcast_lock(doc)


func _broadcast_lock(doc) -> void:
	_to_watchers(doc.watchers, {"t": "lock_state", "path": doc.path, "holder": doc.lock_holder})
	if doc.lock_holder != 0:
		activity_fn.call(doc.lock_holder, "locked %s for editing" % doc.path.get_file(), {"type": "scene", "path": doc.path}, "lock:" + doc.path)


# --- activity text for scene edits ---------------------------------------------------------------

func _describe_before(doc, op: Dictionary) -> Dictionary:
	var id := String(op.get("id", ""))
	var out := {"name": doc.name_of(id) if doc.nodes.has(id) else String(op.get("n", "?"))}
	if String(op.get("k", "")) == "set" and doc.nodes.has(id):
		var old := {}
		var props = op.get("props", {})
		if props is Dictionary:
			for k in props:
				old[k] = doc.nodes[id].props.get(k)
		out["old"] = old
	return out


func _activity_for_ops(pid: int, doc, items: Array) -> void:
	var scene: String = String(doc.path).get_file()
	for it in items:
		var before: Dictionary = it[0]
		var op: Dictionary = it[1]
		var id := String(op.get("id", ""))
		var link := {"type": "node", "path": doc.path, "id": id}
		match String(op.get("k", "")):
			"add":
				var what := String(op.get("inst", "")).get_file() if not String(op.get("inst", "")).is_empty() else String(op.get("c", "Node"))
				activity_fn.call(pid, "added %s (%s) in %s" % [op.get("n", "?"), what, scene], link, "")
			"del":
				activity_fn.call(pid, "deleted %s in %s" % [before.name, scene], {"type": "scene", "path": doc.path}, "")
			"move":
				activity_fn.call(pid, "moved %s in %s" % [before.name, scene], link, "move:" + id)
			"name":
				activity_fn.call(pid, "renamed %s → %s" % [before.name, op.get("n", "?")], link, "name:" + id)
			"set":
				var props: Dictionary = op.get("props", {})
				var names := props.keys()
				if names.size() == 1:
					var k: String = names[0]
					var old = before.get("old", {}).get(k)
					activity_fn.call(pid, "changed %s.%s %s → %s" % [before.name, k.get_file(), Wire.describe(old), Wire.describe(props[k])], link, "set:%s:%s" % [id, k])
				elif names.size() > 1:
					activity_fn.call(pid, "changed %d properties on %s" % [names.size(), before.name], link, "set:%s:*" % id)
				for k in op.get("reset", []):
					activity_fn.call(pid, "reset %s.%s" % [before.name, String(k).get_file()], link, "reset:%s:%s" % [id, k])
			"groups":
				activity_fn.call(pid, "edited groups of %s" % before.name, link, "groups:" + id)
			"conns":
				activity_fn.call(pid, "edited signal connections of %s" % before.name, link, "conns:" + id)


# --- scripts ---------------------------------------------------------------------------------------

func _tx_open(pid: int, msg: Dictionary) -> void:
	var path: String = msg.path
	var doc = texts.get(path)
	if doc == null:
		var abs := project_dir.path_join(Util.res_to_rel(path))
		var exists := FileAccess.file_exists(abs)
		doc = TextDoc.new(path, FileAccess.get_file_as_string(abs) if exists else "")
		doc.missing = not exists
		texts[path] = doc
	doc.orphaned_ms = 0
	doc.watchers[pid] = true
	# "missing": the host doesn't have this file yet (it was just created on the opener's side and
	# is still on its way), so the opener's text should become the document.
	var reply := {"t": "tx_state", "path": path, "epoch": doc.epoch, "rev": doc.rev, "text": doc.text, "since": null,
		"missing": doc.missing and doc.rev == 0}
	if String(msg.get("epoch", "")) == doc.epoch and msg.has("rev"):
		reply["since"] = doc.ops_since(int(msg.rev))
		reply["from_rev"] = int(msg.rev)
	_send(pid, reply)


func _tx_close(pid: int, path: String, keep := false) -> void:
	var doc = texts.get(path)
	if doc == null:
		return
	doc.watchers.erase(pid)
	_to_watchers(doc.watchers, {"t": "tx_cursor", "path": path, "by": pid, "sel": []})
	if doc.watchers.is_empty():
		if keep:
			doc.orphaned_ms = Util.now_ms()
		else:
			texts.erase(path)


func _tx_op(pid: int, msg: Dictionary) -> void:
	var path: String = msg.path
	var doc = texts.get(path)
	if doc == null or not doc.watchers.has(pid) or String(msg.get("epoch", "")) != doc.epoch:
		_send(pid, {"t": "tx_reject", "path": path, "reason": "stale"})
		return
	if not can_write_fn.call(pid, Util.res_to_rel(path)):
		_send(pid, {"t": "tx_reject", "path": path, "reason": "read_only"})
		return
	var uuid := String(uuid_fn.call(pid))
	var cseq := int(msg.get("cseq", 0))
	var cid := String(msg.get("cid", ""))
	if doc.is_duplicate(uuid, cseq, cid):
		return
	var op := OT.from_array(msg.get("op"))
	if op == null:
		return
	var applied = doc.receive(int(msg.get("rev", -1)), op, uuid, cseq, cid)
	if applied == null:
		_send(pid, {"t": "tx_reject", "path": path, "reason": "conflict"})
		return
	_to_watchers(doc.watchers, {"t": "tx_op", "path": path, "rev": doc.rev, "op": applied.to_array(), "by": pid, "uuid": uuid, "cseq": cseq, "cid": cid})
	activity_fn.call(pid, "is editing %s" % path.get_file(), {"type": "script", "path": path}, "tx:" + path)


## A new version of a script file arrived or was saved. `live` means it came from an editor that
## has the document open: that editor's edits already reach the document as live operations (some
## may still be on their way), so the file adds nothing and must not be merged in again. Anything
## else (an external editor, a save from someone without the file open) is merged three-way
## against the last version seen on disk, so live edits made since aren't lost.
## `text` is the new contents (read from disk when null).
func on_file_changed(rel: String, by: int, live := false, text = null) -> void:
	var path := Util.rel_to_res(rel)
	var doc = texts.get(path)
	if doc == null:
		return
	var disk: String
	if text is String:
		disk = text
	else:
		var abs := project_dir.path_join(rel)
		if not FileAccess.file_exists(abs):
			return
		disk = FileAccess.get_file_as_string(abs)
	disk = disk.replace("\r\n", "\n")
	var base: String = doc.disk_text
	doc.disk_text = disk
	if live or disk == base or disk == doc.text:
		return
	var merged := OT.merge3(base, doc.text, disk)
	if merged == doc.text:
		return
	_file_cseq += 1
	var applied = doc.receive(doc.rev, OT.diff(doc.text, merged), "file", _file_cseq, "file")
	if applied != null:
		_to_watchers(doc.watchers, {"t": "tx_op", "path": path, "rev": doc.rev, "op": applied.to_array(), "by": by, "uuid": "file", "cseq": _file_cseq, "cid": "file"})
