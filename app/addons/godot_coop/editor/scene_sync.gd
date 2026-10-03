@tool
extends RefCounted
## Live scene editing.
##
## For every open scene we keep a Tracker that gives each node a stable id and remembers the last
## synced state ("cache"). Local edits are found by diffing the live tree against the cache
## (triggered by undo/redo activity, tree signals, a fast poll of the selection for live gizmo
## drags, and a slow rolling scan), and sent to the host as small ops. Ops from teammates are
## applied straight to the nodes - outside your undo history, so Ctrl+Z only undoes your own work.
## Anything surprising (a rejected op, reconnect, reload) ends in a full reconcile against the
## host's copy, which makes the tree match exactly.

const Util := preload("res://addons/godot_coop/core/util.gd")
const Wire := preload("res://addons/godot_coop/core/wire.gd")
const Net := preload("res://addons/godot_coop/core/net.gd")

const SKIP_PROPS := ["name", "owner", "scene_file_path", "_import_path", "multiplayer", "unique_name_in_owner_"]
const SELECTION_POLL_MS := 80
const ROLLING_PER_FRAME := 30
const FULL_DIFF_LIMIT := 400
## A property that keeps changing on its own (a @tool script animating it, an animation preview)
## stops being sent after this many changes in a row, until it settles.
const CHURN_LIMIT := 6
const CHURN_GAP_MS := 400
const CHURN_QUIET_MS := 1500


class Tracker:
	extends RefCounted
	var path := ""
	var root: Node = null
	var root_iid := 0
	var ids := {}            # instance id -> node id
	var nodes := {}          # node id -> instance id
	var cache := {}          # node id -> record {p, n, c, inst, props, groups, conns}
	var order := {}          # parent node id -> [child ids] (last synced order)
	var ready := false
	var epoch := ""
	var rev := 0
	var pending := {}        # "id/key" -> count of unacknowledged local changes
	var batches := {}        # cseq -> {"keys": [], "ops": [], "reapply": bool}
	var cseq := 0
	var wire: Wire = null
	var graveyard: Array = []
	var failed: Array = []   # [id, prop, wire] that couldn't be applied yet (missing resource)
	var lock_holder := 0
	var live := false        # the host knows we have this scene open (sc_state received)
	var resend_after_state := false   # reconnected: batches the host never got are sent again
	var unsaved_pending := false      # teammates changed it: mark the scene unsaved when shown
	var missing_files := false        # a node's scene file hadn't arrived yet: fetch again later
	var warned_code := false
	var rolling := 0
	var warned_readonly := 0


var plugin                     # the EditorPlugin
var trackers := {}             # res path -> Tracker
var applying := false
var _capture_due := false
var _structure_due := false
var _last_sel_poll := 0
var _last_refresh := 0
var _class_defaults := {}
var _script_props := {}        # script instance id -> {name: true}
var _instance_base := {}       # scene path -> {"props": {}, "groups": []}
var _signals_connected := false
var _churn := {}               # "id/prop" -> {"v": last value seen, "last": ms, "n": changes in a row}
## Batch numbers for every scene come from here and never restart (not even with the editor), so
## the host's "last batch I got from you" can't be mistaken for a newer batch after a reload.
var _next_cseq := int(Time.get_unix_time_from_system() * 1000.0)


func _session():
	return plugin.session


func _online() -> bool:
	return plugin.session != null and plugin.session.is_online()


func setup(p) -> void:
	plugin = p
	var ur := EditorInterface.get_editor_undo_redo()
	ur.version_changed.connect(_on_undo_version)
	ur.history_changed.connect(_on_undo_version)
	plugin.get_tree().node_added.connect(_on_tree_node_added)
	plugin.get_tree().node_removed.connect(_on_tree_node_removed)
	plugin.get_tree().node_renamed.connect(_on_tree_node_renamed)
	_signals_connected = true


func teardown() -> void:
	if _signals_connected:
		var ur := EditorInterface.get_editor_undo_redo()
		if ur.version_changed.is_connected(_on_undo_version):
			ur.version_changed.disconnect(_on_undo_version)
			ur.history_changed.disconnect(_on_undo_version)
		var tree: SceneTree = plugin.get_tree()
		if tree.node_added.is_connected(_on_tree_node_added):
			tree.node_added.disconnect(_on_tree_node_added)
			tree.node_removed.disconnect(_on_tree_node_removed)
			tree.node_renamed.disconnect(_on_tree_node_renamed)
		_signals_connected = false
	for path in trackers:
		_free_graveyard(trackers[path], true)
	trackers.clear()


func session_started() -> void:
	trackers.clear()
	_refresh_open_scenes(true)


## Connection lost: keep capturing edits, but hold them until the host has us back.
func session_lost() -> void:
	for path in trackers:
		trackers[path].live = false
		trackers[path].resend_after_state = true


## The connection came back: re-open every scene. The host's state says which of our batches it
## processed; the rest are sent again and re-applied once acknowledged (see "sc_state").
func session_resumed() -> void:
	for path in trackers:
		trackers[path].live = false
		_send({"t": "sc_open", "path": path})


func _send(msg: Dictionary) -> void:
	_session().send(msg, Net.CH_LIVE)


# --- bookkeeping -------------------------------------------------------------------------------------

func _on_undo_version() -> void:
	if not applying:
		_capture_due = true


func _in_edited_scene(node: Node) -> bool:
	var root := EditorInterface.get_edited_scene_root()
	return root != null and (node == root or root.is_ancestor_of(node))


func _on_tree_node_added(node: Node) -> void:
	if not applying and _in_edited_scene(node):
		_structure_due = true


func _on_tree_node_removed(node: Node) -> void:
	if not applying and _in_edited_scene(node):
		_structure_due = true


func _on_tree_node_renamed(node: Node) -> void:
	if not applying and _in_edited_scene(node):
		_structure_due = true


func current_tracker() -> Tracker:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return null
	var tr: Tracker = trackers.get(root.scene_file_path)
	if tr != null and tr.root == root:
		return tr
	return null


func is_scene_open(path: String) -> bool:
	return trackers.has(path) or EditorInterface.get_open_scenes().has(path)


func _new_tracker(path: String, root: Node) -> Tracker:
	var tr := Tracker.new()
	tr.path = path
	tr.root = root
	tr.root_iid = root.get_instance_id()
	tr.wire = Wire.new()
	tr.wire.node_to_id = func(n: Node): return String(tr.ids.get(n.get_instance_id(), ""))
	tr.wire.id_to_node = func(id: String): return _node_by_id(tr, id)
	return tr


