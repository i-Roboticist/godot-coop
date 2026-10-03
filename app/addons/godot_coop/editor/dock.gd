@tool
extends VBoxContainer
## The Co-op dock: host/join, invite codes, people, chat, activity feed, review queue and tools.

const Util := preload("res://addons/godot_coop/core/util.gd")
const Invite := preload("res://addons/godot_coop/core/invite.gd")
const Git := preload("res://addons/godot_coop/core/git.gd")

var plugin
var _built := false
var _scale := 1.0

var _status_dot: Label
var _status_text: Label
var _tabs: TabContainer
var _idle: VBoxContainer
var _hosting: VBoxContainer
var _joined: VBoxContainer
var _people: VBoxContainer
var _chat_log: RichTextLabel
var _chat_input: LineEdit
var _activity_log: RichTextLabel
var _review: VBoxContainer
var _tools: VBoxContainer

# idle widgets
var _name_edit: LineEdit
var _color_btn: ColorPickerButton
var _email_edit: LineEdit
var _join_edit: LineEdit
var _rejoin_btn: Button
var _idle_error: Label
var _relay_edit: LineEdit
var _relay_port: SpinBox
var _port_spin: SpinBox
var _upnp_check: CheckBox
var _web_edit: LineEdit
var _adv_box: VBoxContainer

# hosting widgets
var _host_title: Label
var _invite_role: OptionButton
var _invite_edit: LineEdit
var _short_label: Label
var _short_copy: Button
var _weblink_copy: Button
var _preparing: Label
var _conn_info: Label
var _auto_viewers: CheckBox
var _trust_host_cb: CheckBox

# joined widgets
var _join_title: Label
var _join_detail: Label
var _git_warn: Label
var _sync_progress: ProgressBar
var _trust_join_cb: CheckBox
var _leave_btn: Button

var _people_dirty := true
var _people_at := 0
var _activity_dirty := false
var _activity_at := 0
var _sync_done := 0
var _sync_total := 0
var _progress_connected = null


func _ready() -> void:
	if _built:
		return
	_built = true
	_scale = EditorInterface.get_editor_scale()
	custom_minimum_size = Vector2(260, 300) * _scale
	add_theme_constant_override("separation", int(4 * _scale))
	var head := HBoxContainer.new()
	add_child(head)
	_status_dot = Label.new()
	_status_dot.text = "●"
	head.add_child(_status_dot)
	_status_text = Label.new()
	_status_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status_text.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	head.add_child(_status_text)
	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(_tabs)
	_build_session_tab()
	_people = _scroll_tab("People")
	_build_chat_tab()
	_build_activity_tab()
	_review = _scroll_tab("Review")
	_tools = _scroll_tab("Tools")
	refresh()


# --- small UI helpers -----------------------------------------------------------------------------------

func _icon(name: String) -> Texture2D:
	return EditorInterface.get_editor_theme().get_icon(name, "EditorIcons")


func _scroll_tab(title: String) -> VBoxContainer:
	var sc := ScrollContainer.new()
	sc.name = title
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_tabs.add_child(sc)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", int(6 * _scale))
	sc.add_child(box)
	return box


