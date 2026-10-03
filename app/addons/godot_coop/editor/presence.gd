@tool
extends RefCounted
## Presence: where everyone is, what they have selected, their mouse cursor in 2D, their camera in
## 3D, "follow" mode (your view tracks theirs) and pings (flash something for everyone).

const Util := preload("res://addons/godot_coop/core/util.gd")
const Net := preload("res://addons/godot_coop/core/net.gd")

const SEND_MS := 150
const FAST_MS := 90
const PING_MS := 2600

var plugin
var following := 0
var main_screen := "2D"
var _last_send := 0
var _last_fast := 0
var _last_sent := {}
var _last_fast_sent := {}
var _pings: Array = []
var _decorated: Array = []
var _last_decorate := 0
var _last_overlay := 0
var _canvas_editor: Node = null
var _zoom_widget: Node = null
var _scene_tree: Tree = null
var _fs_tree: Tree = null
var _follow_scene := ""
var _follow_script := ""
var last_canvas_click := Vector2.ZERO


func _session():
	return plugin.session


func setup(p) -> void:
	plugin = p
	var base := EditorInterface.get_base_control()
	_canvas_editor = _find_class(EditorInterface.get_editor_main_screen(), "CanvasItemEditor")
	if _canvas_editor != null:
		_zoom_widget = _find_class(_canvas_editor, "EditorZoomWidget")
	var std := _find_class(base, "SceneTreeDock")
	if std != null and std.has_method("get_tree_editor"):
		var ste = std.get_tree_editor()
		if ste != null:
			_scene_tree = _find_class(ste, "Tree")
	var fsd := EditorInterface.get_file_system_dock()
	if fsd != null:
		_fs_tree = _find_class(fsd, "Tree")


static func _find_class(n: Node, cls: String) -> Node:
	if n == null:
		return null
	if n.get_class() == cls:
		return n
	for c in n.get_children(true):
		var r := _find_class(c, cls)
		if r != null:
			return r
	return null


func on_main_screen_changed(name: String) -> void:
	main_screen = name


func describe(pid: int) -> String:
	var p: Dictionary = _session().presence.get(pid, {})
	if p.is_empty():
		return "Online" if _session().roster.get(pid, {}).get("online", false) else "Offline"
	var screen := String(p.get("screen", ""))
	if screen == "Script" and not String(p.get("script", "")).is_empty():
		return "%s:%d" % [String(p.script).get_file(), int(p.get("line", 0)) + 1]
	var scene := String(p.get("scene", ""))
	if scene.is_empty():
		return screen
	return "%s · %s" % [scene.get_file(), screen]


# --- sending ---------------------------------------------------------------------------------------

func process() -> void:
	var now := Util.now_ms()
	var s = _session()
	if _recenter_at > 0 and now >= _recenter_at:
		_recenter_at = 0
		if _canvas_editor != null and _canvas_editor.has_method("center_at"):
			_canvas_editor.center_at(_recenter_to)
	if now - _last_send >= SEND_MS:
		_last_send = now
		var p := _gather()
		if p != _last_sent:
			_last_sent = p
			s.send(p, Net.CH_CTRL)
	if now - _last_fast >= FAST_MS:
		_last_fast = now
		var f := _gather_fast()
		if f != _last_fast_sent:
			_last_fast_sent = f
			s.send(f, Net.CH_FAST, false)
	if not _pings.is_empty():
		var keep := []
		for pg in _pings:
			if now - int(pg.start) < PING_MS:
				keep.append(pg)
		_pings = keep
		plugin.update_overlays()
	if now - _last_decorate > 350:
		_last_decorate = now
		_decorate_docks()
	# Keep teammates' boxes glued to nodes that move, and draw state that arrived before we opened the scene.
	if now - _last_overlay > 250:
		_last_overlay = now
		var root := EditorInterface.get_edited_scene_root()
		if root != null and not _others_in_scene(root.scene_file_path).is_empty():
			plugin.update_overlays()