func _free_graveyard(tr: Tracker, now := false) -> void:
	for n in tr.graveyard:
		if is_instance_valid(n) and n.get_parent() == null:
			if now:
				n.free()
			else:
				n.queue_free()
	tr.graveyard.clear()


## Keeps trackers in line with the editor's open scene tabs (opens, closes, reloads, save-as).
func _refresh_open_scenes(force := false) -> void:
	var now := Util.now_ms()
	if not force and now - _last_refresh < 400:
		return
	_last_refresh = now
	var open := {}
	for root in EditorInterface.get_open_scene_roots():
		if root == null or not is_instance_valid(root):
			continue
		var path: String = root.scene_file_path
		if path.is_empty() or not path.begins_with("res://"):
			continue
		open[path] = root
	for path in trackers.keys():
		if not open.has(path):
			_close_tracker(path)
	for path in open:
		var root: Node = open[path]
		var tr: Tracker = trackers.get(path)
		if tr == null:
			tr = _new_tracker(path, root)
			trackers[path] = tr
			if _online():
				_send({"t": "sc_open", "path": path})
		elif tr.root_iid != root.get_instance_id() or not is_instance_valid(tr.root):
			# The scene was reloaded from disk (e.g. a scene it instances changed). Start over with
			# the new root and reconcile against the live document, without closing it: closing
			# would drop the document if we were its only editor, losing unsaved live edits.
			_free_graveyard(tr)
			var fresh := _new_tracker(path, root)
			fresh.lock_holder = tr.lock_holder
			trackers[path] = fresh
			if _online():
				_send({"t": "sc_open", "path": path})


func _close_tracker(path: String) -> void:
	var tr: Tracker = trackers.get(path)
	trackers.erase(path)
	if tr != null:
		_free_graveyard(tr)
	if _online():
		_send({"t": "sc_close", "path": path})
	if _session() != null and _session().files != null:
		_session().files.flush_deferred(Util.res_to_rel(path))


## A scene tab closed. Godot also says this when it reloads a scene (which reopens it at once), so
## the next check of the open tabs decides: still gone means closed, open again means reloaded.
func on_scene_closed(path: String) -> void:
	if trackers.has(path):
		_last_refresh = 0


# --- node ids ------------------------------------------------------------------------------------------

func _node_by_id(tr: Tracker, id: String) -> Node:
	if not tr.nodes.has(id):
		return null
	var obj = instance_from_id(tr.nodes[id])
	if obj == null or not is_instance_valid(obj) or not (obj is Node):
		return null
	return obj


func _register(tr: Tracker, node: Node, id: String) -> void:
	var old = tr.nodes.get(id)
	if old != null and tr.ids.get(old) == id:
		tr.ids.erase(old)
	tr.ids[node.get_instance_id()] = id
	tr.nodes[id] = node.get_instance_id()


func id_of(tr: Tracker, node: Node, create := true) -> String:
	var iid := node.get_instance_id()
	if tr.ids.has(iid):
		return tr.ids[iid]
	if not create:
		return ""
	var id := Util.random_hex(6)
	_register(tr, node, id)
	return id


