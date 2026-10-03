@tool
extends RefCounted
## Live script co-editing in Godot's script editor: everyone types in the same file at once,
## teammates' carets/selections are drawn in their colour, and Ctrl+Z / Ctrl+Y only undo/redo your
## own edits (we intercept them before the CodeEdit's built-in undo).

const Util := preload("res://addons/godot_coop/core/util.gd")
const OT := preload("res://addons/godot_coop/core/ot.gd")
const OTClient := preload("res://addons/godot_coop/core/ot_client.gd")
const Net := preload("res://addons/godot_coop/core/net.gd")

const CURSOR_SEND_MS := 120


class STracker:
	extends RefCounted
	var path := ""
	var code: CodeEdit = null
	var client = null
	var known := ""
	var ready := false
	var remote := {}            # pid -> {"sel": [[anchor, head], ...]}
	var overlay: Control = null
	var cursor_due := 0
	var last_sent_sel := []
	var flash := {}             # line -> until ms
	var warned := 0
	var seen_version := -1
	var cb_text: Callable
	var cb_caret: Callable
	var cb_input: Callable


var plugin
var trackers := {}              # res path -> STracker
var _editor_paths := {}         # ScriptEditorBase instance id -> res path
var _last_scan := 0


func _session():
	return plugin.session


func _online() -> bool:
	return plugin.session != null and plugin.session.is_online()


func setup(p) -> void:
	plugin = p
	var se := EditorInterface.get_script_editor()
	se.editor_script_changed.connect(_on_editor_script_changed)
	se.script_close.connect(_on_script_close)


func teardown() -> void:
	var se := EditorInterface.get_script_editor()
	if se.editor_script_changed.is_connected(_on_editor_script_changed):
		se.editor_script_changed.disconnect(_on_editor_script_changed)
		se.script_close.disconnect(_on_script_close)
	for path in trackers.keys():
		_drop(path, false)


func session_started() -> void:
	_scan_editors(true)


func session_resumed() -> void:
	for path in trackers:
		var tr: STracker = trackers[path]
		_flush_local(tr)
		var msg := {"t": "tx_open", "path": path}
		if tr.client != null and not tr.client.epoch.is_empty():
			msg["epoch"] = tr.client.epoch
			msg["rev"] = tr.client.rev
		tr.ready = false
		_session().send(msg, Net.CH_LIVE)


func is_open(path: String) -> bool:
	if trackers.has(path):
		return true
	for s in EditorInterface.get_script_editor().get_open_scripts():
		if s != null and s.resource_path == path:
			return true
	return false


func _on_editor_script_changed(script: Script) -> void:
	var ed := EditorInterface.get_script_editor().get_current_editor()
	if script != null and ed != null and _syncable(script):
		_editor_paths[ed.get_instance_id()] = script.resource_path
	_scan_editors(true)


func _on_script_close(script: Script) -> void:
	if script != null and trackers.has(script.resource_path):
		_drop(script.resource_path, true)


static func _syncable(script: Script) -> bool:
	var p := script.resource_path
	return p.begins_with("res://") and p.find("::") == -1 and (script is GDScript or p.get_extension() in ["gdshader", "gdshaderinc"])


## Matches script editor tabs to files and starts/stops live documents accordingly.
func _scan_editors(force := false) -> void:
	var now := Util.now_ms()
	if not force and now - _last_scan < 500:
		return
	_last_scan = now
	var se := EditorInterface.get_script_editor()
	var editors := se.get_open_script_editors()
	var scripts := se.get_open_scripts()
	# Tabs restored at startup were never "current": fall back to matching by position.
	if editors.size() == scripts.size():
		for i in editors.size():
			var ed = editors[i]
			if ed != null and scripts[i] != null and not _editor_paths.has(ed.get_instance_id()) and _syncable(scripts[i]):
				_editor_paths[ed.get_instance_id()] = scripts[i].resource_path
	var live := {}
	for ed in editors:
		if ed == null:
			continue
		var path := String(_editor_paths.get(ed.get_instance_id(), ""))
		if path.is_empty():
			continue
		var base = ed.get_base_editor()
		if not (base is CodeEdit):
			continue
		live[path] = base
	for path in trackers.keys():
		if not live.has(path) or trackers[path].code != live[path]:
			_drop(path, true)
	if not _online():
		return
	for path in live:
		if not trackers.has(path):
			_start(path, live[path])