func _gather() -> Dictionary:
	var root := EditorInterface.get_edited_scene_root()
	var scene := root.scene_file_path if root != null else ""
	var sel := []
	var tr = plugin.scene_sync.current_tracker()
	if tr != null:
		sel = plugin.scene_sync.node_ids(tr, EditorInterface.get_selection().get_selected_nodes())
	var sl: Array = plugin.script_sync.current_line()
	return {"t": "presence", "scene": scene, "screen": main_screen, "sel": sel, "script": sl[0], "line": sl[1]}


func _gather_fast() -> Dictionary:
	var d := {"t": "presence_fast"}
	if main_screen == "2D":
		var vp := EditorInterface.get_editor_viewport_2d()
		var xf := vp.global_canvas_transform
		var zoom := xf.get_scale().x
		var center := _view_center_2d()
		d["cam2d"] = [snappedf(center.x, 0.1), snappedf(center.y, 0.1), snappedf(zoom, 0.0001)]
		var mp := vp.get_mouse_position()
		if Rect2(Vector2.ZERO, Vector2(vp.size)).has_point(mp):
			var w := xf.affine_inverse() * mp
			d["mouse"] = [snappedf(w.x, 0.5), snappedf(w.y, 0.5)]
	elif main_screen == "3D":
		var cam := EditorInterface.get_editor_viewport_3d(0).get_camera_3d()
		if cam != null:
			d["cam3d"] = cam.global_transform
	return d


# --- remote presence: follow -----------------------------------------------------------------------

func on_message(m: Dictionary) -> void:
	match String(m.get("t", "")):
		"presence", "presence_fast":
			var pid := int(m.get("pid", 0))
			if pid == following:
				_apply_follow()
			plugin.update_overlays()
		"peer_left":
			if int(m.get("pid", 0)) == following:
				stop_follow("%s left" % _session().peer_name(following))
			plugin.update_overlays()
		"ping":
			_on_ping(m)


func follow(pid: int) -> void:
	if pid == following or pid == _session().my_pid:
		stop_follow()
		return
	following = pid
	_follow_scene = ""
	_follow_script = ""
	plugin.toast("Following %s. Click in a viewport or press Follow again to stop." % _session().peer_name(pid), 0)
	_apply_follow()
	plugin.refresh_ui()


func stop_follow(why := "") -> void:
	if following == 0:
		return
	following = 0
	if not why.is_empty():
		plugin.toast("Stopped following (%s)." % why, 0)
	plugin.refresh_ui()


func _apply_follow() -> void:
	var p: Dictionary = _session().presence.get(following, {})
	if p.is_empty():
		return
	var scene := String(p.get("scene", ""))
	var screen := String(p.get("screen", ""))
	if not scene.is_empty() and scene != _follow_scene:
		_follow_scene = scene
		var root := EditorInterface.get_edited_scene_root()
		if root == null or root.scene_file_path != scene:
			if ResourceLoader.exists(scene):
				EditorInterface.open_scene_from_path(scene)
	if screen in ["2D", "3D", "Script"] and screen != main_screen:
		EditorInterface.set_main_screen_editor(screen)
	if screen == "Script":
		var sp := String(p.get("script", ""))
		var line := int(p.get("line", 0))
		if not sp.is_empty():
			_follow_script = sp
			var cur := EditorInterface.get_script_editor().get_current_script()
			if cur == null or cur.resource_path != sp:
				if ResourceLoader.exists(sp):
					EditorInterface.edit_script(load(sp), line, 0, false)
			else:
				var ed := EditorInterface.get_script_editor().get_current_editor()
				if ed != null and ed.get_base_editor() is CodeEdit:
					var ce: CodeEdit = ed.get_base_editor()
					if not ce.is_line_in_viewport(line):
						ce.set_line_as_center_visible(line)
	elif screen == "2D" and p.has("cam2d"):
		var c: Array = p.cam2d
		_set_2d_view(Vector2(c[0], c[1]), float(c[2]))
	elif screen == "3D" and p.has("cam3d"):
		var cam := EditorInterface.get_editor_viewport_3d(0).get_camera_3d()
		if cam != null and p.cam3d is Transform3D:
			cam.global_transform = p.cam3d


## The 2D editor frame our overlay draws into - the same frame center_at() uses.
var _overlay_2d: Control = null


