@tool
extends EditorPlugin
## Godot Co-op editor plugin: wires the collaboration session into the editor.

const Util := preload("res://addons/godot_coop/core/util.gd")
const Session := preload("res://addons/godot_coop/core/session.gd")
const Invite := preload("res://addons/godot_coop/core/invite.gd")
const Git := preload("res://addons/godot_coop/core/git.gd")
const Net := preload("res://addons/godot_coop/core/net.gd")
const SceneSync := preload("res://addons/godot_coop/editor/scene_sync.gd")
const ScriptSync := preload("res://addons/godot_coop/editor/script_sync.gd")
const Presence := preload("res://addons/godot_coop/editor/presence.gd")
const Playtest := preload("res://addons/godot_coop/editor/playtest.gd")
const SettingsSync := preload("res://addons/godot_coop/editor/settings_sync.gd")
const Dock := preload("res://addons/godot_coop/editor/dock.gd")
const PingMenu := preload("res://addons/godot_coop/editor/ping_menu.gd")

var session = null
var scene_sync = SceneSync.new()
var script_sync = ScriptSync.new()
var presence = Presence.new()
var playtest = Playtest.new()
var settings_sync = SettingsSync.new()
var dock: Control = null
var toolbar: Control = null
var profile := {}
var prefs := {}
var trust_host := false
var project_dir := ""
var notifications: Array = []
var lock_requests: Array = []
var git_warning := ""
var short_resolver = null
var live := false                    # live modules (scenes/scripts/presence) running
var _editor_dock = null
var _menus: Array = []
var _fs_scan_at := 0
var _changed_scenes := {}
var _status_at := 0
var _refresh_due := false
var _test = null


func _get_plugin_name() -> String:
	return "Godot Co-op"


func _get_plugin_icon() -> Texture2D:
	return EditorInterface.get_editor_theme().get_icon("Signals", "EditorIcons")


func _enter_tree() -> void:
	project_dir = ProjectSettings.globalize_path("res://").trim_suffix("/")
	Util.ensure_coop_dir(project_dir)
	profile = Util.load_profile()
	prefs = _load_prefs()
	trust_host = bool(prefs.get("trust_host", false))
	scene_sync.setup(self)
	script_sync.setup(self)
	presence.setup(self)
	playtest.setup(self)
	settings_sync.setup(self)
	dock = Dock.new()
	dock.plugin = self
	dock.name = "Co-op"
	if ClassDB.class_exists("EditorDock"):
		_editor_dock = ClassDB.instantiate("EditorDock")
		_editor_dock.title = "Co-op"
		_editor_dock.default_slot = 7          # right side, lower half
		_editor_dock.add_child(dock)
		call("add_dock", _editor_dock)
	else:
		add_control_to_dock(DOCK_SLOT_RIGHT_BL, dock)
	toolbar = Dock.make_toolbar(self)
	add_control_to_container(CONTAINER_TOOLBAR, toolbar)
	for slot in [EditorContextMenuPlugin.CONTEXT_SLOT_SCENE_TREE, EditorContextMenuPlugin.CONTEXT_SLOT_2D_EDITOR,
			EditorContextMenuPlugin.CONTEXT_SLOT_SCRIPT_EDITOR_CODE, EditorContextMenuPlugin.CONTEXT_SLOT_FILESYSTEM]:
		var m := PingMenu.new()
		m.plugin = self
		m.slot = slot
		add_context_menu_plugin(slot, m)
		_menus.append(m)
	set_force_draw_over_forwarding_enabled()
	set_input_event_forwarding_always_enabled()
	main_screen_changed.connect(presence.on_main_screen_changed)
	scene_closed.connect(_on_scene_closed)
	resource_saved.connect(_on_resource_saved)
	scene_saved.connect(_on_scene_saved)
	project_settings_changed.connect(_on_project_settings_changed)
	call_deferred("_autostart")