func _start(path: String, code: CodeEdit) -> void:
	var tr := STracker.new()
	tr.path = path
	tr.code = code
	tr.known = code.text
	tr.client = OTClient.new()
	var me := tr
	tr.client.send_op.connect(func(rev: int, op, cseq: int):
		_session().send({"t": "tx_op", "path": me.path, "rev": rev, "op": op.to_array(), "cseq": cseq, "epoch": me.client.epoch}, Net.CH_LIVE))
	tr.cb_text = _on_text_changed.bind(tr)
	tr.cb_caret = _on_caret_changed.bind(tr)
	tr.cb_input = _on_code_input.bind(tr)
	code.text_changed.connect(tr.cb_text)
	code.caret_changed.connect(tr.cb_caret)
	code.gui_input.connect(tr.cb_input)
	var ov := Control.new()
	ov.name = "CoopCarets"
	ov.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ov.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ov.draw.connect(_draw_overlay.bind(tr))
	code.add_child(ov, false, Node.INTERNAL_MODE_BACK)
	code.draw.connect(ov.queue_redraw)
	tr.overlay = ov
	trackers[path] = tr
	_session().send({"t": "tx_open", "path": path}, Net.CH_LIVE)


func _drop(path: String, notify: bool) -> void:
	var tr: STracker = trackers.get(path)
	trackers.erase(path)
	if tr == null:
		return
	if is_instance_valid(tr.code):
		if tr.code.text_changed.is_connected(tr.cb_text):
			tr.code.text_changed.disconnect(tr.cb_text)
		if tr.code.caret_changed.is_connected(tr.cb_caret):
			tr.code.caret_changed.disconnect(tr.cb_caret)
		if tr.code.gui_input.is_connected(tr.cb_input):
			tr.code.gui_input.disconnect(tr.cb_input)
		if is_instance_valid(tr.overlay):
			if tr.code.draw.is_connected(tr.overlay.queue_redraw):
				tr.code.draw.disconnect(tr.overlay.queue_redraw)
			tr.overlay.queue_free()
		for line in tr.flash:
			if line < tr.code.get_line_count():
				tr.code.set_line_background_color(line, Color(0, 0, 0, 0))
	if notify and _online():
		_session().send({"t": "tx_close", "path": path}, Net.CH_LIVE)
	if _session() != null and _session().files != null:
		_session().files.flush_deferred(Util.res_to_rel(path))


# --- local edits ----------------------------------------------------------------------------------

func _on_text_changed(tr: STracker) -> void:
	_flush_local(tr)


## Turns whatever changed in the editor since we last looked into an operation.
func _flush_local(tr: STracker) -> void:
	if not tr.ready or not is_instance_valid(tr.code):
		return
	var v := tr.code.get_version()
	if v == tr.seen_version:
		return
	tr.seen_version = v
	var now_text := tr.code.text
	if now_text == tr.known:
		return
	var s = _session()
	var rel := Util.res_to_rel(tr.path)
	if not s.can_edit() or (s.role == "editor" and not _allowed(s, rel)):
		_set_text_keep_view(tr, tr.known)
		if Util.now_ms() - tr.warned > 4000:
			tr.warned = Util.now_ms()
			plugin.toast("You can't edit %s in this session (read-only)." % tr.path.get_file(), 1)
		return
	var before := tr.known
	var op := OT.diff(before, now_text)
	tr.known = now_text
	tr.client.apply_client(op, before)
	_transform_remote(tr, op)


static func _allowed(s, rel: String) -> bool:
	if s.paths.is_empty():
		return true
	for p in s.paths:
		var prefix := Util.res_to_rel(String(p)).trim_suffix("/")
		if prefix.is_empty() or rel == prefix or rel.begins_with(prefix + "/"):
			return true
	return false