func _view_center_2d() -> Vector2:
	var vp := EditorInterface.get_editor_viewport_2d()
	var size := Vector2(vp.size)
	if _overlay_2d != null and is_instance_valid(_overlay_2d) and _overlay_2d.size.x > 0:
		size = _overlay_2d.size
	return vp.global_canvas_transform.affine_inverse() * (size * 0.5)


var _recenter_at := 0
var _recenter_to := Vector2.ZERO


func _set_2d_view(center: Vector2, zoom: float) -> void:
	if _zoom_widget != null and zoom > 0.0 and absf(_zoom_widget.get_zoom() - zoom) > 0.0005:
		_zoom_widget.set_zoom(zoom)
		_zoom_widget.emit_signal("zoom_changed", zoom)
		# The new zoom reaches the view transform a frame later; centre again once it has.
		_recenter_at = Util.now_ms() + 60
		_recenter_to = center
	if _canvas_editor != null and _canvas_editor.has_method("center_at"):
		_canvas_editor.center_at(center)


## Called for viewport input (forwarding is always on): any interaction stops following.
func on_viewport_input(event: InputEvent) -> void:
	if following == 0:
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
			var vp := EditorInterface.get_editor_viewport_2d()
			last_canvas_click = vp.global_canvas_transform.affine_inverse() * vp.get_mouse_position()
		return
	if (event is InputEventMouseButton and event.pressed) or (event is InputEventKey and event.pressed and not event.echo):
		stop_follow("you took the wheel")


# --- pings -----------------------------------------------------------------------------------------

func ping_nodes(nodes: Array) -> void:
	var tr = plugin.scene_sync.current_tracker()
	if tr == null or nodes.is_empty():
		return
	var ids: Array = plugin.scene_sync.node_ids(tr, nodes)
	if ids.is_empty():
		return
	_send_ping({"kind": "node", "scene": tr.path, "ids": ids, "label": String(nodes[0].name)})


func ping_position(pos: Vector2) -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return
	_send_ping({"kind": "pos", "scene": root.scene_file_path, "pos": pos, "label": "a spot"})


func ping_line(script_path: String, line: int) -> void:
	_send_ping({"kind": "line", "script": script_path, "line": line, "label": "%s:%d" % [script_path.get_file(), line + 1]})


func ping_file(path: String) -> void:
	_send_ping({"kind": "file", "file": path, "label": path.get_file()})


func _send_ping(m: Dictionary) -> void:
	m["t"] = "ping"
	_session().send(m, Net.CH_CTRL)
	var local := m.duplicate()
	local["by"] = _session().my_pid
	_on_ping(local, true)


func _on_ping(m: Dictionary, mine := false) -> void:
	var by := int(m.get("by", 0))
	var col: Color = _session().peer_color(by)
	_pings.append({"m": m, "start": Util.now_ms(), "col": col, "name": _session().peer_name(by)})
	plugin.update_overlays()
	if String(m.get("kind", "")) == "line":
		plugin.script_sync.flash_line(String(m.get("script", "")), int(m.get("line", 0)), col)
	if not mine:
		var where := String(m.get("label", "something"))
		if m.has("scene"):
			where += " in " + String(m.scene).get_file()
		plugin.notify("%s pinged %s" % [_session().peer_name(by), where], col, jump.bind(m))


## Opens whatever a ping / activity entry points at.
func jump(m: Dictionary) -> void:
	match String(m.get("kind", m.get("type", ""))):
		"node", "pos", "scene":
			var scene := String(m.get("scene", m.get("path", "")))
			if scene.is_empty() or not ResourceLoader.exists(scene):
				return
			var root := EditorInterface.get_edited_scene_root()
			if root == null or root.scene_file_path != scene:
				EditorInterface.open_scene_from_path(scene)
			var ids: Array = m.get("ids", [m.get("id")] if m.has("id") else [])
			var tr = plugin.scene_sync.trackers.get(scene)
			if tr != null and not ids.is_empty():
				var nodes: Array = plugin.scene_sync.nodes_for_ids(tr, ids)
				if not nodes.is_empty():
					EditorInterface.edit_node(nodes[0])
					var sel := EditorInterface.get_selection()
					sel.clear()
					for n in nodes:
						sel.add_node(n)
					if nodes[0] is Node2D or nodes[0] is Control:
						EditorInterface.set_main_screen_editor("2D")
						_center_2d(nodes[0].get_global_transform().origin)
					elif nodes[0] is Node3D:
						EditorInterface.set_main_screen_editor("3D")
			elif m.has("pos"):
				EditorInterface.set_main_screen_editor("2D")
				_center_2d(m.pos)
		"line", "script":
			var sp := String(m.get("script", m.get("path", "")))
			if ResourceLoader.exists(sp):
				EditorInterface.set_main_screen_editor("Script")
				EditorInterface.edit_script(load(sp), int(m.get("line", 0)))
		"file":
			EditorInterface.select_file(String(m.get("file", m.get("path", ""))))