func _header(parent: Control, text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.theme_type_variation = "HeaderSmall"
	parent.add_child(l)
	return l


func _note(parent: Control, text: String, color := Color(1, 1, 1, 0.6)) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_color_override("font_color", color)
	l.custom_minimum_size.x = 120 * _scale
	parent.add_child(l)
	return l


func _button(parent: Control, text: String, cb: Callable, icon := "") -> Button:
	var b := Button.new()
	b.text = text
	if not icon.is_empty():
		b.icon = _icon(icon)
	b.pressed.connect(cb)
	parent.add_child(b)
	return b


func _row(parent: Control) -> HBoxContainer:
	var h := HBoxContainer.new()
	parent.add_child(h)
	return h


func _sep(parent: Control) -> void:
	parent.add_child(HSeparator.new())


func _clear(box: Control) -> void:
	for c in box.get_children():
		box.remove_child(c)
		c.queue_free()


func _swatch(color: Color, size := 12.0) -> Control:
	var p := Panel.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = color
	sb.set_corner_radius_all(int(size))
	p.add_theme_stylebox_override("panel", sb)
	p.custom_minimum_size = Vector2(size, size) * _scale
	p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return p


static func _esc(s: String) -> String:
	return s.replace("[", "[lb]")


func _s():
	return plugin.session


func _online() -> bool:
	return plugin.session != null and plugin.session.is_online()


# --- Session tab -----------------------------------------------------------------------------------------

func _build_session_tab() -> void:
	var box := _scroll_tab("Session")
	_idle = VBoxContainer.new()
	_hosting = VBoxContainer.new()
	_joined = VBoxContainer.new()
	for b in [_idle, _hosting, _joined]:
		b.add_theme_constant_override("separation", int(6 * _scale))
		box.add_child(b)
	_build_idle()
	_build_hosting()
	_build_joined()


func _build_idle() -> void:
	var p: Dictionary = plugin.profile
	_header(_idle, "You")
	var r := _row(_idle)
	_color_btn = ColorPickerButton.new()
	_color_btn.color = Color.from_string(String(p.get("color", "4dabf7")), Color.SKY_BLUE)
	_color_btn.custom_minimum_size = Vector2(28, 28) * _scale
	_color_btn.edit_alpha = false
	_color_btn.color_changed.connect(_on_profile_color)
	r.add_child(_color_btn)
	_name_edit = LineEdit.new()
	_name_edit.text = String(p.get("name", ""))
	_name_edit.placeholder_text = "Your name"
	_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name_edit.text_changed.connect(_on_profile_text.bind("name"))
	r.add_child(_name_edit)
	_email_edit = LineEdit.new()
	_email_edit.text = String(p.get("email", ""))
	_email_edit.placeholder_text = "Email (optional, for git co-author credit)"
	_email_edit.text_changed.connect(_on_profile_text.bind("email"))
	_idle.add_child(_email_edit)
	_sep(_idle)
	_header(_idle, "Host this project")
	_note(_idle, "Teammates join with an invite code and edit this project with you, live.")
	_button(_idle, "Start hosting", func(): plugin.start_host(), "Play")
	var adv := CheckButton.new()
	adv.text = "Connection settings"
	_idle.add_child(adv)
	_adv_box = VBoxContainer.new()
	_adv_box.visible = false
	adv.toggled.connect(func(on): _adv_box.visible = on)
	_idle.add_child(_adv_box)
	var pr := _row(_adv_box)
	var pl := Label.new()
	pl.text = "UDP port"
	pl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pr.add_child(pl)
	_port_spin = SpinBox.new()
	_port_spin.min_value = 1024
	_port_spin.max_value = 65000
	_port_spin.value = int(plugin.prefs.port)
	_port_spin.value_changed.connect(_set_pref.bind("port"))
	pr.add_child(_port_spin)
	_upnp_check = CheckBox.new()
	_upnp_check.text = "Open the port on my router automatically (UPnP)"
	_upnp_check.button_pressed = bool(plugin.prefs.use_upnp)
	_upnp_check.toggled.connect(_set_pref.bind("use_upnp"))
	_adv_box.add_child(_upnp_check)
	_note(_adv_box, "Relay server (optional): lets people connect through any firewall and enables short codes. Run one with: GodotCoop.exe --headless -- --relay")
	var rr := _row(_adv_box)
	_relay_edit = LineEdit.new()
	_relay_edit.placeholder_text = "relay host (e.g. relay.example.com)"
	_relay_edit.text = String(plugin.prefs.relay_host)
	_relay_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_relay_edit.text_changed.connect(_set_pref.bind("relay_host"))
	rr.add_child(_relay_edit)
	_relay_port = SpinBox.new()
	_relay_port.min_value = 1
	_relay_port.max_value = 65000
	_relay_port.value = int(plugin.prefs.relay_port)
	_relay_port.value_changed.connect(_set_pref.bind("relay_port"))
	rr.add_child(_relay_port)
	_web_edit = LineEdit.new()
	_web_edit.placeholder_text = "Invite web page URL (optional, e.g. https://you.github.io/coop/join/)"
	_web_edit.text = String(plugin.prefs.web_link_base)
	_web_edit.text_changed.connect(_set_pref.bind("web_link_base"))
	_adv_box.add_child(_web_edit)
	_sep(_idle)
	_header(_idle, "Join a session")
	var jr := _row(_idle)
	_join_edit = LineEdit.new()
	_join_edit.placeholder_text = "Paste invite code or link"
	_join_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_join_edit.text_submitted.connect(_do_join.unbind(1))
	jr.add_child(_join_edit)
	_button(jr, "Join", _do_join)
	_note(_idle, "Joining makes this folder match the host's project. Files you changed that the host also changed are backed up to .coop/conflicts/. Tip: the Godot Co-op app can download a project you don't have yet.")
	_rejoin_btn = _button(_idle, "Rejoin last session", _do_rejoin, "Reload")
	_idle_error = _note(_idle, "", Color(1, 0.45, 0.45))


func _on_profile_color(c: Color) -> void:
	plugin.profile.color = c.to_html(false)
	plugin.save_profile()


func _on_profile_text(t: String, key: String) -> void:
	plugin.profile[key] = t.strip_edges()
	plugin.save_profile()


func _set_pref(value, key: String) -> void:
	if typeof(value) == TYPE_FLOAT:
		value = int(value)
	elif typeof(value) == TYPE_STRING:
		value = String(value).strip_edges()
	plugin.prefs[key] = value
	plugin.save_prefs()
	if key == "auto_accept_viewers" and _s() != null:
		_s().settings.auto_accept_viewers = value


func _do_join() -> void:
	var code := _join_edit.text.strip_edges()
	if code.is_empty():
		return
	if not Invite.is_short_code(code) and Invite.decode(code).is_empty():
		_idle_error.text = "That doesn't look like an invite code."
		return
	_idle_error.text = ""
	plugin.join(code)


func _do_rejoin() -> void:
	var last: Dictionary = Util.read_json(plugin.project_dir.path_join(".coop/last_session.json"), {})
	if last.has("invite"):
		plugin.join(String(last.invite), String(last.get("token", "")))


func _build_hosting() -> void:
	_host_title = _header(_hosting, "Hosting")
	_preparing = _note(_hosting, "Preparing invite… (checking your router and relay)")
	var ir := _row(_hosting)
	var il := Label.new()
	il.text = "Invite for"
	ir.add_child(il)
	_invite_role = OptionButton.new()
	_invite_role.add_item("Editors", 0)
	_invite_role.add_item("Viewers (read-only)", 1)
	_invite_role.item_selected.connect(func(_i): refresh())
	ir.add_child(_invite_role)
	_invite_edit = LineEdit.new()
	_invite_edit.editable = false
	_invite_edit.secret = false
	_hosting.add_child(_invite_edit)
	var cr := _row(_hosting)
	_button(cr, "Copy code", func(): _copy(_invite_edit.text, "Invite code copied. Send it to your teammate."), "ActionCopy")
	_button(cr, "Copy link", func(): _copy(Invite.link(_invite_edit.text), "Invite link copied."), "ExternalLink")
	_weblink_copy = _button(cr, "Copy web link", func(): _copy(Invite.web_link(String(plugin.prefs.web_link_base), _invite_edit.text), "Web link copied."))
	var sr := _row(_hosting)
	_short_label = Label.new()
	_short_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sr.add_child(_short_label)
	_short_copy = _button(sr, "Copy", func(): _copy(_short_label.get_meta("code", ""), "Short code copied."), "ActionCopy")
	_conn_info = _note(_hosting, "")
	_auto_viewers = CheckBox.new()
	_auto_viewers.text = "Let viewers in without asking"
	_auto_viewers.toggled.connect(_set_pref.bind("auto_accept_viewers"))
	_hosting.add_child(_auto_viewers)
	_trust_host_cb = CheckBox.new()
	_trust_host_cb.text = "Trust teammates' editor scripts (skip review)"
	_trust_host_cb.tooltip_text = "@tool scripts, plugins and native libraries run inside the editor as soon as they load. Leave this off unless you trust everyone in the session."
	_trust_host_cb.toggled.connect(func(on): plugin.set_trust(on))
	_hosting.add_child(_trust_host_cb)
	var br := _row(_hosting)
	_button(br, "New codes", _new_codes, "Reload")
	_button(br, "End session", _confirm_end, "Stop")


func _build_joined() -> void:
	_join_title = _header(_joined, "")
	_join_detail = _note(_joined, "")
	_sync_progress = ProgressBar.new()
	_sync_progress.custom_minimum_size.y = 16 * _scale
	_joined.add_child(_sync_progress)
	_git_warn = _note(_joined, "", Color(1, 0.8, 0.3))
	_trust_join_cb = CheckBox.new()
	_trust_join_cb.text = "Trust the host's editor scripts (skip review)"
	_trust_join_cb.tooltip_text = "@tool scripts, plugins and native libraries run inside the editor as soon as they load. Leave this off unless you trust the host."
	_trust_join_cb.toggled.connect(func(on): plugin.set_trust(on))
	_joined.add_child(_trust_join_cb)
	_leave_btn = _button(_joined, "Leave session", func(): plugin.leave(), "Close")


func _new_codes() -> void:
	_s().regenerate_invites()
	plugin.toast("Old invite codes no longer work for new people (people already here stay).", 0)


func _copy(text: String, msg: String) -> void:
	if text.is_empty():
		return
	DisplayServer.clipboard_set(text)
	plugin.toast(msg, 0)


func _confirm_end() -> void:
	var s = _s()
	var gi := Git.info(plugin.project_dir)
	if gi.get("ok", false) and gi.get("dirty", false):
		var d := ConfirmationDialog.new()
		d.title = "End session"
		d.dialog_text = "The project has uncommitted changes from this session.\nCommit them (with everyone as co-authors) before ending?"
		d.ok_button_text = "Commit & end"
		d.add_button("End without committing", true, "end")
		d.confirmed.connect(_commit_dialog.bind(true))
		d.custom_action.connect(_end_without_commit.bind(d))
		_popup(d)
	else:
		plugin.leave()


func _end_without_commit(_action, d: Window) -> void:
	d.hide()
	plugin.leave()


func _popup(d: Window) -> void:
	d.visibility_changed.connect(_free_if_hidden.bind(d))
	EditorInterface.popup_dialog_centered(d)


func _free_if_hidden(d: Window) -> void:
	if is_instance_valid(d) and not d.visible:
		d.queue_free()


# --- refresh ---------------------------------------------------------------------------------------------

func refresh() -> void:
	if not _built:
		return
	var s = _s()
	var state: String = s.state if s != null else "idle"
	var col := Color(0.6, 0.6, 0.6)
	var text := "Not in a session"
	match state:
		"hosting":
			col = Color(0.32, 0.81, 0.4)
			var n := 0
			for pid in s.roster:
				if s.roster[pid].online:
					n += 1
			text = "Hosting · %d %s" % [n, "person" if n == 1 else "people"]
		"connected":
			col = Color(0.32, 0.81, 0.4)
			text = "In %s's session" % s.host_info.get("host_name", "?")
		"connecting", "waiting_approval", "reconnecting":
			col = Color(1, 0.75, 0.25)
			text = s.state_detail if not s.state_detail.is_empty() else state.capitalize()
		"failed":
			col = Color(1, 0.4, 0.4)
			text = "Couldn't connect"
		"ended", "ending":
			text = "Session ended"
	_status_dot.add_theme_color_override("font_color", col)
	_status_text.text = text
	_status_text.tooltip_text = text
	var in_session: bool = state in ["hosting", "connected", "connecting", "waiting_approval", "reconnecting"]
	_idle.visible = not in_session
	_hosting.visible = state == "hosting"
	_joined.visible = in_session and state != "hosting"
	if _idle.visible:
		var last: Dictionary = Util.read_json(plugin.project_dir.path_join(".coop/last_session.json"), {})
		_rejoin_btn.visible = not String(last.get("token", "")).is_empty()
		_rejoin_btn.text = "Rejoin %s" % last.get("project", "last session") if last.get("project", "") != "" else "Rejoin last session"
		_idle_error.text = s.state_detail if s != null and state == "failed" else ""
	if _hosting.visible:
		_refresh_hosting(s)
	if _joined.visible:
		_refresh_joined(s)
	_people_dirty = true
	_refresh_review()
	_refresh_tools()
	if plugin.toolbar != null:
		plugin.toolbar.call("update_from", plugin)


func _refresh_hosting(s) -> void:
	_host_title.text = "Hosting %s" % s.host_info.get("project", "")
	_preparing.visible = not s.invites_ready
	var r := "viewer" if _invite_role.selected == 1 else "editor"
	var inv: Dictionary = s.get_invite(r)
	_invite_edit.text = String(inv.get("code", "")) if s.invites_ready else ""
	var short := String(s.get_invite("editor").get("short", ""))
	_short_label.visible = not short.is_empty() and r == "editor"
	_short_copy.visible = _short_label.visible
	if not short.is_empty():
		_short_label.text = "Short code: " + Invite.pretty_short_code(short)
		_short_label.set_meta("code", Invite.pretty_short_code(short))
	_weblink_copy.visible = not String(plugin.prefs.web_link_base).is_empty()
	_conn_info.text = "Reachable via: %s\n%s\n%s" % [s.connection_summary(), s.upnp_status, s.relay_status]
	_auto_viewers.set_pressed_no_signal(bool(s.settings.auto_accept_viewers))
	_trust_host_cb.set_pressed_no_signal(plugin.trust_host)


func _refresh_joined(s) -> void:
	var host_name := String(s.host_info.get("host_name", "the host"))
	match s.state:
		"connected":
			_join_title.text = "In %s's session" % host_name
			var rtt := -1
			if s._conn != null:
				rtt = s.net.link_rtt(s._conn.link)
			_join_detail.text = "%s · via %s%s · you're %s%s" % [s.host_info.get("project", ""), s.connection_kind,
				(" (%d ms)" % rtt) if rtt >= 0 else "", "a viewer (read-only)" if s.role == "viewer" else "an editor",
				(" in " + ", ".join(s.paths)) if not s.paths.is_empty() else ""]
		"waiting_approval":
			_join_title.text = "Waiting for the host…"
			_join_detail.text = "The host has to let you in."
		"reconnecting":
			_join_title.text = "Reconnecting…"
			_join_detail.text = s.state_detail
		_:
			_join_title.text = "Connecting…"
			_join_detail.text = s.state_detail
	_leave_btn.text = "Leave session" if s.state == "connected" else "Cancel"
	_git_warn.text = plugin.git_warning
	_git_warn.visible = not plugin.git_warning.is_empty()
	_trust_join_cb.set_pressed_no_signal(plugin.trust_host)
	var f = s.files
	if f != null and _progress_connected != f:
		_progress_connected = f
		f.progress.connect(_on_progress)
	_sync_progress.visible = f != null and f.is_syncing()
	if _sync_progress.visible:
		_sync_progress.max_value = maxi(1, _sync_total)
		_sync_progress.value = _sync_done


func _on_progress(done: int, total: int, _cur: String) -> void:
	_sync_done = done
	_sync_total = total


func process() -> void:
	if not _built:
		return
	var now := Util.now_ms()
	if _sync_progress.visible:
		_sync_progress.max_value = maxi(1, _sync_total)
		_sync_progress.value = _sync_done
		if _s() != null and _s().files != null and not _s().files.is_syncing():
			refresh()
	if _people_dirty and now - _people_at > 300 and _tabs.current_tab == 1:
		_people_at = now
		_people_dirty = false
		_refresh_people()
	if _activity_dirty and now - _activity_at > 250:
		_activity_at = now
		_activity_dirty = false
		_rebuild_activity()


func mark_people_dirty() -> void:
	_people_dirty = true


# --- People ---------------------------------------------------------------------------------------------

func _refresh_people() -> void:
	_clear(_people)
	var s = _s()
	if s == null or not (s.state in ["hosting", "connected"]):
		_note(_people, "Start or join a session to see who's here.")
		return
	var ids: Array = s.roster.keys()
	ids.sort()
	for pid in ids:
		var r: Dictionary = s.roster[pid]
		var panel := PanelContainer.new()
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(Util.color_of(r), 0.08)
		sb.border_color = Color(Util.color_of(r), 0.5)
		sb.border_width_left = int(3 * _scale)
		sb.set_content_margin_all(6 * _scale)
		sb.set_corner_radius_all(int(4 * _scale))
		panel.add_theme_stylebox_override("panel", sb)
		_people.add_child(panel)
		var v := VBoxContainer.new()
		panel.add_child(v)
		var top := HBoxContainer.new()
		v.add_child(top)
		top.add_child(_swatch(Util.color_of(r) if r.online else Color(0.4, 0.4, 0.4)))
		var nl := Label.new()
		nl.text = String(r.name) + (" (you)" if int(pid) == s.my_pid else "")
		nl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		nl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		top.add_child(nl)
		var role := Label.new()
		var rt: String = {"owner": "Host", "editor": "Editor", "viewer": "Viewer"}.get(r.role, String(r.role))
		if not Array(r.get("paths", [])).is_empty():
			rt += " (limited)"
			role.tooltip_text = "Can edit: " + ", ".join(PackedStringArray(r.paths))
		role.text = rt
		role.add_theme_color_override("font_color", Color(1, 1, 1, 0.55))
		top.add_child(role)
		var where := Label.new()
		var loc: String = plugin.presence.describe(int(pid)) if r.online else "Offline (can reconnect)"
		if r.get("mode", "editor") == "download":
			loc = "Downloading the project…"
		where.text = loc + ("" if r.via in ["local", ""] else "  ·  " + String(r.via))
		where.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
		where.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		v.add_child(where)
		if int(pid) == s.my_pid or not r.online:
			continue
		var br := HBoxContainer.new()
		v.add_child(br)
		var following: bool = plugin.presence.following == int(pid)
		var fb := _button(br, "Stop following" if following else "Follow", func(): plugin.presence.follow(int(pid)), "GuiVisibilityVisible")
		fb.toggle_mode = true
		fb.set_pressed_no_signal(following)
		_button(br, "Go to", _goto_peer.bind(int(pid)), "ArrowRight")
		if s.is_host:
			var mb := MenuButton.new()
			mb.text = "Manage"
			mb.flat = false
			var pm := mb.get_popup()
			pm.add_item("Make editor", 0)
			pm.add_item("Make viewer (read-only)", 1)
			pm.add_item("Limit to folders…", 2)
			pm.add_separator()
			pm.add_item("Remove from session", 3)
			pm.id_pressed.connect(_manage.bind(int(pid)))
			br.add_child(mb)


func _goto_peer(pid: int) -> void:
	var p: Dictionary = _s().presence.get(pid, {})
	if String(p.get("screen", "")) == "Script":
		plugin.presence.jump({"kind": "line", "script": p.get("script", ""), "line": p.get("line", 0)})
	else:
		plugin.presence.jump({"kind": "node", "scene": p.get("scene", ""), "ids": p.get("sel", [])})


func _manage(action: int, pid: int) -> void:
	var s = _s()
	match action:
		0:
			s.set_peer_role(pid, "editor", [])
		1:
			s.set_peer_role(pid, "viewer", [])
		2:
			var d := ConfirmationDialog.new()
			d.title = "Limit %s to folders" % s.peer_name(pid)
			var v := VBoxContainer.new()
			var l := Label.new()
			l.text = "Comma-separated folders they may change (e.g. res://art, res://audio):"
			v.add_child(l)
			var e := LineEdit.new()
			e.text = ", ".join(PackedStringArray(s.roster.get(pid, {}).get("paths", [])))
			e.custom_minimum_size.x = 360 * _scale
			v.add_child(e)
			d.add_child(v)
			d.confirmed.connect(_apply_folder_limit.bind(pid, e))
			_popup(d)
		3:
			s.kick(pid)
	refresh()


func _apply_folder_limit(pid: int, e: LineEdit) -> void:
	var paths := []
	for part in e.text.split(","):
		var p := part.strip_edges()
		if not p.is_empty():
			paths.append(p if p.begins_with("res://") else "res://" + p.trim_prefix("/"))
	_s().set_peer_role(pid, "editor", paths)
	refresh()


# --- Chat -----------------------------------------------------------------------------------------------

func _build_chat_tab() -> void:
	var v := VBoxContainer.new()
	v.name = "Chat"
	_tabs.add_child(v)
	_chat_log = RichTextLabel.new()
	_chat_log.bbcode_enabled = true
	_chat_log.scroll_following = true
	_chat_log.selection_enabled = true
	_chat_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(_chat_log)
	_chat_input = LineEdit.new()
	_chat_input.placeholder_text = "Message everyone…"
	_chat_input.text_submitted.connect(_send_chat)
	v.add_child(_chat_input)


func _send_chat(t: String) -> void:
	if t.strip_edges().is_empty() or _s() == null:
		return
	_s().send({"t": "chat", "text": t})
	_chat_input.clear()


func on_chat(e: Dictionary) -> void:
	if not _built:
		return
	_chat_log.append_text("[color=#888]%s[/color] [color=#%s][b]%s[/b][/color]  %s\n" % [
		Util.clock_string(float(e.get("ts", 0))), String(e.get("color", "ffffff")), _esc(String(e.get("name", "?"))), _esc(String(e.get("text", "")))])
	if _tabs.current_tab != 2:
		_tabs.set_tab_title(2, "Chat •")


# --- Activity ---------------------------------------------------------------------------------------------

func _build_activity_tab() -> void:
	_activity_log = RichTextLabel.new()
	_activity_log.name = "Activity"
	_activity_log.bbcode_enabled = true
	_activity_log.scroll_following = true
	_activity_log.meta_underlined = false
	_activity_log.meta_clicked.connect(_on_activity_link)
	_tabs.add_child(_activity_log)
	_tabs.tab_changed.connect(_on_tab_changed)


func _on_tab_changed(i: int) -> void:
	if i == 2:
		_tabs.set_tab_title(2, "Chat")
	if i == 1:
		_people_dirty = true


func on_activity(_e: Dictionary, _replaced: bool) -> void:
	_activity_dirty = true


func _rebuild_activity() -> void:
	var s = _s()
	if s == null:
		return
	_activity_log.clear()
	var i := 0
	for e in s.activity_log:
		var link: Dictionary = e.get("link", {})
		var text := _esc(String(e.get("text", "")))
		if not link.is_empty():
			text = "[url=%d]%s[/url]" % [i, text]
		_activity_log.append_text("[color=#888]%s[/color] [color=#%s]%s[/color] %s\n" % [Util.clock_string(float(e.get("ts", 0))), String(e.get("color", "ffffff")), _esc(String(e.get("name", "?"))), text])
		i += 1


func _on_activity_link(meta) -> void:
	var s = _s()
	var i := int(str(meta))
	if s == null or i < 0 or i >= s.activity_log.size():
		return
	var link: Dictionary = s.activity_log[i].get("link", {})
	var m := link.duplicate()
	if String(link.get("type", "")) == "node":
		m["kind"] = "node"
		m["scene"] = link.get("path", "")
		m["ids"] = [link.get("id", "")]
	plugin.presence.jump(m)


# --- Review ---------------------------------------------------------------------------------------------

func _refresh_review() -> void:
	_clear(_review)
	var s = _s()
	var count := 0
	if s != null and s.is_host:
		var reqs: Array = s.pending_requests()
		if not reqs.is_empty():
			_header(_review, "Join requests")
			for req in reqs:
				count += 1
				_join_request_row(_review, req)
	if not plugin.lock_requests.is_empty():
		_header(_review, "Control requests")
		for lr in plugin.lock_requests.duplicate():
			count += 1
			var row := _row(_review)
			var l := Label.new()
			l.text = "%s wants to edit %s" % [s.peer_name(int(lr.from)), String(lr.path).get_file()] if s != null else ""
			l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(l)
			_button(row, "Give", _give_lock.bind(lr, true))
			_button(row, "Ignore", _give_lock.bind(lr, false))
	if s != null and s.files != null and not s.files.quarantine.is_empty():
		_header(_review, "Files that can run code (held for review)")
		for rel in s.files.quarantine:
			count += 1
			var q: Dictionary = s.files.quarantine[rel]
			var v := VBoxContainer.new()
			_review.add_child(v)
			var l := Label.new()
			l.text = "%s: %s (from %s)" % [rel, q.reason, s.peer_name(int(q.by))]
			l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			l.custom_minimum_size.x = 120 * _scale
			v.add_child(l)
			var row := _row(v)
			var r: String = rel
			_button(row, "View", func(): _view_text(r, s.files.quarantined_text(r)), "Search")
			_button(row, "Accept", _review_file.bind(r, true), "ImportCheck")
			_button(row, "Reject", _review_file.bind(r, false), "Close")
	if not plugin.settings_sync.held.is_empty():
		_header(_review, "Project setting changes that can run code")
		for i in plugin.settings_sync.held.size():
			count += 1
			var h: Dictionary = plugin.settings_sync.held[i]
			var keys: Array = h["set"].keys() + h["erase"]
			_note(_review, "%s changed: %s" % [s.peer_name(int(h.by)) if s != null else "?", ", ".join(PackedStringArray(keys))])
			var row := _row(_review)
			var idx: int = i
			_button(row, "Apply", func(): plugin.settings_sync.accept_held(idx))
			_button(row, "Ignore", func(): plugin.settings_sync.reject_held(idx))
	if s != null and s.files != null and not s.files.deferred.is_empty():
		_header(_review, "Waiting for you to close")
		var names := PackedStringArray()
		for rel in s.files.deferred:
			names.append(String(rel).get_file())
		_note(_review, "Newer saved versions of %s arrived while you had them open. Your open copy is already live-synced; the saved file updates when you close it." % ", ".join(names))
	if not plugin.notifications.is_empty():
		_header(_review, "Recent")
		for n in plugin.notifications.slice(0, 8):
			var row := _row(_review)
			row.add_child(_swatch(n.color, 8.0))
			var l := Label.new()
			l.text = "%s  %s" % [Util.clock_string(float(n.ts)), n.text]
			l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			l.tooltip_text = n.text
			row.add_child(l)
			var j: Callable = n.jump
			if j.is_valid():
				_button(row, "Jump", j)
	if _review.get_child_count() == 0:
		_note(_review, "Nothing to review.")
	_tabs.set_tab_title(4, "Review (%d)" % count if count > 0 else "Review")


func _give_lock(lr: Dictionary, give: bool) -> void:
	if give:
		_s().send({"t": "lock_give", "path": lr.path, "to": int(lr.from)}, 1)
	plugin.lock_requests.erase(lr)
	refresh()


func _review_file(rel: String, accept: bool) -> void:
	if accept:
		_s().files.accept_quarantined(rel)
	else:
		_s().files.reject_quarantined(rel)
	refresh()


func _decide(req_id: String, decision: String) -> void:
	if decision == "deny":
		_s().deny(req_id)
	else:
		_s().approve(req_id, decision)
	refresh()


func _join_request_row(parent: Control, req: Dictionary) -> void:
	var s = _s()
	var v := VBoxContainer.new()
	parent.add_child(v)
	var top := _row(v)
	top.add_child(_swatch(Color.from_string(String(req.get("color", "ffffff")), Color.WHITE)))
	var l := Label.new()
	l.text = "%s wants to %s (Godot %s, %s)" % [req.name, "download the project" if req.mode == "download" else "join", req.godot, req.via]
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.custom_minimum_size.x = 100 * _scale
	top.add_child(l)
	var row := _row(v)
	_button(row, "Let in", _decide.bind(req.id, "editor"), "ImportCheck")
	_button(row, "As viewer", _decide.bind(req.id, "viewer"), "GuiVisibilityVisible")
	_button(row, "Deny", _decide.bind(req.id, "deny"), "Close")


func show_join_request(req: Dictionary) -> void:
	var s = _s()
	var d := AcceptDialog.new()
	d.title = "Godot Co-op: someone wants to join"
	d.dialog_text = "%s wants to %s.\nGodot %s · connected via %s · invite for %ss" % [req.name, "download the project" if req.mode == "download" else "join your session", req.godot, req.via, req.role]
	d.ok_button_text = "Let in as editor"
	d.add_button("Let in as viewer", false, "viewer")
	d.add_button("Deny", true, "deny")
	d.confirmed.connect(_decide.bind(req.id, "editor"))
	d.custom_action.connect(_on_join_dialog_action.bind(req.id, d))
	_popup(d)


func _on_join_dialog_action(action: StringName, req_id: String, d: Window) -> void:
	_decide(req_id, "viewer" if action == &"viewer" else "deny")
	d.hide()


func show_version_help(m: Dictionary) -> void:
	var d := AcceptDialog.new()
	d.title = "Different Godot version"
	d.dialog_text = "%s\n\nEveryone in a session must use exactly the same Godot version, or scene files can break.\nThe Godot Co-op app downloads the right version automatically, or get it from the Godot archive." % m.get("reason", "")
	d.add_button("Open Godot download archive", true, "open")
	d.custom_action.connect(func(_a): OS.shell_open("https://godotengine.org/download/archive/"))
	_popup(d)


func _view_text(title: String, text: String) -> void:
	var d := AcceptDialog.new()
	d.title = "Review: " + title
	var ce := CodeEdit.new()
	ce.text = text
	ce.editable = false
	ce.custom_minimum_size = Vector2(640, 420) * _scale
	d.add_child(ce)
	_popup(d)


# --- Tools ---------------------------------------------------------------------------------------------

func _refresh_tools() -> void:
	_clear(_tools)
	var s = _s()
	if s == null or not (s.state in ["hosting", "connected"]):
		_note(_tools, "Tools appear once you're in a session.")
		return
	_header(_tools, "Playtest together")
	var pr := _row(_tools)
	_button(pr, "Play for everyone", func(): plugin.playtest.play_for_everyone(""), "Play")
	_button(pr, "Stop all", func(): plugin.playtest.stop_for_everyone(), "Stop")
	var root := EditorInterface.get_edited_scene_root()
	if root != null and not root.scene_file_path.is_empty():
		var path := root.scene_file_path
		_button(_tools, "Play %s for everyone" % path.get_file(), func(): plugin.playtest.play_for_everyone(path), "PlayScene")
	var ac := CheckBox.new()
	ac.text = "Auto-connect multiplayer games"
	ac.tooltip_text = "Host's game runs as server, everyone else's connects to it through the co-op tunnel.\nIn your game: preload(\"res://addons/godot_coop/runtime/coop_playtest.gd\").create_peer()"
	ac.button_pressed = plugin.playtest.auto_connect
	ac.toggled.connect(func(on): plugin.playtest.auto_connect = on)
	_tools.add_child(ac)
	if not s.can_edit():
		_note(_tools, "Viewers can't start playtests.")
	_sep(_tools)
	_header(_tools, "This scene")
	var tr = plugin.scene_sync.current_tracker()
	if tr == null:
		_note(_tools, "Open a saved scene to lock it or resync it.")
	else:
		var holder: int = tr.lock_holder
		if holder == 0:
			_note(_tools, "%s: anyone can edit, live." % tr.path.get_file())
			if s.can_edit():
				_button(_tools, "Lock it for just me", func(): s.send({"t": "lock", "path": tr.path, "on": true}, 1), "Lock")
		elif holder == s.my_pid:
			_note(_tools, "You have %s locked. Others watch live." % tr.path.get_file())
			_button(_tools, "Unlock", func(): s.send({"t": "lock", "path": tr.path, "on": false}, 1), "Unlock")
		else:
			_note(_tools, "%s has %s locked." % [s.peer_name(holder), tr.path.get_file()])
			_button(_tools, "Request control", _request_control.bind(tr.path, holder), "Lock")
			if s.is_host:
				_button(_tools, "Force unlock (host)", func(): s.send({"t": "lock", "path": tr.path, "on": false}, 1), "Unlock")
		var row := _row(_tools)
		_button(row, "Ping selection", func(): plugin.presence.ping_nodes(EditorInterface.get_selection().get_selected_nodes()), "Signals")
		_button(row, "Resync scene", func(): s.send({"t": "sc_get", "path": tr.path}, 1), "Reload")
	_sep(_tools)
	_header(_tools, "Git")
	var gi := Git.info(plugin.project_dir)
	if not gi.get("ok", false):
		_note(_tools, "This project isn't a git repository (or git isn't installed).")
	else:
		_note(_tools, "%s @ %s%s" % [gi.branch, String(gi.head).substr(0, 8), " · uncommitted changes" if gi.dirty else " · clean"])
		if s.is_host and gi.dirty:
			_button(_tools, "Commit session (with co-authors)…", func(): _commit_dialog(false), "Save")
	if not plugin.git_warning.is_empty():
		_note(_tools, plugin.git_warning, Color(1, 0.8, 0.3))
	_sep(_tools)
	_header(_tools, "Connection")
	var f = s.files
	if f != null:
		_note(_tools, "Sent %s · received %s" % [Util.human_bytes(int(f.stats.sent)), Util.human_bytes(int(f.stats.received))])


func _request_control(path: String, holder: int) -> void:
	_s().send({"t": "lock_req", "path": path}, 1)
	plugin.toast("Asked %s for control." % _s().peer_name(holder), 0)


func _commit_dialog(end_after: bool) -> void:
	var s = _s()
	var d := ConfirmationDialog.new()
	d.title = "Commit session"
	d.ok_button_text = "Commit & end session" if end_after else "Commit"
	var v := VBoxContainer.new()
	var te := TextEdit.new()
	te.text = "Co-op session: %s" % Time.get_date_string_from_system()
	te.custom_minimum_size = Vector2(460, 90) * _scale
	v.add_child(te)
	var co: Array = s.contributors()
	var names := PackedStringArray()
	for c in co:
		names.append("%s <%s>" % [c.name, c.email])
	var l := Label.new()
	l.text = "Co-authors: " + (", ".join(names) if not names.is_empty() else "(no one else changed files)")
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size.x = 460 * _scale
	v.add_child(l)
	d.add_child(v)
	d.confirmed.connect(_do_commit.bind(te, co, end_after))
	_popup(d)


func _do_commit(te: TextEdit, co: Array, end_after: bool) -> void:
	var res := Git.commit_all(plugin.project_dir, te.text, co)
	plugin.toast("Committed." if res.ok else "Commit failed: " + String(res.out), 0 if res.ok else 2)
	if end_after:
		plugin.leave()
	refresh()


# --- toolbar --------------------------------------------------------------------------------------------

class Toolbar:
	extends HBoxContainer
	var plugin_ref

	func update_from(p) -> void:
		plugin_ref = p
		for c in get_children():
			remove_child(c)
			c.queue_free()
		var s = p.session
		if s == null or not (s.state in ["hosting", "connected", "reconnecting"]):
			visible = false
			return
		visible = true
		var k := EditorInterface.get_editor_scale()
		var ids: Array = s.roster.keys()
		ids.sort()
		var shown := 0
		for pid in ids:
			var r: Dictionary = s.roster[pid]
			if not r.online or shown >= 6:
				continue
			shown += 1
			var l := Label.new()
			l.text = String(r.name).substr(0, 1).to_upper()
			l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			l.custom_minimum_size = Vector2(22, 22) * k
			var sb := StyleBoxFlat.new()
			sb.bg_color = Color.from_string(String(r.color), Color.WHITE)
			sb.set_corner_radius_all(int(11 * k))
			l.add_theme_stylebox_override("normal", sb)
			l.add_theme_color_override("font_color", Color.BLACK if sb.bg_color.get_luminance() > 0.6 else Color.WHITE)
			l.tooltip_text = "%s · %s%s" % [r.name, r.role, " · you" if int(pid) == s.my_pid else ""]
			l.mouse_filter = Control.MOUSE_FILTER_PASS
			add_child(l)
		if s.state == "reconnecting":
			var w := Label.new()
			w.text = "reconnecting…"
			w.add_theme_color_override("font_color", Color(1, 0.75, 0.25))
			add_child(w)

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.pressed and plugin_ref != null and plugin_ref._editor_dock != null:
			plugin_ref._editor_dock.make_visible()


static func make_toolbar(p) -> Control:
	var t := Toolbar.new()
	t.plugin_ref = p
	t.visible = false
	t.add_theme_constant_override("separation", 3)
	t.mouse_filter = Control.MOUSE_FILTER_STOP
	t.tooltip_text = "Godot Co-op: click to open the Co-op dock"
	return t