func _on_caret_changed(tr: STracker) -> void:
	tr.cursor_due = Util.now_ms() + CURSOR_SEND_MS


func _on_code_input(event: InputEvent, tr: STracker) -> void:
	if not tr.ready or not (event is InputEventKey) or not event.pressed:
		return
	if event.is_action("ui_redo", true):
		tr.code.accept_event()
		_undo_redo(tr, false)
	elif event.is_action("ui_undo", true):
		tr.code.accept_event()
		_undo_redo(tr, true)


func _undo_redo(tr: STracker, undo: bool) -> void:
	_flush_local(tr)
	var op = tr.client.pop_undo() if undo else tr.client.pop_redo()
	if op == null:
		tr.client._undo_mode = 0
		return
	var before := tr.known
	var after = op.apply(before)
	if after == null:
		tr.client._undo_mode = 0
		return
	_apply_to_editor(tr, op, true)
	tr.client.finish_undo_redo(op, before)
	_transform_remote(tr, op)


# --- remote edits -----------------------------------------------------------------------------------

func on_message(m: Dictionary) -> void:
	var path := String(m.get("path", ""))
	var tr: STracker = trackers.get(path)
	if tr == null or not is_instance_valid(tr.code):
		return
	var me: int = _session().my_pid
	match String(m.get("t", "")):
		"tx_state":
			_on_state(tr, m)
		"tx_op":
			if not tr.ready:
				return
			_flush_local(tr)
			if int(m.get("by", 0)) == me and int(m.get("cseq", -1)) == tr.client.outstanding_cseq and tr.client.has_pending():
				tr.client.server_ack()
				return
			var op = OT.from_array(m.get("op"))
			if op == null:
				return
			var local_op = tr.client.apply_server(op)
			if local_op == null or local_op.base_length != tr.known.length():
				_resync(tr)
				return
			_apply_to_editor(tr, local_op, false)
			_transform_remote(tr, local_op)
			# Briefly highlight the line a teammate just changed.
			var by := int(m.get("by", 0))
			if by != me:
				var at := _first_change_offset(local_op)
				if at >= 0:
					_flash_line(tr, _offset_to_lc(tr.known, at).x, _session().peer_color(by))
		"tx_reject":
			_resync(tr)
		"tx_cursor":
			var by := int(m.get("by", 0))
			if by != me:
				tr.remote[by] = {"sel": m.get("sel", []), "moved": Util.now_ms()}
				if is_instance_valid(tr.overlay):
					tr.overlay.queue_redraw()


func _on_state(tr: STracker, m: Dictionary) -> void:
	var text := String(m.get("text", ""))
	var since = m.get("since")
	var epoch := String(m.get("epoch", ""))
	var me: int = _session().my_pid
	if since is Array and tr.client.epoch == epoch and int(m.get("from_rev", -1)) == tr.client.rev:
		# Reconnected to the same document: replay what we missed.
		tr.ready = true
		_flush_local(tr)
		for h in since:
			var author := String(h[1])
			if author == str(me) and int(h[2]) == tr.client.outstanding_cseq and tr.client.has_pending():
				tr.client.server_ack()
			else:
				var lop = tr.client.apply_server(OT.from_array(h[0]))
				if lop == null:
					_resync(tr)
					return
				_apply_to_editor(tr, lop, false)
		tr.client.resend()
		return
	tr.cursor_due = Util.now_ms() + 300
	tr.client.reset(int(m.get("rev", 0)), epoch)
	var local := tr.code.text
	var disk_path := ProjectSettings.globalize_path(tr.path)
	var disk := FileAccess.get_file_as_string(disk_path).replace("\r\n", "\n") if FileAccess.file_exists(disk_path) else ""
	tr.ready = true
	var unsaved := tr.code.get_version() != tr.code.get_saved_version()
	if local == text:
		tr.known = text
	elif unsaved and local != disk and text == disk:
		# We had unsaved edits before joining the live document: share them.
		tr.known = text
		var op := OT.diff(text, local)
		tr.known = local
		tr.client.apply_client(op, text)
	else:
		_set_text_keep_view(tr, text)
		tr.known = text
	tr.seen_version = -1


