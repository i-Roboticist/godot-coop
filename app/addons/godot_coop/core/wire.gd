@tool
extends RefCounted
## Converts property values to a pure-data "wire" form (safe for var_to_bytes, comparable with ==)
## and back. Objects become tagged dictionaries:
##   {"$ext": "res://path"}                           external resource
##   {"$sub": rid, "cls": "BoxShape3D", "p": {...}}   resource embedded in the scene
##   {"$node": id}                                    reference to a synced node
##   {"$arr": [...], "tb", "tc", "ts"}                typed array
##   {"$dict": [k, v, ...], "kt": [...], "vt": [...]} dictionary
## Remote embedded resources are matched to local objects by id, or adopted in place, so editing
## a shape's size updates the existing shape instead of replacing it.

const Util := preload("res://addons/godot_coop/core/util.gd")
const MAX_DEPTH := 12
const SKIP_RES_PROPS := ["resource_path", "resource_scene_unique_id"]

var node_to_id: Callable          # func(Node) -> String
var id_to_node: Callable          # func(String) -> Node
var missing_resource := false     # set when from_wire hit a res:// file that doesn't exist (yet)
var unresolved_node := false      # set when from_wire hit a node id that doesn't exist (yet)
var allow_code := false           # accept embedded scripts that would run in the editor (@tool)
var blocked_code := false         # set when from_wire skipped one of those

var _res_by_rid := {}
var _rid_by_obj := {}
var _shared_rids := {}            # ids that came from the wire (known to peers), vs made up locally


func rid_for(res: Resource) -> String:
	var iid := res.get_instance_id()
	if _rid_by_obj.has(iid):
		return _rid_by_obj[iid]
	var rid := Util.random_hex(6)
	_rid_by_obj[iid] = rid
	_res_by_rid[rid] = res
	return rid


func _register(rid: String, res: Resource, take_over := false) -> void:
	_res_by_rid[rid] = res
	_shared_rids[rid] = true
	if take_over or not _rid_by_obj.has(res.get_instance_id()):
		_rid_by_obj[res.get_instance_id()] = rid


## Equal values, treating embedded resources as equal when only their ids differ (each editor
## makes up its own ids for resources it hasn't exchanged yet).
static func same_value(a, b) -> bool:
	if typeof(a) != typeof(b):
		return false
	if a is Dictionary:
		if a.has("$sub") and b.has("$sub"):
			return String(a.get("cls", "")) == String(b.get("cls", "")) and same_value(a.get("p", {}), b.get("p", {}))
		if a.size() != b.size():
			return false
		for k in a:
			if not b.has(k) or not same_value(a[k], b[k]):
				return false
		return true
	if a is Array:
		if a.size() != b.size():
			return false
		for i in a.size():
			if not same_value(a[i], b[i]):
				return false
		return true
	return a == b


static func is_external(res: Resource) -> bool:
	var p := res.resource_path
	return not p.is_empty() and p.find("::") == -1


func to_wire(v, depth := 0):
	match typeof(v):
		TYPE_OBJECT:
			if v == null or not is_instance_valid(v):
				return null
			if v is Resource:
				return _res_to_wire(v, depth)
			if v is Node:
				return {"$node": node_to_id.call(v) if node_to_id.is_valid() else ""}
			return null
		TYPE_ARRAY:
			var arr: Array = v
			var out := []
			if depth < MAX_DEPTH:
				for e in arr:
					out.append(to_wire(e, depth + 1))
			if arr.is_typed():
				var sc = arr.get_typed_script()
				return {"$arr": out, "tb": arr.get_typed_builtin(), "tc": String(arr.get_typed_class_name()), "ts": sc.resource_path if sc is Script else ""}
			return out
		TYPE_DICTIONARY:
			var d: Dictionary = v
			var kv := []
			if depth < MAX_DEPTH:
				for k in d:
					kv.append(to_wire(k, depth + 1))
					kv.append(to_wire(d[k], depth + 1))
			var w := {"$dict": kv}
			if d.is_typed():
				var ks = d.get_typed_key_script()
				var vs = d.get_typed_value_script()
				w["kt"] = [d.get_typed_key_builtin(), String(d.get_typed_key_class_name()), ks.resource_path if ks is Script else ""]
				w["vt"] = [d.get_typed_value_builtin(), String(d.get_typed_value_class_name()), vs.resource_path if vs is Script else ""]
			return w
		TYPE_CALLABLE, TYPE_SIGNAL, TYPE_RID:
			return null
		_:
			return v


func _res_to_wire(res: Resource, depth: int):
	if is_external(res):
		return {"$ext": res.resource_path}
	if depth > MAX_DEPTH:
		return null
	var props := {}
	for p in res.get_property_list():
		if not (p.usage & PROPERTY_USAGE_STORAGE):
			continue
		var n: String = p.name
		if n in SKIP_RES_PROPS:
			continue
		props[n] = to_wire(res.get(n), depth + 1)
	return {"$sub": rid_for(res), "cls": res.get_class(), "p": props}