func _center_2d(pos: Vector2) -> void:
	if _canvas_editor != null and _canvas_editor.has_method("center_at"):
		_canvas_editor.center_at(pos)


# --- drawing ------------------------------------------------------------------------------------------

func _others_in_scene(scene: String) -> Array:
	var out := []
	var s = _session()
	for pid in s.presence:
		if int(pid) == s.my_pid:
			continue
		var p: Dictionary = s.presence[pid]
		if String(p.get("scene", "")) == scene:
			out.append(int(pid))
	return out


func _label(ov: Control, at: Vector2, text: String, col: Color) -> void:
	var font := ov.get_theme_default_font()
	var fs := int(12 * EditorInterface.get_editor_scale())
	var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var r := Rect2(at + Vector2(0, -fs - 6), Vector2(w + 10, fs + 6))
	ov.draw_rect(r, col)
	ov.draw_string(font, r.position + Vector2(5, fs + 1), text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color.BLACK if col.get_luminance() > 0.6 else Color.WHITE)


static func _rect_corners(xf: Transform2D, r: Rect2) -> PackedVector2Array:
	return PackedVector2Array([xf * r.position, xf * Vector2(r.end.x, r.position.y), xf * r.end, xf * Vector2(r.position.x, r.end.y)])


## The node's outline in canvas coordinates (4 corners), or [] when it has no visible extent.
func _corners_2d(n: Node, depth := 0) -> PackedVector2Array:
	if n is Control:
		return _rect_corners(n.get_global_transform(), Rect2(Vector2.ZERO, n.size))
	if n is Node2D and n.has_method("get_rect"):
		return _rect_corners(n.get_global_transform(), n.get_rect())
	if n is CollisionShape2D and n.shape != null:
		return _rect_corners(n.get_global_transform(), n.shape.get_rect())
	if n is CollisionPolygon2D and n.polygon.size() > 2:
		var b := Rect2(n.polygon[0], Vector2.ZERO)
		for p in n.polygon:
			b = b.expand(p)
		return _rect_corners(n.get_global_transform(), b)
	# Bodies, plain Node2Ds…: bound whatever their children draw.
	if depth < 2:
		var pts := PackedVector2Array()
		for c in n.get_children():
			if c is CanvasItem and c.is_visible_in_tree():
				pts.append_array(_corners_2d(c, depth + 1))
		if not pts.is_empty():
			var b := Rect2(pts[0], Vector2.ZERO)
			for p in pts:
				b = b.expand(p)
			return _rect_corners(Transform2D.IDENTITY, b.grow(4))
	return PackedVector2Array()