func _resync(tr: STracker) -> void:
	tr.ready = false
	tr.client.reset(0, "")
	_session().send({"t": "tx_open", "path": tr.path}, Net.CH_LIVE)


func _set_text_keep_view(tr: STracker, text: String) -> void:
	var line := tr.code.get_caret_line()
	var col := tr.code.get_caret_column()
	var scroll := tr.code.scroll_vertical
	tr.code.text = text
	tr.code.set_caret_line(mini(line, tr.code.get_line_count() - 1), false)
	tr.code.set_caret_column(col, false)
	tr.code.scroll_vertical = scroll
	tr.seen_version = tr.code.get_version()


## Applies `op` (relative to tr.known) to the CodeEdit with minimal edits, keeping carets in place.
func _apply_to_editor(tr: STracker, op, _local: bool) -> void:
	var old := tr.known
	var new_text = op.apply(old)
	if new_text == null:
		_resync(tr)
		return
	var edits := []
	var idx := 0
	for c in op.ops:
		if typeof(c) == TYPE_INT and c > 0:
			idx += c
		elif typeof(c) == TYPE_STRING:
			edits.append([idx, idx, c])
		else:
			if not edits.is_empty() and edits[-1][1] == idx and edits[-1][0] == idx:
				edits[-1][1] = idx - c
			else:
				edits.append([idx, idx - c, ""])
			idx -= c
	tr.code.begin_complex_operation()
	for i in range(edits.size() - 1, -1, -1):
		var e: Array = edits[i]
		var a := _offset_to_lc(old, e[0])
		if e[1] > e[0]:
			var b := _offset_to_lc(old, e[1])
			tr.code.remove_text(a.x, a.y, b.x, b.y)
		if not String(e[2]).is_empty():
			tr.code.insert_text(e[2], a.x, a.y, false, false)
	tr.code.end_complex_operation()
	tr.known = new_text
	if tr.code.text != new_text:
		_set_text_keep_view(tr, new_text)
	tr.seen_version = tr.code.get_version()


static func _offset_to_lc(text: String, off: int) -> Vector2i:
	off = clampi(off, 0, text.length())
	var line := text.count("\n", 0, off) if off > 0 else 0
	var start := text.rfind("\n", off - 1) + 1 if off > 0 else 0
	return Vector2i(line, off - start)


static func _lc_to_offset(text: String, line: int, col: int) -> int:
	var off := 0
	for i in line:
		var nl := text.find("\n", off)
		if nl == -1:
			return text.length()
		off = nl + 1
	var eol := text.find("\n", off)
	if eol == -1:
		eol = text.length()
	return mini(off + col, eol)


static func _first_change_offset(op) -> int:
	var idx := 0
	for c in op.ops:
		if typeof(c) == TYPE_INT and c > 0:
			idx += c
		else:
			return idx
	return -1


func _transform_remote(tr: STracker, op) -> void:
	for pid in tr.remote:
		var sel: Array = tr.remote[pid].sel
		tr.remote[pid]["moved"] = Util.now_ms()
		var out := []
		for s in sel:
			if s is Array and s.size() == 2:
				out.append([op.transform_index(int(s[0])), op.transform_index(int(s[1]))])
		tr.remote[pid].sel = out
	if is_instance_valid(tr.overlay):
		tr.overlay.queue_redraw()


func _flash_line(tr: STracker, line: int, color: Color) -> void:
	if line < 0 or line >= tr.code.get_line_count():
		return
	tr.code.set_line_background_color(line, Color(color, 0.22))
	tr.flash[line] = Util.now_ms() + 1200


## Jump to a script line (activity feed / pings) and flash it.
func flash_line(path: String, line: int, color: Color) -> void:
	var tr: STracker = trackers.get(path)
	if tr != null:
		_flash_line(tr, line, color)


# --- per-frame work: cursor broadcast, flash fade, editor discovery --------------------------------------