func _exit_tree() -> void:
	if session != null and session.state in ["hosting", "connected", "reconnecting", "connecting", "waiting_approval"]:
		session.end_session("%s closed their editor." % profile.get("name", "Someone"), true)
	session = null
	scene_sync.teardown()
	script_sync.teardown()
	playtest.teardown()
	for m in _menus:
		remove_context_menu_plugin(m)
	_menus.clear()
	if toolbar != null:
		remove_control_from_container(CONTAINER_TOOLBAR, toolbar)
		toolbar.queue_free()
	if _editor_dock != null:
		call("remove_dock", _editor_dock)
		_editor_dock.queue_free()
	elif dock != null:
		remove_control_from_docks(dock)
		dock.queue_free()
	if _test != null and _test.has_method("stop"):
		_test.stop()


# --- preferences / launch config --------------------------------------------------------------------

func _load_prefs() -> Dictionary:
	var d: Dictionary = Util.read_json(project_dir.path_join(".coop/prefs.json"), {})
	var shared: Dictionary = Util.read_json(Util.shared_data_dir().path_join("settings.json"), {})
	var defaults := {
		"port": Util.DEFAULT_PORT, "use_upnp": true, "relay_host": shared.get("relay_host", ""),
		"relay_port": shared.get("relay_port", Util.DEFAULT_RELAY_PORT), "auto_accept_viewers": false,
		"web_link_base": shared.get("web_link_base", ""), "trust_host": false, "game_port": 7777,
	}
	defaults.merge(d, true)
	return defaults


func save_prefs() -> void:
	Util.write_json(project_dir.path_join(".coop/prefs.json"), prefs)


func save_profile() -> void:
	Util.save_profile(profile)


func _autostart() -> void:
	var test_path := OS.get_environment("GODOT_COOP_TEST")
	var lp := project_dir.path_join(".coop/launch.json")
	var launch: Dictionary = Util.read_json(lp, {})
	if not launch.is_empty():
		DirAccess.remove_absolute(lp)
		if Util.unix_time() - float(launch.get("created", 0)) < 900:
			if launch.get("profile") is Dictionary:
				profile.merge(launch.profile, true)
			if launch.get("settings") is Dictionary:
				prefs.merge(launch.settings, true)
			trust_host = bool(launch.get("trust", trust_host))
			match String(launch.get("mode", "")):
				"host":
					start_host()
				"join":
					join(String(launch.get("invite", "")), String(launch.get("token", "")))
	if not test_path.is_empty() and FileAccess.file_exists(test_path):
		var scr = load(test_path)
		if scr != null:
			_test = scr.new()
			_test.call("start", self)


# --- starting / stopping ------------------------------------------------------------------------------

func _new_session() -> void:
	if session != null and session.state in ["hosting", "connected", "reconnecting", "connecting", "waiting_approval"]:
		session.end_session("Restarted")
	session = Session.new()
	live = false
	session.state_changed.connect(_on_state_changed)
	session.message.connect(_on_message)
	session.join_request.connect(_on_join_request)
	session.join_request_cancelled.connect(func(_id): refresh_ui())
	session.roster_changed.connect(refresh_ui)
	session.invites_changed.connect(_on_invites_changed)
	session.chat_received.connect(func(e): dock.on_chat(e))
	session.activity_received.connect(func(e, r): dock.on_activity(e, r))
	session.welcomed.connect(_on_welcomed)
	session.log_line.connect(func(l): print("[Co-op] ", l))


func _wire_files() -> void:
	var f = session.files
	f.is_open_fn = _is_open_in_editor
	f.trust_risky = trust_host
	f.file_applied.connect(_on_file_applied)
	f.quarantine_changed.connect(_on_quarantine_changed)
	f.deferred_changed.connect(refresh_ui)
	f.rejected.connect(func(rel, why): toast("Change to %s was undone: %s" % [rel, why], 1))
	f.sync_finished.connect(_on_initial_sync_done)


func start_host() -> void:
	_new_session()
	var settings := {
		"port": int(prefs.port), "use_upnp": bool(prefs.use_upnp), "relay_host": String(prefs.relay_host),
		"relay_port": int(prefs.relay_port), "auto_accept_viewers": bool(prefs.auto_accept_viewers),
		"game_port": int(prefs.game_port), "web_link_base": String(prefs.web_link_base),
		"include_loopback": bool(prefs.get("include_loopback", false)),
		"auto_accept_all": bool(prefs.get("auto_accept_all", false)),
	}
	if session.host(project_dir, profile, settings) != OK:
		toast("Couldn't start hosting: " + session.state_detail, 2)
		refresh_ui()
		return
	_wire_files()
	_start_live()
	refresh_ui()