## `current` is the value presently in the slot; embedded resources of the same class are updated
## in place instead of being replaced.
func from_wire(w, current = null):
	match typeof(w):
		TYPE_DICTIONARY:
			if w.has("$ext"):
				return _load_ext(String(w["$ext"]))
			if w.has("$sub"):
				return _sub_from_wire(w, current)
			if w.has("$node"):
				var n = id_to_node.call(String(w["$node"])) if id_to_node.is_valid() else null
				if n == null and not String(w["$node"]).is_empty():
					unresolved_node = true
				return n
			if w.has("$arr"):
				var items := []
				for e in w["$arr"]:
					items.append(from_wire(e))
				var ts = _load_ext(String(w.get("ts", ""))) if not String(w.get("ts", "")).is_empty() else null
				var typed := Array(items, int(w.get("tb", 0)), StringName(w.get("tc", "")), ts)
				return typed
			if w.has("$dict"):
				var kv: Array = w["$dict"]
				var d := {}
				var i := 0
				while i + 1 < kv.size():
					d[from_wire(kv[i])] = from_wire(kv[i + 1])
					i += 2
				if w.has("kt") and w.has("vt"):
					var kt: Array = w["kt"]
					var vt: Array = w["vt"]
					var kscript = _load_ext(String(kt[2])) if not String(kt[2]).is_empty() else null
					var vscript = _load_ext(String(vt[2])) if not String(vt[2]).is_empty() else null
					return Dictionary(d, int(kt[0]), StringName(kt[1]), kscript, int(vt[0]), StringName(vt[1]), vscript)
				return d
			return null
		TYPE_ARRAY:
			var out := []
			for e in w:
				out.append(from_wire(e))
			return out
		_:
			return w


func _load_ext(path: String):
	if not Util.is_safe_res_path(path):
		return null
	if ResourceLoader.exists(path):
		var r = ResourceLoader.load(path)
		if r != null:
			return r
	missing_resource = true
	return null


func _sub_from_wire(w: Dictionary, current):
	var rid := String(w.get("$sub", ""))
	var cls := String(w.get("cls", ""))
	# A built-in @tool script would run in this editor the moment it's attached: same rule as for
	# files, it needs the sender to be trusted.
	if not allow_code and ClassDB.is_parent_class(cls, "Script") and w.get("p") is Dictionary:
		var src = w.p.get("script/source", w.p.get("source_code", ""))
		if src is String and (src.contains("@tool") or src.contains("[Tool]")):
			blocked_code = true
			return null
	var res: Resource = _res_by_rid.get(rid)
	if res != null and res.get_class() != cls:
		res = null
	# Adopt the object already in the slot (the first sync of an existing scene), unless peers
	# already know it under another id: then other slots share it and this one was made unique.
	if res == null and current is Resource and current.get_class() == cls and not is_external(current):
		var known = _rid_by_obj.get(current.get_instance_id())
		if known == null or known == rid or not _shared_rids.has(known):
			res = current
			_register(rid, res, true)
	if res == null:
		if not ClassDB.class_exists(cls) or not ClassDB.can_instantiate(cls) or not ClassDB.is_parent_class(cls, "Resource"):
			return null
		res = ClassDB.instantiate(cls)
		if res == null:
			return null
		_register(rid, res)
	var props = w.get("p", {})
	if not (props is Dictionary):
		return res
	if props.has("script"):
		var s = from_wire(props["script"])
		if res.get_script() != s:
			res.set_script(s)
	if res is Animation:
		# Tracks are indexed properties ("tracks/3/path"): rebuild them, or tracks deleted or
		# reordered by the sender would linger here.
		res.clear()
	for k in props:
		if k == "script":
			continue
		var cur = res.get(k)
		var nv = from_wire(props[k], cur)
		if typeof(nv) != typeof(cur) or nv != cur:
			res.set(k, nv)
	if res is Script and (props.has("script/source") or props.has("source_code")):
		res.reload()
	return res


## Short human-readable rendering for the activity feed.
static func describe(w) -> String:
	match typeof(w):
		TYPE_NIL:
			return "default"
		TYPE_DICTIONARY:
			if w.has("$ext"):
				return String(w["$ext"]).get_file()
			if w.has("$sub"):
				return "new " + String(w.get("cls", "Resource"))
			if w.has("$node"):
				return "node"
			if w.has("$arr"):
				return "[%d items]" % w["$arr"].size()
			if w.has("$dict"):
				return "{%d entries}" % (w["$dict"].size() / 2)
			return "?"
		TYPE_ARRAY:
			return "[%d items]" % w.size()
		TYPE_FLOAT:
			return str(snappedf(w, 0.001))
		TYPE_VECTOR2:
			return "(%.1f, %.1f)" % [w.x, w.y]
		TYPE_VECTOR3:
			return "(%.2f, %.2f, %.2f)" % [w.x, w.y, w.z]
		TYPE_STRING:
			return "\"%s\"" % Util.short_text(w, 30)
		TYPE_TRANSFORM2D, TYPE_TRANSFORM3D, TYPE_BASIS:
			return "(transform)"
	return Util.short_text(str(w), 40)