func process() -> void:
	_scan_editors()
	var now := Util.now_ms()
	for path in trackers:
		var tr: STracker = trackers[path]
		if not is_instance_valid(tr.code):
			continue
		if tr.ready:
			_flush_local(tr)
		if tr.cursor_due > 0 and now >= tr.cursor_due and tr.ready:
			tr.cursor_due = 0
			var sel := _local_selection(tr)
			if sel != tr.last_sent_sel:
				tr.last_sent_sel = sel
				_session().send({"t": "tx_cursor", "path": path, "sel": sel}, Net.CH_LIVE)
		for pid in tr.remote:
			var age: int = now - int(tr.remote[pid].get("moved", 0))
			if age < 3200 and is_instance_valid(tr.overlay):
				tr.overlay.queue_redraw()
		for line in tr.flash.keys():
			if now >= int(tr.flash[line]):
				tr.flash.erase(line)
				if line < tr.code.get_line_count():
					tr.code.set_line_background_color(line, Color(0, 0, 0, 0))


func _local_selection(tr: STracker) -> Array:
	var out := []
	for i in tr.code.get_caret_count():
		var head := _lc_to_offset(tr.known, tr.code.get_caret_line(i), tr.code.get_caret_column(i))
		var anchor := head
		if tr.code.has_selection(i):
			anchor = _lc_to_offset(tr.known, tr.code.get_selection_origin_line(i), tr.code.get_selection_origin_column(i))
		out.append([anchor, head])
	return out


func current_line() -> Array:
	var se := EditorInterface.get_script_editor()
	var s := se.get_current_script()
	if s == null:
		return ["", 0]
	var ed := se.get_current_editor()
	var line := 0
	if ed != null and ed.get_base_editor() is CodeEdit:
		line = ed.get_base_editor().get_caret_line()
	return [s.resource_path, line]


func _draw_overlay(tr: STracker) -> void:
	var ov := tr.overlay
	if not is_instance_valid(ov) or not is_instance_valid(tr.code):
		return
	var font := ov.get_theme_default_font()
	var fs := int(12 * EditorInterface.get_editor_scale())
	var lh := tr.code.get_line_height()
	var now := Util.now_ms()
	for pid in tr.remote:
		var show_name: bool = now - int(tr.remote[pid].get("moved", 0)) < 3000
		var col: Color = _session().peer_color(pid)
		var name: String = _session().peer_name(pid)
		for s in tr.remote[pid].sel:
			if not (s is Array) or s.size() != 2:
				continue
			var a := _offset_to_lc(tr.known, int(s[0]))
			var h := _offset_to_lc(tr.known, int(s[1]))
			if a != h:
				var from := a if a.x < h.x or (a.x == h.x and a.y < h.y) else h
				var to := h if from == a else a
				for line in range(from.x, to.x + 1):
					if not tr.code.is_line_in_viewport(line):
						continue
					var c0 := from.y if line == from.x else 0
					var c1 := to.y if line == to.x else tr.code.get_line(line).length()
					var r0 := tr.code.get_rect_at_line_column(line, c0)
					var r1 := tr.code.get_rect_at_line_column(line, c1)
					if r0.position.x < 0 or r1.position.x < 0:
						continue
					ov.draw_rect(Rect2(r0.position.x, r0.position.y, maxf(4.0, r1.position.x - r0.position.x), lh), Color(col, 0.22))
			var r := tr.code.get_rect_at_line_column(h.x, h.y)
			if r.position.x < 0 or r.position.y < 0:
				continue
			var x := float(r.position.x)
			ov.draw_rect(Rect2(x - 1, r.position.y, 2, lh), col)
			if not show_name:
				# After a moment the name collapses to a small flag so it doesn't hide code.
				ov.draw_rect(Rect2(x - 1, r.position.y - 3, 6, 4), col)
				continue
			var tw := font.get_string_size(name, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
			var tag := Rect2(x - 1, r.position.y - fs - 4, tw + 8, fs + 4)
			if tag.position.y < 0:
				tag.position.y = r.position.y + lh
			ov.draw_rect(tag, col)
			ov.draw_string(font, Vector2(tag.position.x + 4, tag.position.y + fs), name, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color.BLACK if col.get_luminance() > 0.6 else Color.WHITE)