func join(code: String, token := "") -> void:
	code = code.strip_edges()
	if Invite.is_short_code(code) and not Invite.extract_code(code).begins_with(Invite.PREFIX):
		_resolve_short_code(code)
		return
	_new_session()
	if session.join(code, profile, "editor", project_dir, token) != OK:
		toast(session.state_detail, 2)
		refresh_ui()
		return
	_wire_files()
	Util.write_json(project_dir.path_join(".coop/last_session.json"), {"invite": Invite.extract_code(code), "token": token, "project": Invite.decode(code).get("project", "")})
	refresh_ui()


func leave() -> void:
	if session == null:
		return
	if session.is_host:
		session.end_session("%s ended the session." % profile.get("name", "The host"))
	else:
		session.leave()
	_stop_live()
	refresh_ui()


## Short "ABCD-EFGH" codes are looked up on the configured relay.
func _resolve_short_code(code: String) -> void:
	if String(prefs.relay_host).is_empty():
		toast("Short codes need a relay server (set one in the Co-op dock). Paste the full invite code instead.", 1)
		return
	var n := Net.new()
	n.start_client()
	var done := [false]
	n.relay_state.connect(func(st):
		if st == "connected":
			n.relay_send({"t": "short_get", "code": Invite.normalize_short_code(code)})
		elif st == "failed" or st == "lost":
			done[0] = true
			toast("Couldn't reach the relay to look up that code.", 2))
	n.relay_message.connect(func(m):
		if m.get("t") == "short_res":
			done[0] = true
			call_deferred("join", String(m.get("invite", "")))
		elif m.get("t") == "error":
			done[0] = true
			toast(String(m.get("reason", "Unknown code")), 2))
	n.connect_relay(String(prefs.relay_host), int(prefs.relay_port))
	short_resolver = {"net": n, "done": done, "until": Util.now_ms() + 8000}


func _start_live() -> void:
	if live:
		return
	live = true
	scene_sync.session_started()
	script_sync.session_started()
	settings_sync.session_started()


func _stop_live() -> void:
	live = false
	presence.stop_follow()
	scene_sync.trackers.clear()
	for p in script_sync.trackers.keys():
		script_sync._drop(p, false)


# --- session events ------------------------------------------------------------------------------------

func _on_state_changed(state: String, detail: String) -> void:
	match state:
		"reconnecting":
			if live:
				toast("Connection lost. Reconnecting…", 1)
		"failed":
			toast("Co-op: " + detail, 2)
			_stop_live()
		"ended":
			if not detail.is_empty():
				toast("Co-op: " + detail, 1)
			_stop_live()
	refresh_ui()


func _on_welcomed(info: Dictionary) -> void:
	var h: Dictionary = session.host_info
	git_warning = Git.compare(h.get("git", {}), Git.info(project_dir))
	var lp := project_dir.path_join(".coop/last_session.json")
	var last: Dictionary = Util.read_json(lp, {})
	last["token"] = session._token
	last["project"] = h.get("project", "")
	last["host"] = h.get("host_name", "")
	Util.write_json(lp, last)
	if info.get("resumed", false) and live:
		toast("Reconnected.", 0)
	else:
		toast("Joined %s's session (%s). Syncing files…" % [h.get("host_name", "?"), h.get("project", "")], 0)
	refresh_ui()


func _on_initial_sync_done(_summary: Dictionary) -> void:
	if session == null or session.is_host:
		return
	EditorInterface.get_resource_filesystem().scan()
	if not live:
		_start_live()
		session.send({"t": "proj_get"})
		if not session.files.conflict_backups.is_empty():
			toast("Some of your local edits conflicted with the host's. Backups are in .coop/conflicts/.", 1)
	else:
		scene_sync.session_resumed()
		script_sync.session_resumed()