func draw_2d(ov: Control) -> void:
	_overlay_2d = ov
	var root := EditorInterface.get_edited_scene_root()
	if root == null or _session() == null:
		return
	var scene := root.scene_file_path
	var vp := EditorInterface.get_editor_viewport_2d()
	var xf := vp.global_canvas_transform
	var tr = plugin.scene_sync.current_tracker()
	var s = _session()
	for pid in _others_in_scene(scene):
		var p: Dictionary = s.presence[pid]
		var col: Color = s.peer_color(pid)
		var name: String = s.peer_name(pid)
		if tr != null:
			for n in plugin.scene_sync.nodes_for_ids(tr, p.get("sel", [])):
				if not (n is CanvasItem) or not n.is_visible_in_tree():
					continue
				var pts := _corners_2d(n)
				if pts.size() == 4:
					var sp := PackedVector2Array()
					for q in pts:
						sp.append(xf * q)
					sp.append(sp[0])
					ov.draw_polyline(sp, col, 2.0)
					_label(ov, sp[0], name, col)
				else:
					var c: Vector2 = xf * n.get_global_transform().origin
					ov.draw_rect(Rect2(c - Vector2(12, 12), Vector2(24, 24)), col, false, 2.0)
					_label(ov, c - Vector2(12, 12), name, col)
		if p.has("mouse") and String(p.get("screen", "")) == "2D":
			var m: Array = p.mouse
			var at := xf * Vector2(m[0], m[1])
			_draw_cursor(ov, at, col, name)
	var now := Util.now_ms()
	for pg in _pings:
		var m: Dictionary = pg.m
		if String(m.get("scene", "")) != scene:
			continue
		var t := float(now - int(pg.start)) / PING_MS
		var centers := []
		if m.kind == "pos":
			centers.append(xf * Vector2(m.pos))
		elif m.kind == "node" and tr != null:
			for n in plugin.scene_sync.nodes_for_ids(tr, m.get("ids", [])):
				if n is CanvasItem:
					centers.append(xf * n.get_global_transform().origin)
		for c in centers:
			_draw_ping_rings(ov, c, pg.col, t, pg.name)
	_draw_lock_banner(ov, tr)


func _draw_cursor(ov: Control, at: Vector2, col: Color, name: String) -> void:
	var k := EditorInterface.get_editor_scale()
	var shape := PackedVector2Array([Vector2(0, 0), Vector2(0, 17), Vector2(4.5, 13), Vector2(8, 20.5), Vector2(11, 19.2), Vector2(7.6, 12), Vector2(13, 12)])
	for i in shape.size():
		shape[i] = at + shape[i] * k
	ov.draw_colored_polygon(shape, col)
	var outline := shape.duplicate()
	outline.append(shape[0])
	ov.draw_polyline(outline, Color(0, 0, 0, 0.7), 1.0)
	_label(ov, at + Vector2(14, 34) * k, name, col)


func _draw_ping_rings(ov: Control, c: Vector2, col: Color, t: float, name: String) -> void:
	for i in 3:
		var tt := fmod(t * 2.0 + i * 0.33, 1.0)
		ov.draw_arc(c, 8.0 + tt * 60.0, 0, TAU, 48, Color(col, 1.0 - tt), 3.0)
	ov.draw_circle(c, 6.0, col)
	if t < 0.8:
		_label(ov, c + Vector2(10, -10), "%s pinged" % name, col)


func _draw_lock_banner(ov: Control, tr) -> void:
	if tr == null or tr.lock_holder == 0:
		return
	var s = _session()
	var mine: bool = tr.lock_holder == s.my_pid
	var col: Color = s.peer_color(tr.lock_holder)
	var text := "Locked by you. Others can watch but not edit." if mine else "Locked by %s. You're watching live. Use Request control in the Co-op dock." % s.peer_name(tr.lock_holder)
	var font := ov.get_theme_default_font()
	var fs := int(13 * EditorInterface.get_editor_scale())
	var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var r := Rect2(Vector2((ov.size.x - w) * 0.5 - 12, 8), Vector2(w + 24, fs + 12))
	ov.draw_rect(r, Color(0.08, 0.09, 0.12, 0.85))
	ov.draw_rect(r, col, false, 2.0)
	ov.draw_string(font, r.position + Vector2(12, fs + 3), text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color.WHITE)