## Root + every node saved in this scene, parents before children, siblings in order.
func _synced_nodes(tr: Tracker) -> Array:
	var out := []
	if tr.root == null or not is_instance_valid(tr.root):
		return out
	var stack: Array = [tr.root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		out.append(n)
		var kids := n.get_children()
		# Nodes owned by an instanced sub-scene belong to that scene's file, not this one.
		for i in range(kids.size() - 1, -1, -1):
			var c: Node = kids[i]
			if c.owner == tr.root:
				stack.append(c)
	return out


func node_ids(tr: Tracker, nodes: Array) -> Array:
	var out := []
	for n in nodes:
		if n is Node and tr.ids.has(n.get_instance_id()):
			out.append(tr.ids[n.get_instance_id()])
	return out


func nodes_for_ids(tr: Tracker, ids: Array) -> Array:
	var out := []
	for id in ids:
		var n := _node_by_id(tr, String(id))
		if n != null:
			out.append(n)
	return out


# --- capturing the state of a node -----------------------------------------------------------------------

func _class_default(cls: String, prop: String):
	var d: Dictionary = _class_defaults.get(cls, {})
	if d.is_empty():
		_class_defaults[cls] = d
	if not d.has(prop):
		d[prop] = ClassDB.class_get_property_default_value(cls, prop)
	return d[prop]


func _script_prop_set(script: Script) -> Dictionary:
	var key := script.get_instance_id()
	if _script_props.has(key):
		return _script_props[key]
	var s := {}
	for p in script.get_script_property_list():
		s[p.name] = true
	_script_props[key] = s
	return s


func _instance_info(path: String) -> Dictionary:
	if _instance_base.has(path):
		return _instance_base[path]
	var info := {"props": {}, "groups": []}
	if ResourceLoader.exists(path):
		# Read from disk, not the cache: after a teammate's save the cache can still hold the old one.
		var ps = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
		if ps is PackedScene:
			var st: SceneState = ps.get_state()
			if st.get_node_count() > 0:
				for i in st.get_node_property_count(0):
					info.props[String(st.get_node_property_name(0, i))] = st.get_node_property_value(0, i)
				for g in st.get_node_groups(0):
					info.groups.append(String(g))
	_instance_base[path] = info
	return info


func invalidate_instance_cache(path := "") -> void:
	if path.is_empty():
		_instance_base.clear()
	else:
		_instance_base.erase(path)
	_script_props.clear()
	if path.is_empty():
		return
	# Instances of that scene still show its old version until they're refreshed. Measured against
	# the new version, their old values would look like local overrides and be sent to everyone,
	# undoing the teammate's change: take them as the new starting point instead.
	for p in trackers:
		var tr: Tracker = trackers[p]
		if not is_instance_valid(tr.root):
			continue
		for n in _synced_nodes(tr):
			if n != tr.root and n.scene_file_path == path:
				var id := String(tr.ids.get(n.get_instance_id(), ""))
				if tr.cache.has(id):
					tr.cache[id].props = _props_of(tr, n)


func _is_instance(tr: Tracker, node: Node) -> bool:
	return node != tr.root and not node.scene_file_path.is_empty()


## What a property would be if nobody had touched it (instanced scene's value, script default, class default).
func _base_value(tr: Tracker, node: Node, prop: String):
	if _is_instance(tr, node):
		var info := _instance_info(node.scene_file_path)
		if info.props.has(prop):
			return info.props[prop]
	var scr = node.get_script()
	if scr is Script and _script_prop_set(scr).has(prop):
		return scr.get_property_default_value(prop)
	return _class_default(node.get_class(), prop)


func _props_of(tr: Tracker, node: Node) -> Dictionary:
	var out := {}
	for p in node.get_property_list():
		if not (p.usage & PROPERTY_USAGE_STORAGE):
			continue
		var name: String = p.name
		if name in SKIP_PROPS:
			continue
		var v = node.get(name)
		if name == "script":
			if v != null:
				out[name] = tr.wire.to_wire(v)
			continue
		var base = _base_value(tr, node, name)
		if Util.same(v, base):
			continue
		out[name] = tr.wire.to_wire(v)
	return out


func _groups_of(tr: Tracker, node: Node) -> Array:
	var out := []
	var base: Array = _instance_info(node.scene_file_path).groups if _is_instance(tr, node) else []
	for g in node.get_groups():
		var s := String(g)
		if s.begins_with("_") or base.has(s):
			continue
		out.append(s)
	out.sort()
	return out


func _conns_of(tr: Tracker, node: Node) -> Array:
	var out := []
	for c in node.get_incoming_connections():
		var flags := int(c.flags)
		if not (flags & CONNECT_PERSIST):
			continue
		var sig: Signal = c.signal
		var src = sig.get_object()
		if not (src is Node) or not tr.ids.has(src.get_instance_id()):
			continue
		var cb: Callable = c.callable
		if cb.get_object() != node:
			continue
		out.append([tr.ids[src.get_instance_id()], String(sig.get_name()), String(cb.get_method()), flags & (CONNECT_DEFERRED | CONNECT_ONE_SHOT | CONNECT_APPEND_SOURCE_OBJECT), tr.wire.to_wire(cb.get_bound_arguments()), cb.get_unbound_arguments_count()])
	out.sort_custom(func(a, b): return str(a) < str(b))
	return out


func _record(tr: Tracker, node: Node, parent_id: String) -> Dictionary:
	return {
		"p": parent_id, "n": String(node.name), "c": node.get_class(),
		"inst": node.scene_file_path if _is_instance(tr, node) else "",
		"props": _props_of(tr, node), "groups": _groups_of(tr, node), "conns": _conns_of(tr, node),
	}


## Full snapshot for the host (parent-first, with sibling indices).
func _snapshot(tr: Tracker) -> Array:
	var list := []
	tr.cache.clear()
	tr.order.clear()
	var nodes := _synced_nodes(tr)
	for n in nodes:
		id_of(tr, n)
	var counters := {}
	for n in nodes:
		var id := id_of(tr, n)
		var pid := "" if n == tr.root else id_of(tr, n.get_parent())
		var si: int = counters.get(pid, 0)
		counters[pid] = si + 1
		var rec := _record(tr, n, pid)
		tr.cache[id] = rec.duplicate()
		if not tr.order.has(pid):
			tr.order[pid] = []
		tr.order[pid].append(id)
		var out := rec.duplicate()
		out["id"] = id
		out["si"] = si
		list.append(out)
	return list


# --- local change detection ------------------------------------------------------------------------------

func process() -> void:
	# Edits are still captured while reconnecting; they're sent once the host has us back.
	if _session() == null or not (_session().state in ["hosting", "connected", "reconnecting"]):
		return
	_refresh_open_scenes()
	var tr := current_tracker()
	if tr != null and tr.unsaved_pending:
		# Teammates changed this scene: it no longer matches the file, so closing it asks to save.
		tr.unsaved_pending = false
		EditorInterface.mark_scene_as_unsaved()
	if tr == null or not tr.ready or applying:
		return
	var now := Util.now_ms()
	var ops := []
	# Changes seen without any editor action or mouse drag may come from a @tool script or an
	# animation preview; those are throttled if they never settle (see _volatile).
	var dragging := Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	if _structure_due or _capture_due:
		var full := _capture_due and tr.cache.size() <= FULL_DIFF_LIMIT
		ops.append_array(_diff_structure(tr))
		var targets := {}
		for n in EditorInterface.get_selection().get_selected_nodes():
			targets[n.get_instance_id()] = n
		if full:
			for n in _synced_nodes(tr):
				targets[n.get_instance_id()] = n
		ops.append_array(_diff_props(tr, targets.values(), not _capture_due and not dragging))
		_structure_due = false
		_capture_due = false
		_last_sel_poll = now
	elif now - _last_sel_poll > SELECTION_POLL_MS:
		_last_sel_poll = now
		var sel := EditorInterface.get_selection().get_selected_nodes()
		if not sel.is_empty():
			ops.append_array(_diff_props(tr, sel, not dragging))
	else:
		# Slow rolling scan catches edits made by tools/plugins that bypass undo/redo.
		var all := _synced_nodes(tr)
		if not all.is_empty():
			var chunk := []
			for i in mini(ROLLING_PER_FRAME, all.size()):
				tr.rolling = (tr.rolling + 1) % all.size()
				chunk.append(all[tr.rolling])
			ops.append_array(_diff_props(tr, chunk, not dragging))
	if not ops.is_empty():
		_submit(tr, ops)


## Captures local edits still waiting for this frame's diff, so they're ours (pending) before a
## teammate's changes are applied on top; otherwise a node added this frame could look like a
## stranger to the reconcile and be removed.
func _capture_pending(tr: Tracker) -> void:
	if tr != current_tracker() or not tr.ready or applying or not (_structure_due or _capture_due):
		return
	var ops := _diff_structure(tr)
	var targets := {}
	for n in EditorInterface.get_selection().get_selected_nodes():
		targets[n.get_instance_id()] = n
	if _capture_due and tr.cache.size() <= FULL_DIFF_LIMIT:
		for n in _synced_nodes(tr):
			targets[n.get_instance_id()] = n
	ops.append_array(_diff_props(tr, targets.values()))
	_structure_due = false
	_capture_due = false
	if not ops.is_empty():
		_submit(tr, ops)


## Sends batches that were held back (made while the host didn't have us).
func _send_unsent(tr: Tracker) -> void:
	if not (_online() and tr.live):
		return
	var cs: Array = tr.batches.keys()
	cs.sort()
	for c in cs:
		if not tr.batches[c].get("sent", true):
			tr.batches[c].sent = true
			_send({"t": "sc_ops", "path": tr.path, "cseq": c, "ops": tr.batches[c].ops})


## True while a property keeps changing by itself (more than CHURN_LIMIT changes, each within
## CHURN_GAP_MS of the last): those changes aren't sent until it has been still for CHURN_QUIET_MS,
## then the value it settled on is. Changes from editor actions always go through.
func _volatile(key: String, value, passive: bool) -> bool:
	var now := Util.now_ms()
	var e: Dictionary = _churn.get(key, {})
	if e.is_empty() or not passive:
		_churn[key] = {"v": value, "last": now, "n": 0}
		return false
	if not Util.same(value, e.v):
		e.n = int(e.n) + 1 if now - int(e.last) < CHURN_GAP_MS else 1
		e.v = value
		e.last = now
	return int(e.n) >= CHURN_LIMIT and now - int(e.last) < CHURN_QUIET_MS


func _diff_structure(tr: Tracker) -> Array:
	var ops := []
	var nodes := _synced_nodes(tr)
	var local_order := {}
	var parent_of := {}
	var seen := {}
	for n in nodes:
		var id := id_of(tr, n)
		var pid := "" if n == tr.root else id_of(tr, n.get_parent())
		seen[id] = true
		parent_of[id] = pid
		if not local_order.has(pid):
			local_order[pid] = []
		local_order[pid].append(id)
	# Simulate the host's order lists so we only send moves for real reorders.
	var sim := {}
	for pid in tr.order:
		sim[pid] = tr.order[pid].duplicate()
	# Deletions (only top-most deleted nodes). Children that are still in the scene are kept:
	# "Change Type" and similar replace a node and move its children onto the replacement.
	var dels := []
	var gone := {}           # parent id -> {name: true} of deleted nodes
	for id in tr.cache.keys():
		if seen.has(id) or not tr.cache.has(id):
			continue
		var p := String(tr.cache[id].p)
		if not tr.cache.has(p) or seen.has(p) or p.is_empty():
			dels.append({"k": "del", "id": id})
			if not gone.has(p):
				gone[p] = {}
			gone[p][String(tr.cache[id].n)] = true
		_forget_subtree(tr, id, sim, seen)
	var renames := []
	for n in nodes:
		var id := id_of(tr, n)
		var pid: String = parent_of[id]
		var si: int = local_order[pid].find(id)
		if not tr.cache.has(id):
			var rec := _record(tr, n, pid)
			var op := rec.duplicate()
			op["k"] = "add"
			op["id"] = id
			op["si"] = si
			ops.append(op)
			tr.cache[id] = rec
			if not sim.has(pid):
				sim[pid] = []
			sim[pid].insert(mini(si, sim[pid].size()), id)
			if gone.get(pid, {}).has(rec.n):
				renames.append({"k": "name", "id": id, "n": rec.n})
			continue
		var old: Dictionary = tr.cache[id]
		if String(old.p) != pid:
			ops.append({"k": "move", "id": id, "p": pid, "si": si})
			if sim.has(old.p):
				sim[old.p].erase(id)
			if not sim.has(pid):
				sim[pid] = []
			sim[pid].insert(mini(si, sim[pid].size()), id)
			old.p = pid
			if gone.get(pid, {}).has(String(n.name)):
				renames.append({"k": "name", "id": id, "n": String(n.name)})
		if String(old.n) != String(n.name):
			ops.append({"k": "name", "id": id, "n": String(n.name)})
			old.n = String(n.name)
	# The host still has the deleted nodes until the deletes, so they come after the adds and
	# moves (which may use their children), then sibling order, then names a deleted node held
	# (a replacement keeps the original's name, which the host had to change while both existed).
	ops.append_array(dels)
	for pid in local_order:
		var want: Array = local_order[pid]
		var have: Array = sim.get(pid, [])
		# Where something was deleted, positions in the adds and moves above were counted without
		# it while the host still had it: send the order again.
		if have != want or gone.has(pid):
			for i in want.size():
				ops.append({"k": "move", "id": want[i], "p": pid, "si": i})
	ops.append_array(renames)
	tr.order = local_order
	return ops


func _forget_subtree(tr: Tracker, id: String, sim: Dictionary, keep := {}) -> void:
	if not tr.cache.has(id) or keep.has(id):
		return
	var p := String(tr.cache[id].p)
	if sim.has(p):
		sim[p].erase(id)
	for cid in tr.order.get(id, []):
		_forget_subtree(tr, cid, sim, keep)
	sim.erase(id)
	tr.cache.erase(id)
	tr.order.erase(id)
	var iid = tr.nodes.get(id)
	tr.nodes.erase(id)
	if iid != null and tr.ids.get(iid) == id:
		tr.ids.erase(iid)


func _diff_props(tr: Tracker, nodes: Array, passive := false) -> Array:
	var ops := []
	for n in nodes:
		if not (n is Node) or not is_instance_valid(n) or not tr.ids.has(n.get_instance_id()):
			continue
		var id: String = tr.ids[n.get_instance_id()]
		if not tr.cache.has(id):
			continue
		var old: Dictionary = tr.cache[id]
		var props := _props_of(tr, n)
		var changed := {}
		var reset := []
		var old_props: Dictionary = old.props
		for k in props:
			if not old_props.has(k) or not Util.same(props[k], old_props[k]):
				# A throttled key keeps its old cached value, so the value it settles on is sent.
				if not _volatile(id + "/" + String(k), props[k], passive):
					changed[k] = props[k]
		for k in old_props:
			if not props.has(k):
				reset.append(k)
		if not changed.is_empty() or not reset.is_empty():
			ops.append({"k": "set", "id": id, "props": changed, "reset": reset})
			for k in changed:
				old_props[k] = changed[k]
			for k in reset:
				old_props.erase(k)
		var groups := _groups_of(tr, n)
		if groups != Array(old.groups):
			ops.append({"k": "groups", "id": id, "groups": groups})
			old.groups = groups
		var conns := _conns_of(tr, n)
		if conns != Array(old.conns):
			ops.append({"k": "conns", "id": id, "conns": conns})
			old.conns = conns
	return ops


static func _op_keys(op: Dictionary) -> Array:
	var id := String(op.get("id", ""))
	match String(op.get("k", "")):
		"add", "del":
			return [id + "/$x"]
		"move":
			return [id + "/$p"]
		"name":
			return [id + "/$n"]
		"groups":
			return [id + "/$g"]
		"conns":
			return [id + "/$c"]
		"set":
			var keys := []
			for k in op.get("props", {}):
				keys.append(id + "/" + String(k))
			for k in op.get("reset", []):
				keys.append(id + "/" + String(k))
			return keys
	return []


func _submit(tr: Tracker, ops: Array) -> void:
	var s = _session()
	var rel := Util.res_to_rel(tr.path)
	var read_only: bool = not s.can_edit() or (s.role == "editor" and not _allowed(s, rel))
	var locked_by_other: bool = tr.lock_holder != 0 and tr.lock_holder != s.my_pid
	if read_only or locked_by_other:
		# Put it back the way the host has it.
		_send({"t": "sc_get", "path": tr.path})
		if Util.now_ms() - tr.warned_readonly > 4000:
			tr.warned_readonly = Util.now_ms()
			var why := "You're a viewer in this session" if not s.can_edit() else ("%s has locked this scene" % s.peer_name(tr.lock_holder) if locked_by_other else "You don't have write access to this folder")
			plugin.toast("%s, so your change to %s was undone." % [why, tr.path.get_file()], 1)
		return
	_next_cseq += 1
	tr.cseq = _next_cseq
	var keys := []
	for op in ops:
		for k in _op_keys(op):
			keys.append(k)
			tr.pending[k] = int(tr.pending.get(k, 0)) + 1
	var live: bool = _online() and tr.live
	tr.batches[tr.cseq] = {"keys": keys, "ops": ops, "reapply": false, "sent": live}
	if live:
		_send({"t": "sc_ops", "path": tr.path, "cseq": tr.cseq, "ops": ops})


static func _allowed(s, rel: String) -> bool:
	if s.paths.is_empty():
		return true
	for p in s.paths:
		var prefix := Util.res_to_rel(String(p)).trim_suffix("/")
		if prefix.is_empty() or rel == prefix or rel.begins_with(prefix + "/"):
			return true
	return false


func _ack(tr: Tracker, cseq: int) -> Dictionary:
	var b: Dictionary = tr.batches.get(cseq, {})
	tr.batches.erase(cseq)
	for k in b.get("keys", []):
		var n := int(tr.pending.get(k, 0)) - 1
		if n <= 0:
			tr.pending.erase(k)
		else:
			tr.pending[k] = n
	return b


# --- messages from the host --------------------------------------------------------------------------------

func on_message(m: Dictionary) -> void:
	var path := String(m.get("path", ""))
	var tr: Tracker = trackers.get(path)
	match String(m.get("t", "")):
		"sc_need_snapshot":
			if tr != null and is_instance_valid(tr.root):
				# Our tree becomes the document, unsent edits included.
				tr.batches.clear()
				tr.pending.clear()
				tr.resend_after_state = false
				var snap := _snapshot(tr)
				_send({"t": "sc_snapshot", "path": path, "nodes": snap})
		"sc_state":
			if tr != null and is_instance_valid(tr.root):
				_capture_pending(tr)
				tr.epoch = String(m.get("epoch", ""))
				tr.rev = int(m.get("rev", 0))
				tr.lock_holder = int(m.get("lock", 0))
				var acked := int(m.get("acked", 0))
				var resend := []
				var cs: Array = tr.batches.keys()
				cs.sort()
				for c in cs:
					if tr.resend_after_state and c <= acked:
						_ack(tr, c)          # the host got it before we dropped: it's in this state
						continue
					# Made against the old state: re-apply once acknowledged.
					tr.batches[c].reapply = true
					if tr.resend_after_state or not tr.batches[c].get("sent", true):
						resend.append(c)
				tr.resend_after_state = false
				if _reconcile(tr, m.get("nodes", [])):
					tr.unsaved_pending = true
				tr.ready = true
				tr.live = true
				for c in resend:
					tr.batches[c].sent = true
					_send({"t": "sc_ops", "path": path, "cseq": c, "ops": tr.batches[c].ops})
				plugin.update_overlays()
		"sc_ops":
			if tr == null or not tr.ready:
				return
			tr.rev = int(m.get("rev", tr.rev))
			var ops: Array = m.get("ops", [])
			if int(m.get("by", 0)) == _session().my_pid:
				var b := _ack(tr, int(m.get("cseq", 0)))
				if b.get("reapply", false):
					_apply_remote(tr, ops, true)
				else:
					_apply_fixups(tr, ops)
			else:
				_capture_pending(tr)
				_apply_remote(tr, ops, false)
		"sc_reject":
			if tr != null:
				_ack(tr, int(m.get("cseq", 0)))
				var reason := String(m.get("reason", ""))
				if reason == "locked":
					plugin.toast("%s is locked by %s, so your change was undone." % [path.get_file(), _session().peer_name(tr.lock_holder)], 1)
				elif reason == "read_only":
					plugin.toast("You can't edit %s in this session." % path.get_file(), 1)
				_send({"t": "sc_get", "path": path})
		"lock_state":
			if tr != null:
				tr.lock_holder = int(m.get("holder", 0))
				plugin.update_overlays()
				plugin.refresh_ui()


## Host renamed one of our nodes to keep sibling names unique (and possibly named it back later
## in the same batch, after a node it replaced was deleted).
func _apply_fixups(tr: Tracker, ops: Array) -> void:
	var fixed := {}
	for op in ops:
		if not (op is Dictionary) or not op.has("n"):
			continue
		var id := String(op.get("id", ""))
		if not (op.get("fixed", false) or (String(op.get("k", "")) == "name" and fixed.has(id))):
			continue
		fixed[id] = true
		var n := _node_by_id(tr, id)
		if n == null:
			continue
		applying = true
		if String(n.name) != String(op.n):
			_make_room(tr, n.get_parent(), String(op.n), n)
			n.name = String(op.n)
		applying = false
		if tr.cache.has(id):
			tr.cache[id].n = String(n.name)


## A teammate's node is about to take the name `wanted` under `parent`. If one of our own nodes
## that the host hasn't confirmed yet has that name, step it aside: the host gave the name to the
## teammate, and will send our node's final name when it confirms our change. Returns false when
## the name belongs to a node that's already in sync (only a full reconcile can sort that out).
func _make_room(tr: Tracker, parent: Node, wanted: String, except: Node = null) -> bool:
	if parent == null or wanted.is_empty():
		return true
	var other := parent.get_node_or_null(NodePath(wanted))
	if other == null or other == except or other.get_parent() != parent:
		return true
	var oid := String(tr.ids.get(other.get_instance_id(), ""))
	if oid.is_empty() or not (tr.pending.has(oid + "/$x") or tr.pending.has(oid + "/$n") or tr.pending.has(oid + "/$p")):
		return false
	other.name = wanted + "_" + Util.random_hex(2)
	if tr.cache.has(oid):
		tr.cache[oid].n = String(other.name)
	return true


# --- applying remote changes ---------------------------------------------------------------------------------

func _apply_remote(tr: Tracker, ops: Array, force: bool) -> void:
	if not is_instance_valid(tr.root):
		return
	applying = true
	var need_resync := false
	var touched := {}
	var late := []   # groups/conns/node refs, applied after all nodes exist
	tr.wire.unresolved_node = false
	tr.wire.allow_code = _trust_code()
	tr.wire.blocked_code = false
	if not ops.is_empty():
		tr.unsaved_pending = true
	for op in ops:
		if not (op is Dictionary):
			continue
		var id := String(op.get("id", ""))
		var pend := func(key: String) -> bool: return not force and tr.pending.has(id + "/" + key)
		match String(op.get("k", "")):
			"add":
				if _node_by_id(tr, id) != null and tr.cache.has(id):
					continue
				var parent := _node_by_id(tr, String(op.get("p", "")))
				var n := _instantiate(op)
				if parent == null or n == null:
					if n == null and _inst_missing(op):
						tr.missing_files = true     # fetched again once the file arrives
					else:
						need_resync = true
					if n != null:
						n.free()
					continue
				n.name = String(op.get("n", "Node"))
				if not _make_room(tr, parent, String(n.name)):
					need_resync = true
				parent.add_child(n, true)
				n.owner = tr.root
				_set_index(tr, parent, n, int(op.get("si", 0)))
				_register(tr, n, id)
				var props: Dictionary = op.get("props", {})
				_apply_props(tr, n, id, props, [], true)
				tr.cache[id] = {"p": String(op.p), "n": String(n.name), "c": String(op.get("c", "")), "inst": String(op.get("inst", "")),
					"props": {}, "groups": [], "conns": []}
				if not tr.order.has(op.p):
					tr.order[op.p] = []
				tr.order[op.p].insert(mini(int(op.get("si", 0)), tr.order[op.p].size()), id)
				late.append(["groups", n, id, op.get("groups", [])])
				late.append(["conns", n, id, op.get("conns", [])])
				touched[id] = n
			"del":
				if pend.call("$x"):
					continue
				var n := _node_by_id(tr, id)
				if n != null and n != tr.root:
					_remove_node(tr, n)
				var dummy := {}
				_forget_subtree(tr, id, dummy)
				for pid in tr.order:
					tr.order[pid].erase(id)
			"move":
				if pend.call("$p"):
					continue
				var n := _node_by_id(tr, id)
				var parent := _node_by_id(tr, String(op.get("p", "")))
				if n == null or parent == null or n == tr.root or n.is_ancestor_of(parent):
					need_resync = true
					continue
				if n.get_parent() != parent:
					_make_room(tr, parent, String(op.get("n", n.name)), n)
					n.reparent(parent, false)
					_fix_owner(tr, n)
				if op.has("n") and String(n.name) != String(op.n):
					_make_room(tr, parent, String(op.n), n)
					n.name = String(op.n)
				_set_index(tr, parent, n, int(op.get("si", 0)))
				if tr.cache.has(id):
					var oldp := String(tr.cache[id].p)
					if tr.order.has(oldp):
						tr.order[oldp].erase(id)
					tr.cache[id].p = String(op.p)
					tr.cache[id].n = String(n.name)
				if not tr.order.has(op.p):
					tr.order[op.p] = []
				tr.order[op.p].insert(mini(int(op.get("si", 0)), tr.order[op.p].size()), id)
			"name":
				if pend.call("$n"):
					continue
				var n := _node_by_id(tr, id)
				if n == null:
					need_resync = true
					continue
				if not _make_room(tr, n.get_parent(), String(op.get("n", n.name)), n):
					need_resync = true
				n.name = String(op.get("n", n.name))
				if tr.cache.has(id):
					tr.cache[id].n = String(n.name)
			"set":
				var n := _node_by_id(tr, id)
				if n == null:
					need_resync = true
					continue
				var props := {}
				var src: Dictionary = op.get("props", {})
				for k in src:
					if not pend.call(String(k)):
						props[k] = src[k]
				var reset := []
				for k in op.get("reset", []):
					if not pend.call(String(k)):
						reset.append(k)
				_apply_props(tr, n, id, props, reset, false)
				touched[id] = n
			"groups":
				if not pend.call("$g"):
					var n := _node_by_id(tr, id)
					if n != null:
						late.append(["groups", n, id, op.get("groups", [])])
			"conns":
				if not pend.call("$c"):
					var n := _node_by_id(tr, id)
					if n != null:
						late.append(["conns", n, id, op.get("conns", [])])
	for l in late:
		if not is_instance_valid(l[1]):
			continue
		if l[0] == "groups":
			_apply_groups(tr, l[1], l[3])
		else:
			_apply_conns(tr, l[1], l[3])
	# Node references may point at nodes added later in the same batch: retry them now.
	if tr.wire.unresolved_node:
		for id in touched:
			var n: Node = touched[id]
			if is_instance_valid(n):
				for op in ops:
					if op is Dictionary and String(op.get("id", "")) == id and op.has("props"):
						_apply_props(tr, n, id, op.props, [], true)
	# The cache mirrors what is actually in the tree now, so nothing gets echoed back.
	for id in touched:
		var n: Node = touched[id]
		if is_instance_valid(n) and tr.cache.has(id):
			var c: Dictionary = tr.cache[id]
			c.props = _props_of(tr, n)
			c.groups = _groups_of(tr, n)
			c.conns = _conns_of(tr, n)
	applying = false
	_warn_blocked_code(tr)
	_refresh_inspector(touched)
	plugin.update_overlays()
	if need_resync:
		_send({"t": "sc_get", "path": tr.path})


## Whether embedded @tool scripts from teammates may run here (same trust as for files).
func _trust_code() -> bool:
	return _session() != null and _session().files != null and _session().files.trust_risky


func _warn_blocked_code(tr: Tracker) -> void:
	if tr.wire.blocked_code and not tr.warned_code:
		tr.warned_code = true
		if _session() != null and _session().is_host:
			plugin.toast("A teammate's change to %s includes a built-in @tool script, which would run in your editor. It was left out; when they save the scene, it comes to the Co-op dock's Review tab." % tr.path.get_file(), 1)
		else:
			plugin.toast("A teammate's change to %s includes a built-in @tool script, which would run in your editor. It was left out. Turn on trusting the host's editor scripts to allow it." % tr.path.get_file(), 1)


static func _inst_missing(op: Dictionary) -> bool:
	var inst := String(op.get("inst", ""))
	return not inst.is_empty() and Util.is_safe_res_path(inst) and not ResourceLoader.exists(inst)


func _instantiate(op: Dictionary) -> Node:
	var inst := String(op.get("inst", ""))
	if not inst.is_empty():
		if not Util.is_safe_res_path(inst) or not ResourceLoader.exists(inst):
			return null
		var ps = ResourceLoader.load(inst)
		if not (ps is PackedScene):
			return null
		return ps.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
	var cls := String(op.get("c", ""))
	if not ClassDB.class_exists(cls) or not ClassDB.can_instantiate(cls) or not ClassDB.is_parent_class(cls, "Node"):
		return null
	return ClassDB.instantiate(cls)


func _apply_props(tr: Tracker, n: Node, id: String, props: Dictionary, reset: Array, is_new: bool) -> void:
	tr.wire.missing_resource = false
	if props.has("script"):
		var blocked := tr.wire.blocked_code
		tr.wire.blocked_code = false
		var s = tr.wire.from_wire(props["script"])
		if tr.wire.missing_resource:
			# The script file hasn't arrived yet (or is waiting for review): attach it later.
			tr.failed.append([id, "script", props["script"]])
			tr.wire.missing_resource = false
		elif not tr.wire.blocked_code and n.get_script() != s:
			n.set_script(s)
		tr.wire.blocked_code = tr.wire.blocked_code or blocked
	elif is_new == false and reset.has("script"):
		n.set_script(null)
	for k in props:
		if k == "script":
			continue
		var cur = n.get(k)
		tr.wire.missing_resource = false
		var v = tr.wire.from_wire(props[k], cur)
		if tr.wire.missing_resource:
			tr.failed.append([id, k, props[k]])
		if typeof(v) != typeof(cur) or v != cur:
			n.set(k, v)
	for k in reset:
		if k == "script":
			continue
		n.set(k, _base_value(tr, n, String(k)))


## Retry property values that referenced files we didn't have yet.
func retry_failed() -> void:
	for path in trackers:
		var tr: Tracker = trackers[path]
		if tr.missing_files and tr.live and _online():
			tr.missing_files = false
			_send({"t": "sc_get", "path": path})
		if tr.failed.is_empty():
			continue
		var items := tr.failed.duplicate()
		tr.failed.clear()
		applying = true
		tr.wire.allow_code = _trust_code()
		var touched := {}
		for f in items:
			var n := _node_by_id(tr, f[0])
			if n != null:
				_apply_props(tr, n, f[0], {f[1]: f[2]}, [], true)
				touched[f[0]] = n
		for id in touched:
			if tr.cache.has(id):
				tr.cache[id].props = _props_of(tr, touched[id])
		applying = false


func _apply_groups(tr: Tracker, n: Node, groups: Array) -> void:
	var want := {}
	for g in groups:
		want[String(g)] = true
	for g in _groups_of(tr, n):
		if not want.has(g):
			n.remove_from_group(g)
	for g in want:
		if not n.is_in_group(g):
			n.add_to_group(g, true)
	if tr.cache.has(tr.ids.get(n.get_instance_id(), "")):
		tr.cache[tr.ids[n.get_instance_id()]].groups = _groups_of(tr, n)


func _apply_conns(tr: Tracker, target: Node, conns: Array) -> void:
	var have := _conns_of(tr, target)
	var want_keys := {}
	for c in conns:
		want_keys[str(c)] = c
	var have_keys := {}
	for c in have:
		have_keys[str(c)] = c
	# Remove connections that are gone.
	for c in target.get_incoming_connections():
		if not (int(c.flags) & CONNECT_PERSIST):
			continue
		var sig: Signal = c.signal
		var src = sig.get_object()
		if not (src is Node) or not tr.ids.has(src.get_instance_id()):
			continue
		var cb: Callable = c.callable
		var key := str([tr.ids[src.get_instance_id()], String(sig.get_name()), String(cb.get_method()), int(c.flags) & (CONNECT_DEFERRED | CONNECT_ONE_SHOT | CONNECT_APPEND_SOURCE_OBJECT), tr.wire.to_wire(cb.get_bound_arguments()), cb.get_unbound_arguments_count()])
		if not want_keys.has(key):
			src.disconnect(sig.get_name(), cb)
	for key in want_keys:
		if have_keys.has(key):
			continue
		var c: Array = want_keys[key]
		if c.size() < 6:
			continue
		var src := _node_by_id(tr, String(c[0]))
		if src == null or not src.has_signal(String(c[1])):
			continue
		var cb := Callable(target, StringName(String(c[2])))
		var binds = tr.wire.from_wire(c[4])
		if binds is Array and not binds.is_empty():
			cb = cb.bindv(binds)
		if int(c[5]) > 0:
			cb = cb.unbind(int(c[5]))
		if not src.is_connected(String(c[1]), cb):
			src.connect(String(c[1]), cb, int(c[3]) | CONNECT_PERSIST)
	var id := String(tr.ids.get(target.get_instance_id(), ""))
	if tr.cache.has(id):
		tr.cache[id].conns = _conns_of(tr, target)


func _fix_owner(tr: Tracker, n: Node) -> void:
	if n.owner != tr.root and n.owner == null:
		n.owner = tr.root
	if n.scene_file_path.is_empty():
		for c in n.get_children():
			if c.owner == null or c.owner == tr.root:
				_fix_owner(tr, c)


func _set_index(tr: Tracker, parent: Node, node: Node, si: int) -> void:
	var sibs := []
	for c in parent.get_children():
		if c != node and (c.owner == tr.root):
			sibs.append(c)
	var target := 0
	if si < sibs.size():
		target = sibs[si].get_index()
	elif not sibs.is_empty():
		target = sibs[-1].get_index() + 1
	else:
		target = node.get_index()
	if node.get_index() < target:
		target -= 1
	target = clampi(target, 0, parent.get_child_count() - 1)
	if node.get_index() != target:
		parent.move_child(node, target)


func _remove_node(tr: Tracker, n: Node) -> void:
	var sel := EditorInterface.get_selection()
	var stack: Array = [n]
	while not stack.is_empty():
		var x: Node = stack.pop_back()
		if sel.get_selected_nodes().has(x):
			sel.remove_node(x)
		stack.append_array(x.get_children())
	var insp := EditorInterface.get_inspector().get_edited_object()
	if insp is Node and (insp == n or n.is_ancestor_of(insp)):
		EditorInterface.inspect_object(tr.root)
	n.get_parent().remove_child(n)
	# Keep the node alive: your own undo history may still point at it.
	tr.graveyard.append(n)


func _refresh_inspector(touched: Dictionary) -> void:
	var obj := EditorInterface.get_inspector().get_edited_object()
	if obj == null:
		return
	for id in touched:
		if touched[id] == obj and is_instance_valid(obj):
			obj.notify_property_list_changed()
			return


## Make the local tree match the host's copy exactly. Returns true if anything changed.
func _reconcile(tr: Tracker, list: Array) -> bool:
	applying = true
	tr.wire.allow_code = _trust_code()
	tr.wire.blocked_code = false
	var changed := false
	var doc := {}
	var kids := {}
	var order_ids := []
	for r in list:
		if not (r is Dictionary):
			continue
		var id := String(r.get("id", ""))
		doc[id] = r
		order_ids.append(id)
		var p := String(r.get("p", ""))
		if not kids.has(p):
			kids[p] = []
		kids[p].append(id)
	var paths := {}
	for id in order_ids:
		var r: Dictionary = doc[id]
		var p := String(r.get("p", ""))
		if p.is_empty():
			paths[id] = "."
		else:
			var pp := String(paths.get(p, "?"))
			paths[id] = String(r.n) if pp == "." else pp + "/" + String(r.n)
	# 1. Nodes we already know keep their ids, wherever they are now (so a node that was moved or
	#    renamed is put back rather than rebuilt); the rest are matched by path.
	var known := {}
	for id in order_ids:
		var n := _node_by_id(tr, id)
		if n != null and _same_kind(tr, n, doc[id]) and (n == tr.root or (n.owner == tr.root and tr.root.is_ancestor_of(n))):
			known[id] = n
	tr.ids.clear()
	tr.nodes.clear()
	var used := {}
	for id in known:
		_register(tr, known[id], id)
		used[known[id].get_instance_id()] = true
	var local := {}
	for n in _synced_nodes(tr):
		local["." if n == tr.root else String(tr.root.get_path_to(n))] = n
	for id in order_ids:
		if known.has(id):
			continue
		var n: Node = local.get(paths[id])
		if n != null and not used.has(n.get_instance_id()) and _same_kind(tr, n, doc[id]):
			_register(tr, n, id)
			used[n.get_instance_id()] = true
	# 2. Create missing nodes and put every node under its parent (parents first).
	for id in order_ids:
		var r: Dictionary = doc[id]
		var p := String(r.get("p", ""))
		if p.is_empty():
			continue
		var parent := _node_by_id(tr, p)
		if parent == null:
			continue
		var n := _node_by_id(tr, id)
		if n == null:
			n = _instantiate(r)
			if n == null:
				if _inst_missing(r):
					tr.missing_files = true
				continue
			n.name = String(r.get("n", "Node"))
			parent.add_child(n, true)
			n.owner = tr.root
			_register(tr, n, id)
			used[n.get_instance_id()] = true
			changed = true
		elif n.get_parent() != parent and not n.is_ancestor_of(parent):
			n.reparent(parent, false)
			_fix_owner(tr, n)
			changed = true
	# 3. Remove local nodes that the doc doesn't have (deepest first).
	var locals := _synced_nodes(tr)
	for i in range(locals.size() - 1, -1, -1):
		var n: Node = locals[i]
		if n != tr.root and not used.has(n.get_instance_id()) and is_instance_valid(n) and n.get_parent() != null:
			_remove_node(tr, n)
			changed = true
	# 4. Names, in two steps so that swapped names don't collide on the way.
	var renames := []
	for id in order_ids:
		var n := _node_by_id(tr, id)
		if n != null and n != tr.root and String(n.name) != String(doc[id].n):
			renames.append([n, String(doc[id].n)])
	for e in renames:
		e[0].name = String(e[1]) + "_" + Util.random_hex(3)
	for e in renames:
		e[0].name = e[1]
		changed = true
	# 5. Properties, order, groups and connections.
	tr.cache.clear()
	tr.order.clear()
	for id in order_ids:
		var n := _node_by_id(tr, id)
		if n == null:
			continue
		var r: Dictionary = doc[id]
		var props: Dictionary = r.get("props", {})
		var current := _props_of(tr, n)
		var diff := {}
		var reset := []
		for k in props:
			if not current.has(k) or not Wire.same_value(current[k], props[k]):
				diff[k] = props[k]
		for k in current:
			if not props.has(k):
				reset.append(k)
		if not diff.is_empty() or not reset.is_empty():
			_apply_props(tr, n, id, diff, reset, false)
			changed = true
	for pid in kids:
		var parent := _node_by_id(tr, pid) if not String(pid).is_empty() else null
		if parent == null:
			continue
		var i := 0
		for cid in kids[pid]:
			var c := _node_by_id(tr, cid)
			if c != null and c.get_parent() == parent:
				var before := c.get_index()
				_set_index(tr, parent, c, i)
				changed = changed or c.get_index() != before
				i += 1
	for id in order_ids:
		var n := _node_by_id(tr, id)
		if n == null:
			continue
		var r: Dictionary = doc[id]
		_apply_groups(tr, n, r.get("groups", []))
		_apply_conns(tr, n, r.get("conns", []))
	# Cache = what is actually in the tree now.
	for n in _synced_nodes(tr):
		var id := id_of(tr, n)
		var pid := "" if n == tr.root else id_of(tr, n.get_parent())
		tr.cache[id] = _record(tr, n, pid)
		if not tr.order.has(pid):
			tr.order[pid] = []
		tr.order[pid].append(id)
	applying = false
	_structure_due = false
	_capture_due = false
	_warn_blocked_code(tr)
	var touched := {}
	for id in tr.nodes:
		touched[id] = _node_by_id(tr, id)
	_refresh_inspector(touched)
	return changed


func _same_kind(tr: Tracker, n: Node, r: Dictionary) -> bool:
	if n == tr.root:
		return String(r.get("p", "")).is_empty()
	if String(r.get("p", "")).is_empty():
		return false
	return n.get_class() == String(r.get("c", "")) and (n.scene_file_path if _is_instance(tr, n) else "") == String(r.get("inst", ""))
