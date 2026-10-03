@tool
extends RefCounted
## Host-side model of a scene that someone has open. It holds plain data only (no Nodes), so the
## host can referee edits to scenes it doesn't have open itself.
##
## Node record: {"id", "p" (parent id, "" for root), "n" (name), "c" (class), "inst" (scene path
## for instanced scenes), "props" {name: wire}, "groups" [..], "conns" [[src_id, signal, method, flags, binds]]}
##
## Ops: add / del / move / name / set / groups / conns. The host applies them in arrival order;
## every peer applies the same ordered stream, so all copies converge.

var path := ""
var epoch := ""
var rev := 0
var nodes := {}          # id -> record (without "si")
var children := {}       # id -> Array[String] child ids in order
var root_id := ""
var watchers := {}       # peer id -> true
var creator := 0         # peer asked to upload the first snapshot (0 = none pending)
var waiting: Array = []  # peers waiting for the doc to exist
var lock_holder := 0     # peer id holding the edit lock (0 = unlocked)


func _init(p_path := "") -> void:
	path = p_path
	epoch = str(randi()) + str(Time.get_ticks_usec())


static func _clean_record(r: Dictionary) -> Dictionary:
	var props = r.get("props", {})
	var groups = r.get("groups", [])
	var conns = r.get("conns", [])
	return {
		"id": String(r.get("id", "")),
		"p": String(r.get("p", "")),
		"n": String(r.get("n", "Node")).validate_node_name(),
		"c": String(r.get("c", "Node")),
		"inst": String(r.get("inst", "")),
		"props": props if props is Dictionary else {},
		"groups": groups if groups is Array else [],
		"conns": conns if conns is Array else [],
	}


## Loads a parent-first snapshot list. Returns false if it is malformed.
func load_snapshot(list) -> bool:
	if not (list is Array) or list.is_empty():
		return false
	var new_nodes := {}
	var new_children := {}
	var new_root := ""
	for r in list:
		if not (r is Dictionary):
			return false
		var rec := _clean_record(r)
		if rec.id.is_empty() or new_nodes.has(rec.id):
			return false
		if rec.p.is_empty():
			if not new_root.is_empty():
				return false
			new_root = rec.id
		elif not new_nodes.has(rec.p):
			return false
		new_nodes[rec.id] = rec
		new_children[rec.id] = []
		if not rec.p.is_empty():
			new_children[rec.p].append(rec.id)
	if new_root.is_empty():
		return false
	nodes = new_nodes
	children = new_children
	root_id = new_root
	return true


## Parent-first list of records, each with "si" (index among synced siblings).
func snapshot() -> Array:
	var out := []
	if root_id.is_empty():
		return out
	var stack: Array = [[root_id, 0]]
	while not stack.is_empty():
		var e: Array = stack.pop_back()
		var rec: Dictionary = nodes[e[0]].duplicate()
		rec["si"] = e[1]
		out.append(rec)
		var kids: Array = children[e[0]]
		for i in range(kids.size() - 1, -1, -1):
			stack.append([kids[i], i])
	return out


func path_of(id: String) -> String:
	if id == root_id:
		return "."
	var parts := PackedStringArray()
	var cur := id
	var guard := 0
	while cur != root_id and nodes.has(cur) and guard < 4096:
		parts.append(String(nodes[cur].n))
		cur = String(nodes[cur].p)
		guard += 1
	parts.reverse()
	return "/".join(parts)


func name_of(id: String) -> String:
	return String(nodes[id].n) if nodes.has(id) else "?"


func _unique_name(parent: String, wanted: String, exclude := "") -> String:
	var taken := {}
	for cid in children.get(parent, []):
		if cid != exclude:
			taken[String(nodes[cid].n)] = true
	if not taken.has(wanted):
		return wanted
	var stem := wanted
	while stem.length() > 0 and stem[-1].is_valid_int():
		stem = stem.substr(0, stem.length() - 1)
	if stem.is_empty():
		stem = "Node"
	var n := 2
	while taken.has(stem + str(n)):
		n += 1
	return stem + str(n)


func _is_in_subtree(id: String, maybe_descendant: String) -> bool:
	var cur := maybe_descendant
	var guard := 0
	while not cur.is_empty() and guard < 4096:
		if cur == id:
			return true
		cur = String(nodes[cur].p) if nodes.has(cur) else ""
		guard += 1
	return false


func _insert_child(parent: String, id: String, si: int) -> void:
	var kids: Array = children[parent]
	kids.insert(clampi(si, 0, kids.size()), id)


func _remove_subtree(id: String) -> void:
	for cid in children.get(id, []).duplicate():
		_remove_subtree(cid)
	children.erase(id)
	nodes.erase(id)


## Applies one op. Returns the op as applied (the host may have renamed a node to keep sibling
## names unique - "fixed" is then set) or null when the op is invalid against the current doc.
func apply(op: Dictionary):
	var kind := String(op.get("k", ""))
	var id := String(op.get("id", ""))
	match kind:
		"add":
			var p := String(op.get("p", ""))
			if id.is_empty() or nodes.has(id) or not nodes.has(p):
				return null
			var rec := _clean_record(op)
			var name := _unique_name(p, rec.n)
			var out := op.duplicate()
			if name != rec.n:
				out["n"] = name
				out["fixed"] = true
			rec.n = name
			nodes[id] = rec
			children[id] = []
			_insert_child(p, id, int(op.get("si", 1 << 30)))
			return out
		"del":
			if not nodes.has(id) or id == root_id:
				return null
			var parent := String(nodes[id].p)
			children[parent].erase(id)
			_remove_subtree(id)
			return op
		"move":
			var p := String(op.get("p", ""))
			if not nodes.has(id) or id == root_id or not nodes.has(p) or _is_in_subtree(id, p):
				return null
			var rec: Dictionary = nodes[id]
			children[String(rec.p)].erase(id)
			var out := op.duplicate()
			var name := _unique_name(p, String(rec.n), id)
			if name != rec.n:
				rec.n = name
				out["n"] = name
				out["fixed"] = true
			rec.p = p
			_insert_child(p, id, int(op.get("si", 1 << 30)))
			return out
		"name":
			if not nodes.has(id):
				return null
			var rec: Dictionary = nodes[id]
			var wanted := String(op.get("n", rec.n)).validate_node_name()
			if wanted.is_empty():
				return null
			var name := wanted if id == root_id else _unique_name(String(rec.p), wanted, id)
			rec.n = name
			var out := op.duplicate()
			if name != String(op.get("n", "")):
				out["n"] = name
				out["fixed"] = true
			return out
		"set":
			if not nodes.has(id):
				return null
			var props = op.get("props", {})
			var reset = op.get("reset", [])
			if not (props is Dictionary) or not (reset is Array):
				return null
			var rp: Dictionary = nodes[id].props
			for k in props:
				rp[k] = props[k]
			for k in reset:
				rp.erase(k)
			return op
		"groups":
			if not nodes.has(id) or not (op.get("groups") is Array):
				return null
			nodes[id].groups = op.groups
			return op
		"conns":
			if not nodes.has(id) or not (op.get("conns") is Array):
				return null
			nodes[id].conns = op.conns
			return op
	return null