func _on_message(m: Dictionary) -> void:
	var t := String(m.get("t", ""))
	if t.begins_with("sc_") or t == "lock_state":
		scene_sync.on_message(m)
	elif t == "lock_req":
		var from := int(m.get("from", 0))
		lock_requests.append({"path": String(m.get("path", "")), "from": from})
		notify("%s asks for control of %s" % [session.peer_name(from), String(m.get("path", "")).get_file()], session.peer_color(from), Callable())
		refresh_ui()
	elif t.begins_with("tx_"):
		script_sync.on_message(m)
	elif t in ["presence", "presence_fast", "peer_left", "ping"]:
		presence.on_message(m)
		if t != "presence_fast":
			dock.mark_people_dirty()
	elif t in ["playtest", "tun"]:
		playtest.on_message(m)
	elif t in ["proj_set", "proj_full", "proj_get"]:
		settings_sync.on_message(m)
	elif t == "role":
		toast("Your role is now %s%s." % [m.get("role", "?"), (" (" + ", ".join(PackedStringArray(m.get("paths", []))) + ")") if not Array(m.get("paths", [])).is_empty() else ""], 0)
		refresh_ui()
	elif t == "denied":
		if String(m.get("code", "")) == "version":
			dock.show_version_help(m)
	elif t == "disconnected":
		refresh_ui()


func _on_join_request(req: Dictionary) -> void:
	dock.show_join_request(req)
	refresh_ui()


func _on_invites_changed() -> void:
	refresh_ui()
	_write_status()


func _on_quarantine_changed() -> void:
	var n: int = session.files.quarantine.size() if session != null and session.files != null else 0
	if n > 0:
		notify("%d incoming file(s) can run code in the editor. Review them in the Co-op dock." % n, Color.ORANGE, Callable())
	refresh_ui()


func _on_file_applied(rel: String, _by: int, deleted: bool) -> void:
	_fs_scan_at = Util.now_ms() + 400
	var res := "res://" + rel
	var ext := rel.get_extension().to_lower()
	if deleted or not ResourceLoader.has_cached(res):
		if ext in ["tscn", "scn"]:
			scene_sync.invalidate_instance_cache(res)
		return
	# Resources already loaded in memory would otherwise keep their old contents.
	if ext in ["gd", "gdshader", "gdshaderinc"]:
		var r = load(res)
		var text := FileAccess.get_file_as_string(res)
		if r is Script and r.source_code != text:
			r.source_code = text
			r.reload(true)
		elif r is Shader and r.code != text:
			r.code = text
	elif ext in ["tscn", "scn"]:
		scene_sync.invalidate_instance_cache(res)
		_changed_scenes[res] = true
	elif ext in ["tres", "res"]:
		ResourceLoader.load(res, "", ResourceLoader.CACHE_MODE_REPLACE)


## Scenes instanced inside open scenes changed on disk: refresh the instances.
func _refresh_instancing_scenes() -> void:
	if _changed_scenes.is_empty():
		return
	var changed := _changed_scenes.keys()
	_changed_scenes.clear()
	for path in changed:
		ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE)
	for root in EditorInterface.get_open_scene_roots():
		if root == null or root.scene_file_path.is_empty() or changed.has(root.scene_file_path):
			continue
		var uses := false
		for n in root.find_children("*", "", true, false):
			if n.owner == root and changed.has(n.scene_file_path):
				uses = true
				break
		if uses:
			EditorInterface.reload_scene_from_path(root.scene_file_path)


func _is_open_in_editor(rel: String) -> bool:
	var res := "res://" + rel
	return EditorInterface.get_open_scenes().has(res) or script_sync.is_open(res)


func _on_scene_closed(path: String) -> void:
	scene_sync.on_scene_closed(path)


func _on_resource_saved(res: Resource) -> void:
	if session != null and session.files != null and session.is_online() and res.resource_path.begins_with("res://"):
		session.files.check_path(Util.res_to_rel(res.resource_path))


func _on_scene_saved(path: String) -> void:
	if session != null and session.files != null and session.is_online() and path.begins_with("res://"):
		session.files.check_path(Util.res_to_rel(path))


func _on_project_settings_changed() -> void:
	if live:
		settings_sync.on_project_settings_changed()