func draw_3d(ov: Control) -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null or _session() == null:
		return
	var cam := EditorInterface.get_editor_viewport_3d(0).get_camera_3d()
	if cam == null:
		return
	var scene := root.scene_file_path
	var tr = plugin.scene_sync.current_tracker()
	var s = _session()
	for pid in _others_in_scene(scene):
		var p: Dictionary = s.presence[pid]
		var col: Color = s.peer_color(pid)
		var name: String = s.peer_name(pid)
		if tr != null:
			for n in plugin.scene_sync.nodes_for_ids(tr, p.get("sel", [])):
				if n is Node3D and n.is_visible_in_tree():
					_draw_box_3d(ov, cam, n, col, name)
		if p.has("cam3d") and p.cam3d is Transform3D:
			var t: Transform3D = p.cam3d
			if not cam.is_position_behind(t.origin) and t.origin.distance_to(cam.global_position) > 0.2:
				var at := cam.unproject_position(t.origin)
				var fwd := cam.unproject_position(t.origin - t.basis.z * 0.6) if not cam.is_position_behind(t.origin - t.basis.z * 0.6) else at
				ov.draw_rect(Rect2(at - Vector2(9, 6), Vector2(18, 12)), col)
				ov.draw_line(at, fwd, col, 3.0)
				_label(ov, at + Vector2(-9, -8), name + "'s view", col)
	var now := Util.now_ms()
	for pg in _pings:
		var m: Dictionary = pg.m
		if String(m.get("scene", "")) != scene or m.kind != "node" or tr == null:
			continue
		var t := float(now - int(pg.start)) / PING_MS
		for n in plugin.scene_sync.nodes_for_ids(tr, m.get("ids", [])):
			if n is Node3D and not cam.is_position_behind(n.global_position):
				_draw_ping_rings(ov, cam.unproject_position(n.global_position), pg.col, t, pg.name)
	_draw_lock_banner(ov, tr)


func _draw_box_3d(ov: Control, cam: Camera3D, n: Node3D, col: Color, name: String) -> void:
	var aabb := AABB(Vector3(-0.25, -0.25, -0.25), Vector3(0.5, 0.5, 0.5))
	if n is VisualInstance3D:
		var a: AABB = n.get_aabb()
		if a.size.length() > 0.0001:
			aabb = a
	var xf := n.global_transform
	var corners := []
	for i in 8:
		corners.append(xf * aabb.get_endpoint(i))
	for c in corners:
		if cam.is_position_behind(c):
			return
	var p2 := []
	for c in corners:
		p2.append(cam.unproject_position(c))
	for e in [[0, 1], [1, 3], [3, 2], [2, 0], [4, 5], [5, 7], [7, 6], [6, 4], [0, 4], [1, 5], [2, 6], [3, 7]]:
		ov.draw_line(p2[e[0]], p2[e[1]], col, 2.0)
	var top: Vector2 = p2[0]
	for q in p2:
		if q.y < top.y:
			top = q
	_label(ov, top, name, col)


# --- dock decorations (Scene tree + FileSystem) -----------------------------------------------------------

func _decorate_docks() -> void:
	for item in _decorated:
		if is_instance_valid(item):
			item.clear_custom_bg_color(0)
	_decorated.clear()
	var s = _session()
	if s == null:
		return
	var root := EditorInterface.get_edited_scene_root()
	var tr = plugin.scene_sync.current_tracker()
	var node_tint := {}
	var file_tint := {}
	for pid in s.presence:
		if int(pid) == s.my_pid:
			continue
		var p: Dictionary = s.presence[pid]
		var col: Color = s.peer_color(int(pid))
		if root != null and tr != null and String(p.get("scene", "")) == root.scene_file_path:
			for n in plugin.scene_sync.nodes_for_ids(tr, p.get("sel", [])):
				node_tint[str(n.get_path())] = col
		for k in ["scene", "script"]:
			var f := String(p.get(k, ""))
			if not f.is_empty():
				file_tint[f] = col
	if _scene_tree != null and is_instance_valid(_scene_tree) and not node_tint.is_empty():
		_tint_tree(_scene_tree, node_tint)
	if _fs_tree != null and is_instance_valid(_fs_tree) and not file_tint.is_empty():
		_tint_tree(_fs_tree, file_tint)


func _tint_tree(tree: Tree, tints: Dictionary) -> void:
	var item := tree.get_root()
	var guard := 0
	while item != null and guard < 20000:
		guard += 1
		var meta = item.get_metadata(0)
		var key := str(meta)
		if tints.has(key):
			item.set_custom_bg_color(0, Color(tints[key], 0.3))
			_decorated.append(item)
		item = item.get_next_in_tree()