# --- frame loop --------------------------------------------------------------------------------------

func _process(_delta: float) -> void:
	if short_resolver != null:
		short_resolver.net.poll()
		if short_resolver.done[0] or Util.now_ms() > short_resolver.until:
			short_resolver.net.stop()
			short_resolver = null
	if session == null:
		return
	session.poll()
	if session == null:
		return
	if session.is_online():
		# Godot throttles unfocused editors to ~10 fps; teammates' edits would arrive in steps.
		if OS.low_processor_usage_mode_sleep_usec > 25000:
			OS.low_processor_usage_mode_sleep_usec = 25000
		if session.files != null and not session.files.is_syncing():
			session.files.scan_step(2500)
		if live:
			scene_sync.process()
			script_sync.process()
			presence.process()
			settings_sync.process()
		playtest.process()
	if _fs_scan_at > 0 and Util.now_ms() >= _fs_scan_at:
		_fs_scan_at = 0
		var fs := EditorInterface.get_resource_filesystem()
		if not fs.is_scanning():
			fs.scan()
		scene_sync.retry_failed()
		_refresh_instancing_scenes()
	if _refresh_due:
		_refresh_due = false
		dock.refresh()
	dock.process()
	if Util.now_ms() - _status_at > 2000:
		_write_status()
		_check_control()


## Commands from the companion app (e.g. its "End session" button).
func _check_control() -> void:
	var p := project_dir.path_join(".coop/control.json")
	if not FileAccess.file_exists(p):
		return
	var cmd: Dictionary = Util.read_json(p, {})
	DirAccess.remove_absolute(p)
	match String(cmd.get("cmd", "")):
		"end":
			leave()
			toast("Session ended from the Godot Co-op app.", 0)


## The companion app shows the invite code and who's here by reading this file.
func _write_status() -> void:
	_status_at = Util.now_ms()
	if session == null:
		return
	var peers := []
	for pid in session.roster:
		var r: Dictionary = session.roster[pid]
		peers.append({"name": r.name, "color": r.color, "role": r.role, "online": r.online})
	var st := {"state": session.state, "detail": session.state_detail, "is_host": session.is_host, "peers": peers, "ts": Util.unix_time(), "pid": OS.get_process_id()}
	if session.is_host:
		var inv: Dictionary = session.get_invite("editor")
		st["invite"] = inv.get("code", "")
		st["short"] = inv.get("short", "")
		st["viewer_invite"] = session.get_invite("viewer").get("code", "")
		st["ready"] = session.invites_ready
	Util.write_json(project_dir.path_join(".coop/status.json"), st)


# --- editor hooks ------------------------------------------------------------------------------------

func _forward_canvas_force_draw_over_viewport(overlay: Control) -> void:
	if live and session != null and session.is_online():
		presence.draw_2d(overlay)


func _forward_3d_force_draw_over_viewport(overlay: Control) -> void:
	if live and session != null and session.is_online():
		presence.draw_3d(overlay)


func _forward_canvas_gui_input(event: InputEvent) -> bool:
	if live:
		presence.on_viewport_input(event)
	return false


func _forward_3d_gui_input(_camera: Camera3D, event: InputEvent) -> int:
	if live:
		presence.on_viewport_input(event)
	return EditorPlugin.AFTER_GUI_INPUT_PASS


func _run_scene(_scene: String, args: PackedStringArray) -> PackedStringArray:
	return playtest.run_args(args)


# --- UI helpers -------------------------------------------------------------------------------------

func toast(text: String, severity := 0) -> void:
	EditorInterface.get_editor_toaster().push_toast(text, severity)


func notify(text: String, color: Color, jump: Callable) -> void:
	notifications.push_front({"text": text, "color": color, "jump": jump, "ts": Util.unix_time()})
	if notifications.size() > 20:
		notifications.pop_back()
	toast(text, 0)
	refresh_ui()


func refresh_ui() -> void:
	_refresh_due = true


func set_trust(on: bool) -> void:
	trust_host = on
	prefs.trust_host = on
	save_prefs()
	if session != null and session.files != null:
		session.files.trust_risky = on
