extends Control
## Godot Co-op companion app.
##
##   GodotCoop.exe                          open the app
##   GodotCoop.exe -- "godotcoop://join/…"  open an invite link (what Windows runs for links)
##   GodotCoop.exe --headless -- --relay [--port 47600]   run a relay server, no window
##   GodotCoop.exe --headless -- --install-plugin <project dir>   add the plugin to a project

const Util := preload("res://addons/godot_coop/core/util.gd")
const Invite := preload("res://addons/godot_coop/core/invite.gd")
const Session := preload("res://addons/godot_coop/core/session.gd")
const Relay := preload("res://addons/godot_coop/core/relay_server.gd")
const Net := preload("res://addons/godot_coop/core/net.gd")
const Git := preload("res://addons/godot_coop/core/git.gd")
const AppTheme := preload("res://src/app_theme.gd")
const Installer := preload("res://src/installer.gd")
const Installs := preload("res://src/godot_installs.gd")

const APP_VERSION := "1.0.0"

var installs: Node = null
var profile := {}
var settings := {}
var screen := ""
var _page: VBoxContainer = null
var _scroll: ScrollContainer = null
var _nav := {}
var _toast_label: Label = null
var _toast_until := 0
var _refresh_at := 0

# hosting
var host_dir := ""
var hosted := {}
var _host_exe_pick: OptionButton = null
var _host_status := {}

# joining
var join_session = null
var join_state := ""
var join_error := ""
var join_code := ""
var join_dest := ""
var join_plan := {}
var join_trust := false
var join_clone := false
var join_done_bytes := 0
var join_total_bytes := 0
var join_current := ""
var _short_net = null
var _clone_thread: Thread = null

# relay (in-app or CLI)
var relay: Relay = null
var _relay_cli := false
var _relay_log_at := 0

# version download
var _dl_progress := Vector2i.ZERO
var _dl_msg := ""

# automation flags (used by tests / scripts): --auto-host <dir>, --auto-join, --dest <dir>, --quit-when-done
var _auto_join := false
var _quit_when_done := false


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.has("--relay"):
		_run_relay_cli(args)
		return
	var ip := args.find("--install-plugin")
	if ip != -1 and ip + 1 < args.size():
		var err := Installer.install_plugin(args[ip + 1].replace("\\", "/"))
		print("Godot Co-op plugin installed." if err.is_empty() else "Install failed: " + err)
		get_tree().quit(0 if err.is_empty() else 1)
		return
	theme = AppTheme.build()
	get_window().min_size = Vector2i(880, 620)
	get_window().title = "Godot Co-op"
	profile = Util.load_profile()
	Util.save_profile(profile)
	settings = _load_settings()
	installs = Installs.new()
	add_child(installs)
	installs.download_progress.connect(func(d, t): _dl_progress = Vector2i(d, t))
	installs.download_finished.connect(_on_version_download_done)
	installs.scan()
	_build_layout()
	_auto_join = args.has("--auto-join")
	_quit_when_done = args.has("--quit-when-done")
	var di := args.find("--dest")
	var forced_dest := args[di + 1].replace("\\", "/") if di != -1 and di + 1 < args.size() else ""
	var hi := args.find("--auto-host")
	if hi != -1 and hi + 1 < args.size():
		host_dir = args[hi + 1].replace("\\", "/")
		show_screen("host")
		_start_hosting()
		if _quit_when_done:
			get_tree().quit()
		return
	var link := ""
	for a in args:
		if a.find(Invite.PREFIX) != -1 or a.begins_with(Util.URL_SCHEME + ":") or Invite.is_short_code(a):
			link = a
	if not link.is_empty():
		show_screen("join")
		_start_join(link)
		if not forced_dest.is_empty() and join_session != null:
			_set_join_dest(forced_dest)
	else:
		show_screen("home")
	if bool(settings.get("run_relay", false)):
		_start_relay()
	var shot := args.find("--shot")
	if shot != -1 and shot + 1 < args.size():
		_screenshot(args[shot + 1], args)


## Developer aid: GodotCoop.exe -- --shot out.png [--screen join] renders a screen to an image.
func _screenshot(path: String, args: PackedStringArray) -> void:
	var si := args.find("--screen")
	if si != -1 and si + 1 < args.size():
		show_screen(args[si + 1])
	for i in 12:
		await get_tree().process_frame
	var tex := get_viewport().get_texture()
	var img := tex.get_image()
	var err := img.save_png(path)
	get_tree().quit()


func _load_settings() -> Dictionary:
	var d: Dictionary = Util.read_json(Util.shared_data_dir().path_join("settings.json"), {})
	var defaults := {
		"relay_host": "", "relay_port": Util.DEFAULT_RELAY_PORT, "web_link_base": "", "port": Util.DEFAULT_PORT,
		"use_upnp": true, "auto_accept_viewers": false, "run_relay": false,
		"projects_dir": OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS).path_join("GodotCoop"),
	}
	defaults.merge(d, true)
	return defaults


func _save_settings() -> void:
	var d: Dictionary = Util.read_json(Util.shared_data_dir().path_join("settings.json"), {})
	d.merge(settings, true)
	Util.write_json(Util.shared_data_dir().path_join("settings.json"), d)


# ==================================================================================================
# Layout & widgets

func _build_layout() -> void:
	var bg := Panel.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var root := HBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	add_child(root)
	var side := PanelContainer.new()
	side.theme_type_variation = "Sidebar"
	side.custom_minimum_size.x = 220
	root.add_child(side)
	var sv := VBoxContainer.new()
	sv.add_theme_constant_override("separation", 4)
	side.add_child(sv)
	var brand := HBoxContainer.new()
	brand.add_theme_constant_override("separation", 10)
	sv.add_child(brand)
	var logo := TextureRect.new()
	logo.texture = load("res://icon.svg")
	logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	logo.custom_minimum_size = Vector2(36, 36)
	brand.add_child(logo)
	var bl := Label.new()
	bl.text = "Godot Co-op"
	bl.theme_type_variation = "Subheading"
	brand.add_child(bl)
	var spacer := Control.new()
	spacer.custom_minimum_size.y = 18
	sv.add_child(spacer)
	var group := ButtonGroup.new()
	for item in [["home", "Home"], ["host", "Host a project"], ["join", "Join a session"], ["session", "Hosting status"], ["versions", "Godot versions"], ["settings", "Settings"]]:
		var b := Button.new()
		b.text = item[1]
		b.theme_type_variation = "Nav"
		b.toggle_mode = true
		b.button_group = group
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.pressed.connect(show_screen.bind(item[0]))
		sv.add_child(b)
		_nav[item[0]] = b
	var fill := Control.new()
	fill.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sv.add_child(fill)
	var me := HBoxContainer.new()
	me.add_theme_constant_override("separation", 8)
	sv.add_child(me)
	me.add_child(_dot(Util.color_of(profile), 12))
	var ml := Label.new()
	ml.text = String(profile.get("name", ""))
	ml.name = "MeLabel"
	me.add_child(ml)
	var ver := Label.new()
	ver.text = "v" + APP_VERSION
	ver.theme_type_variation = "Muted"
	sv.add_child(ver)
	var main := VBoxContainer.new()
	main.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(main)
	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	main.add_child(_scroll)
	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side_name in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side_name, 40 if side_name in ["left", "right"] else 34)
	_scroll.add_child(margin)
	_page = VBoxContainer.new()
	_page.add_theme_constant_override("separation", 16)
	_page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.add_child(_page)
	_toast_label = Label.new()
	_toast_label.visible = false
	_toast_label.add_theme_stylebox_override("normal", AppTheme._box(Color("#2b3242"), 8, AppTheme.BORDER, 1, 10))
	_toast_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_toast_label.position.y -= 60
	add_child(_toast_label)


func _dot(color: Color, size := 10) -> Control:
	var p := Panel.new()
	p.add_theme_stylebox_override("panel", AppTheme._box(color, size, Color(0, 0, 0, 0), 0, 0))
	p.custom_minimum_size = Vector2(size, size)
	p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return p


func _label(parent: Control, text: String, variation := "", wrap := false) -> Label:
	var l := Label.new()
	l.text = text
	if not variation.is_empty():
		l.theme_type_variation = variation
	if wrap:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size.x = 200
	parent.add_child(l)
	return l


func _btn(parent: Control, text: String, cb: Callable, primary := false) -> Button:
	var b := Button.new()
	b.text = text
	if primary:
		b.theme_type_variation = "Primary"
	b.pressed.connect(cb)
	parent.add_child(b)
	return b


func _card(parent: Control, flat := false) -> VBoxContainer:
	var pc := PanelContainer.new()
	pc.theme_type_variation = "CardFlat" if flat else "Card"
	pc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(pc)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	pc.add_child(v)
	return v


func _hrow(parent: Control, sep := 10) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", sep)
	parent.add_child(h)
	return h


func _line(parent: Control, text: String, placeholder: String, cb := Callable()) -> LineEdit:
	var e := LineEdit.new()
	e.text = text
	e.placeholder_text = placeholder
	e.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if cb.is_valid():
		e.text_changed.connect(cb)
	parent.add_child(e)
	return e


func _kv(parent: Control, key: String, value: String, color := AppTheme.TEXT) -> Label:
	var h := _hrow(parent)
	var k := Label.new()
	k.text = key
	k.theme_type_variation = "Muted"
	k.custom_minimum_size.x = 160
	h.add_child(k)
	var v := Label.new()
	v.text = value
	v.add_theme_color_override("font_color", color)
	v.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(v)
	return v


func toast(text: String) -> void:
	_toast_label.text = text
	_toast_label.visible = true
	_toast_label.reset_size()
	_toast_label.position = Vector2((size.x - _toast_label.size.x + 220) * 0.5, size.y - 70)
	_toast_until = Util.now_ms() + 2600


func _copy(text: String, what: String) -> void:
	if text.is_empty():
		return
	DisplayServer.clipboard_set(text)
	toast(what + " copied - paste it to your teammate")


func _pick_folder(title: String, start: String, cb: Callable) -> void:
	var fd := FileDialog.new()
	fd.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.use_native_dialog = true
	fd.title = title
	if DirAccess.dir_exists_absolute(start):
		fd.current_dir = start
	fd.dir_selected.connect(func(d):
		cb.call(d)
		fd.queue_free())
	fd.canceled.connect(fd.queue_free)
	add_child(fd)
	fd.popup_centered(Vector2i(800, 520))


func _pick_file(title: String, filters: PackedStringArray, cb: Callable) -> void:
	var fd := FileDialog.new()
	fd.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.use_native_dialog = true
	fd.title = title
	fd.filters = filters
	fd.file_selected.connect(func(f):
		cb.call(f)
		fd.queue_free())
	fd.canceled.connect(fd.queue_free)
	add_child(fd)
	fd.popup_centered(Vector2i(800, 520))


func show_screen(name: String) -> void:
	screen = name
	for k in _nav:
		_nav[k].set_pressed_no_signal(k == name)
	_nav["session"].visible = not hosted.is_empty()
	render()


func render() -> void:
	if _page == null:
		return
	for c in _page.get_children():
		_page.remove_child(c)
		c.queue_free()
	match screen:
		"home":
			_render_home()
		"host":
			_render_host()
		"session":
			_render_session()
		"join":
			_render_join()
		"versions":
			_render_versions()
		"settings":
			_render_settings()


# ==================================================================================================
# Home

func _render_home() -> void:
	_label(_page, "Build together, live.", "Title")
	_label(_page, "Scenes, scripts, files and project settings stay in sync between everyone's Godot editor - like Google Docs, for your game.", "Muted", true)
	var cards := _hrow(_page, 16)
	var h := _card(cards)
	_label(h, "Host a project", "Heading")
	_label(h, "Share a project from this computer. Teammates join with an invite code - no accounts, no servers needed on your LAN.", "Muted", true)
	_btn(h, "Choose a project…", _home_host, true)
	var j := _card(cards)
	_label(j, "Join a session", "Heading")
	_label(j, "Got an invite from a teammate? Paste it here. We'll download the project and the right Godot version for you.", "Muted", true)
	var jr := _hrow(j)
	var code := _line(jr, "", "Invite code, link or short code")
	code.text_submitted.connect(func(t):
		show_screen("join")
		_start_join(t))
	_btn(jr, "Join", _home_join.bind(code), true)
	var how := _card(_page, true)
	_label(how, "How it works", "Subheading")
	for step in [
		"1.  The host picks a project here. Godot opens with the Co-op dock and an invite code.",
		"2.  Teammates paste the code. This app downloads the project (and the matching Godot version) and opens it.",
		"3.  Everyone edits at once: scene changes, script typing, new files and project settings appear for everyone live.",
	]:
		_label(how, step, "Muted", true)
	var recent: Array = Util.read_json(Util.shared_data_dir().path_join("recent.json"), [])
	if not recent.is_empty():
		_label(_page, "Recent", "Heading")
		var rc := _card(_page, true)
		for r in recent.slice(0, 8):
			var row := _hrow(rc)
			var v := VBoxContainer.new()
			v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(v)
			_label(v, String(r.get("project", "?")), "Subheading")
			_label(v, "%s · %s" % ["Hosted" if r.get("kind") == "host" else "Joined", r.get("path", "")], "Muted")
			if r.get("kind") == "host":
				_btn(row, "Host again", func():
					host_dir = String(r.path)
					show_screen("host"))
			else:
				_btn(row, "Open in Godot", _open_recent.bind(r))
			_btn(row, "Folder", func(): OS.shell_show_in_file_manager(String(r.path)))
	var st := _card(_page, true)
	if installs.installs.is_empty():
		_label(st, "No Godot editors found yet. Add one under Godot versions (or we'll download the right one when you join).", "Muted", true)
	else:
		var names := PackedStringArray()
		for i in installs.installs.slice(0, 4):
			names.append(i.label)
		_label(st, "Godot editors found: " + ", ".join(names), "Muted", true)


func _home_host() -> void:
	show_screen("host")
	_choose_host_folder()


func _home_join(code: LineEdit) -> void:
	show_screen("join")
	_start_join(code.text)


func _open_recent(r: Dictionary) -> void:
	var path := String(r.get("path", ""))
	var info := Installer.project_info(path)
	var exe := _pick_editor_for(String(info.get("feature", "")), bool(info.get("dotnet", false)))
	if exe.is_empty():
		toast("No matching Godot editor found - see Godot versions.")
		return
	Installer.launch_editor(exe, path)
	toast("Opening %s… use the Co-op dock's Rejoin button." % r.get("project", ""))


func _add_recent(kind: String, path: String, project: String) -> void:
	var p := Util.shared_data_dir().path_join("recent.json")
	var recent: Array = Util.read_json(p, [])
	recent = recent.filter(func(r): return String(r.get("path", "")) != path)
	recent.push_front({"kind": kind, "path": path, "project": project, "ts": Util.unix_time()})
	Util.write_json(p, recent.slice(0, 12))


func _pick_editor_for(feature: String, dotnet: bool) -> String:
	var list: Array = installs.find_for_feature(feature, dotnet) if not feature.is_empty() else installs.installs
	return String(list[0].path) if not list.is_empty() else ""


# ==================================================================================================
# Host

func _choose_host_folder() -> void:
	_pick_folder("Choose your Godot project folder", host_dir if not host_dir.is_empty() else OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS), func(d):
		host_dir = String(d).replace("\\", "/")
		render())


func _render_host() -> void:
	_label(_page, "Host a project", "Title")
	var c := _card(_page)
	_label(c, "Project folder", "Subheading")
	var r := _hrow(c)
	var path_edit := _line(r, host_dir, "C:/Users/you/Documents/MyGame")
	path_edit.text_submitted.connect(func(t):
		host_dir = t.strip_edges().replace("\\", "/")
		render())
	_btn(r, "Browse…", _choose_host_folder)
	if host_dir.is_empty():
		_label(c, "Pick the folder that contains project.godot.", "Muted")
		return
	var info := Installer.project_info(host_dir)
	if info.is_empty():
		_label(c, "There's no project.godot in that folder.", "Muted").add_theme_color_override("font_color", AppTheme.BAD)
		return
	_kv(c, "Project", String(info.name))
	_kv(c, "Made with Godot", String(info.feature) + (" (.NET)" if info.dotnet else ""))
	var matches: Array = installs.find_for_feature(String(info.feature), bool(info.dotnet))
	var er := _hrow(c)
	var el := Label.new()
	el.text = "Open with"
	el.theme_type_variation = "Muted"
	el.custom_minimum_size.x = 160
	er.add_child(el)
	_host_exe_pick = OptionButton.new()
	_host_exe_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for i in installs.installs:
		_host_exe_pick.add_item("Godot %s - %s" % [i.label, String(i.path).get_file()])
		_host_exe_pick.set_item_metadata(_host_exe_pick.item_count - 1, i.path)
		if not matches.is_empty() and i.path == matches[0].path:
			_host_exe_pick.select(_host_exe_pick.item_count - 1)
	er.add_child(_host_exe_pick)
	if matches.is_empty():
		_label(c, "None of your Godot editors match %s. Add or download one under Godot versions." % info.feature, "Muted", true).add_theme_color_override("font_color", AppTheme.WARN)
	_kv(c, "Co-op plugin", "Installed" if info.plugin_installed else "Will be added to addons/godot_coop (teammates get it automatically)", AppTheme.GOOD if info.plugin_installed else AppTheme.TEXT)
	var o := _card(_page, true)
	_label(o, "Connection", "Subheading")
	var up := CheckBox.new()
	up.text = "Open the port on my router automatically (UPnP)"
	up.button_pressed = bool(settings.use_upnp)
	up.toggled.connect(func(on):
		settings.use_upnp = on
		_save_settings())
	o.add_child(up)
	var av := CheckBox.new()
	av.text = "Let viewers (read-only invite) in without asking"
	av.button_pressed = bool(settings.auto_accept_viewers)
	av.toggled.connect(func(on):
		settings.auto_accept_viewers = on
		_save_settings())
	o.add_child(av)
	if String(settings.relay_host).is_empty():
		_label(o, "Tip: on different networks, people connect directly if your router supports UPnP. For guaranteed connections and short codes, set a relay server in Settings.", "Muted", true)
	else:
		_label(o, "Relay: %s:%d (used when a direct connection isn't possible)" % [settings.relay_host, int(settings.relay_port)], "Muted", true)
	var go := _btn(_page, "Start hosting", _start_hosting, true)
	go.disabled = installs.installs.is_empty()


func _start_hosting() -> void:
	var info := Installer.project_info(host_dir)
	if info.is_empty():
		return
	var exe := ""
	if _host_exe_pick != null and _host_exe_pick.selected >= 0:
		exe = String(_host_exe_pick.get_item_metadata(_host_exe_pick.selected))
	if exe.is_empty():
		toast("Pick a Godot editor first.")
		return
	var err := Installer.install_plugin(host_dir)
	if not err.is_empty():
		toast(err)
		return
	DirAccess.remove_absolute(host_dir.path_join(".coop/status.json"))
	Installer.write_launch(host_dir, {
		"mode": "host", "profile": profile,
		"settings": {"port": int(settings.port), "use_upnp": bool(settings.use_upnp), "relay_host": String(settings.relay_host),
			"relay_port": int(settings.relay_port), "auto_accept_viewers": bool(settings.auto_accept_viewers),
			"web_link_base": String(settings.web_link_base)},
	})
	var pid := Installer.launch_editor(exe, host_dir)
	if pid <= 0:
		toast("Couldn't start Godot.")
		return
	hosted = {"dir": host_dir, "project": info.name, "pid": pid, "started": Util.unix_time()}
	_add_recent("host", host_dir, String(info.name))
	show_screen("session")


# ==================================================================================================
# Hosting status (read from the editor plugin's .coop/status.json)

func _render_session() -> void:
	if hosted.is_empty():
		_label(_page, "You're not hosting anything from this app right now.", "Muted")
		return
	_host_status = Util.read_json(String(hosted.dir).path_join(".coop/status.json"), {})
	var fresh := not _host_status.is_empty() and Util.unix_time() - float(_host_status.get("ts", 0)) < 8.0
	_label(_page, "Hosting %s" % hosted.project, "Title")
	var st := _hrow(_page)
	var col := AppTheme.GOOD if fresh and _host_status.get("state") == "hosting" else AppTheme.WARN
	st.add_child(_dot(col, 12))
	var stext := "Live" if fresh and _host_status.get("state") == "hosting" else ("Godot is starting… (first launch imports the project)" if not fresh else String(_host_status.get("state", "")).capitalize())
	_label(st, stext, "Subheading")
	var c := _card(_page)
	_label(c, "Invite", "Heading")
	if not fresh or not bool(_host_status.get("ready", false)):
		_label(c, "Preparing your invite… (checking your router and relay)", "Muted")
	else:
		var code := String(_host_status.get("invite", ""))
		var ce := LineEdit.new()
		ce.text = code
		ce.editable = false
		ce.add_theme_font_size_override("font_size", 14)
		c.add_child(ce)
		var r := _hrow(c)
		_btn(r, "Copy invite code", func(): _copy(code, "Invite code"), true)
		_btn(r, "Copy link", func(): _copy(Invite.link(code), "Invite link"))
		if not String(settings.web_link_base).is_empty():
			_btn(r, "Copy web link", func(): _copy(Invite.web_link(String(settings.web_link_base), code), "Web link"))
		_btn(r, "Copy read-only invite", func(): _copy(String(_host_status.get("viewer_invite", "")), "Viewer invite"))
		var short := String(_host_status.get("short", ""))
		if not short.is_empty():
			var sr := _hrow(c)
			_label(sr, "Short code:", "Muted")
			var sl := _label(sr, Invite.pretty_short_code(short), "Heading")
			sl.add_theme_color_override("font_color", AppTheme.ACCENT_HOVER)
			_btn(sr, "Copy", func(): _copy(Invite.pretty_short_code(short), "Short code"))
		_label(c, "Send the code or link to your teammate (Discord, email…). They paste it into Godot Co-op. You approve them in the Co-op dock inside Godot.", "Muted", true)
	var pc := _card(_page, true)
	_label(pc, "People", "Subheading")
	for p in _host_status.get("peers", []):
		var row := _hrow(pc)
		row.add_child(_dot(Color.from_string(String(p.get("color", "fff")), Color.WHITE) if p.get("online", false) else Color(0.35, 0.35, 0.35), 10))
		_label(row, "%s  ·  %s%s" % [p.get("name", "?"), p.get("role", ""), "" if p.get("online", false) else " (offline)"])
	var br := _hrow(_page)
	_btn(br, "Open project folder", func(): OS.shell_show_in_file_manager(String(hosted.dir)))
	_btn(br, "End session", func():
		Util.write_json(String(hosted.dir).path_join(".coop/control.json"), {"cmd": "end"})
		toast("Asked the editor to end the session."))
	_btn(br, "Forget", func():
		hosted = {}
		show_screen("home"))


# ==================================================================================================
# Join

func _default_dest(project: String) -> String:
	var safe := ""
	for ch in project:
		safe += ch if (ch.is_valid_identifier() or ch in "-_ 0123456789") else "_"
	safe = safe.strip_edges()
	if safe.is_empty():
		safe = "CoopProject"
	var base := String(settings.projects_dir).path_join(safe)
	var p := base
	var n := 2
	while DirAccess.dir_exists_absolute(p) and not FileAccess.file_exists(p.path_join(".coop/sync_state.json")) and not DirAccess.get_files_at(p).is_empty():
		p = base + " " + str(n)
		n += 1
	return p


func _start_join(text: String) -> void:
	text = text.strip_edges()
	join_error = ""
	if text.is_empty():
		return
	if Invite.is_short_code(text) and Invite.extract_code(text).find(Invite.PREFIX) == -1:
		_resolve_short(text)
		return
	var inv := Invite.decode(text)
	if inv.is_empty():
		join_state = "error"
		join_error = "That doesn't look like a Godot Co-op invite."
		render()
		return
	_cancel_join()
	join_code = Invite.extract_code(text)
	join_dest = _default_dest(String(inv.get("project", "Project")))
	join_plan = {}
	join_trust = false
	join_session = Session.new()
	join_session.state_changed.connect(_on_join_state)
	join_session.welcomed.connect(_on_join_welcomed)
	join_session.join(join_code, profile, "download", join_dest)
	if join_session.files != null:
		_wire_join_files()
	join_state = "connecting"
	render()


func _wire_join_files() -> void:
	var f = join_session.files
	f.plan_preview.connect(_on_plan_preview)
	f.progress.connect(func(d, t, cur):
		join_done_bytes = d
		join_total_bytes = t
		join_current = cur)
	f.sync_finished.connect(_on_download_done)


func _resolve_short(code: String) -> void:
	if String(settings.relay_host).is_empty():
		join_state = "error"
		join_error = "Short codes are looked up on a relay server. Set one in Settings, or paste the full invite code."
		render()
		return
	join_state = "connecting"
	render()
	var n := Net.new()
	n.start_client()
	n.relay_state.connect(_on_short_relay_state.bind(n, code))
	n.relay_message.connect(_on_short_relay_message)
	n.connect_relay(String(settings.relay_host), int(settings.relay_port))
	_short_net = {"net": n, "until": Util.now_ms() + 8000}


func _on_short_relay_state(st: String, n, code: String) -> void:
	if st == "connected":
		n.relay_send({"t": "short_get", "code": Invite.normalize_short_code(code)})


func _on_short_relay_message(m: Dictionary) -> void:
	if str(m.get("t")) == "short_res":
		_short_net = null
		call_deferred("_start_join", String(m.get("invite", "")))
	elif str(m.get("t")) == "error":
		_short_net = null
		join_state = "error"
		join_error = String(m.get("reason", "Unknown code"))
		render()


func _cancel_join() -> void:
	if join_session != null:
		if join_session.state in ["connected", "connecting", "waiting_approval", "reconnecting"]:
			join_session.end_session("Cancelled")
		join_session = null
	join_state = ""


func _on_join_state(st: String, detail: String) -> void:
	match st:
		"waiting_approval":
			join_state = "approval"
		"failed", "ended":
			if join_state in ["connecting", "approval", "plan", "downloading"]:
				join_state = "error"
				join_error = detail
	render()


func _on_join_welcomed(_info: Dictionary) -> void:
	join_state = "loading_plan"
	join_session.files.begin_sync(true)
	render()


func _on_plan_preview(plan: Dictionary) -> void:
	join_plan = plan
	join_state = "plan"
	render()
	if _auto_join:
		join_trust = true
		_begin_download()


func _set_join_dest(d: String) -> void:
	join_dest = d.replace("\\", "/")
	if join_session != null and join_session.files != null:
		join_session.project_dir = join_dest
		Util.ensure_coop_dir(join_dest)
		join_session.files.setup(join_dest, false, join_session.my_pid)
		join_session.files.load_state()
		join_session.files.manage_project_godot = true
		join_state = "loading_plan"
		join_session.files.begin_sync(true)
	render()


func _render_join() -> void:
	_label(_page, "Join a session", "Title")
	match join_state:
		"", "error":
			var c := _card(_page)
			_label(c, "Paste the invite code or link your teammate sent you.", "Muted", true)
			var r := _hrow(c)
			var e := _line(r, join_code if join_state == "error" else "", "gdc1.…  or  godotcoop://join/…  or  ABCD-EFGH")
			e.text_submitted.connect(_start_join)
			_btn(r, "Connect", func(): _start_join(e.text), true)
			if join_state == "error":
				_label(c, join_error, "", true).add_theme_color_override("font_color", AppTheme.BAD)
		"connecting":
			var c := _card(_page)
			_label(c, "Reaching the host…", "Heading")
			_label(c, "Trying a direct connection first, then the relay if there is one.", "Muted", true)
			_btn(c, "Cancel", func():
				_cancel_join()
				render())
		"approval":
			var c := _card(_page)
			_label(c, "Waiting for the host to let you in…", "Heading")
			_label(c, "They'll see a request in their Godot editor.", "Muted", true)
			_btn(c, "Cancel", func():
				_cancel_join()
				render())
		"loading_plan":
			var c := _card(_page)
			_label(c, "You're in! Checking what to download…", "Heading")
		"plan":
			_render_join_plan()
		"downloading":
			_render_join_progress()
		"done":
			var c := _card(_page)
			_label(c, "You're in!", "Heading")
			_label(c, "Godot is opening %s and will connect to the session by itself. The first launch imports the project, which can take a minute." % join_session_project(), "Muted", true)
			var r := _hrow(c)
			_btn(r, "Open project folder", func(): OS.shell_show_in_file_manager(join_dest))
			_btn(r, "Back to home", func():
				join_state = ""
				show_screen("home"))


func join_session_project() -> String:
	if join_session != null:
		return String(join_session.host_info.get("project", "the project"))
	return "the project"


func _render_join_plan() -> void:
	var s = join_session
	var hi: Dictionary = s.host_info
	var need: Dictionary = hi.get("godot", {})
	var c := _card(_page)
	_label(c, "%s's project: %s" % [hi.get("host_name", "Host"), hi.get("project", "")], "Heading")
	var count := int(join_plan.get("count", 0))
	var total := int(join_plan.get("total", 0))
	_kv(c, "To download", "%d files, %s" % [count, Util.human_bytes(total)] if count > 0 else "Nothing - you're up to date")
	var exact: Dictionary = installs.find_exact(need)
	var vrow := _kv(c, "Godot version", Util.version_label(need) + ("  ✓ installed" if not exact.is_empty() else "  - not installed"), AppTheme.GOOD if not exact.is_empty() else AppTheme.WARN)
	vrow.tooltip_text = String(exact.get("path", ""))
	if exact.is_empty():
		var vr := _hrow(c)
		if installs.is_downloading():
			var pb := ProgressBar.new()
			pb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			pb.max_value = max(1, _dl_progress.y)
			pb.value = _dl_progress.x
			pb.custom_minimum_size.y = 22
			vr.add_child(pb)
			_label(vr, "%s / %s" % [Util.human_bytes(_dl_progress.x), Util.human_bytes(_dl_progress.y)], "Muted")
		else:
			_btn(vr, "Download Godot %s" % Util.version_label(need), _download_version.bind(need), true)
			_btn(vr, "I have it - locate…", _locate_editor)
		if not _dl_msg.is_empty():
			_label(c, _dl_msg, "Muted", true)
	var dr := _hrow(c)
	var dl := Label.new()
	dl.text = "Save to"
	dl.theme_type_variation = "Muted"
	dl.custom_minimum_size.x = 160
	dr.add_child(dl)
	var de := _line(dr, join_dest, "")
	de.text_submitted.connect(_set_join_dest)
	_btn(dr, "Change…", func(): _pick_folder("Where should the project go?", String(settings.projects_dir), _set_join_dest))
	var git: Dictionary = hi.get("git", {})
	if git.get("ok", false) and not String(git.get("remote", "")).is_empty() and Git.available():
		var gc := CheckBox.new()
		gc.text = "Clone the git repository first (%s @ %s) so your history matches" % [git.get("branch", ""), String(git.get("head", "")).substr(0, 8)]
		gc.button_pressed = join_clone
		gc.toggled.connect(func(on): join_clone = on)
		c.add_child(gc)
	var risky: Array = join_plan.get("risky", [])
	if not risky.is_empty():
		var rc := _card(_page, true)
		var rh := _label(rc, "%d file(s) in this project can run code inside the Godot editor" % risky.size(), "Subheading")
		rh.add_theme_color_override("font_color", AppTheme.WARN)
		_label(rc, "Editor plugins, @tool scripts and native libraries run as soon as Godot opens the project. Only continue if you trust %s." % hi.get("host_name", "the host"), "Muted", true)
		var list := RichTextLabel.new()
		list.fit_content = true
		list.bbcode_enabled = true
		var t := ""
		for r in risky.slice(0, 30):
			t += "• [b]%s[/b] - [color=#8d96a8]%s[/color]\n" % [String(r[0]).replace("[", "[lb]"), r[1]]
		if risky.size() > 30:
			t += "…and %d more" % (risky.size() - 30)
		list.text = t
		rc.add_child(list)
		var tc := CheckBox.new()
		tc.text = "I trust %s - allow these files" % hi.get("host_name", "the host")
		tc.button_pressed = join_trust
		tc.toggled.connect(func(on):
			join_trust = on
			render())
		rc.add_child(tc)
	var br := _hrow(_page)
	var go := _btn(br, "Download & open in Godot", _begin_download, true)
	go.disabled = exact.is_empty() or (not risky.is_empty() and not join_trust)
	_btn(br, "Cancel", func():
		_cancel_join()
		render())
	if exact.is_empty():
		_label(_page, "Install Godot %s first - everyone in a session needs the exact same version." % Util.version_label(need), "Muted", true)


func _download_version(v: Dictionary) -> void:
	_dl_msg = ""
	installs.download(v)
	render()


func _locate_editor() -> void:
	_pick_file("Locate a Godot editor", PackedStringArray(["*.exe, *.x86_64 ; Godot editor"]), _on_editor_located)


func _on_editor_located(f: String) -> void:
	if not installs.add_path(f):
		toast("That doesn't look like a Godot editor.")
	render()


func _begin_download() -> void:
	var s = join_session
	if join_clone and (not DirAccess.dir_exists_absolute(join_dest) or DirAccess.get_files_at(join_dest).is_empty()):
		var git: Dictionary = s.host_info.get("git", {})
		join_state = "downloading"
		join_current = "Cloning git repository…"
		render()
		_clone_thread = Thread.new()
		_clone_thread.start(func(): return Git.clone(String(git.remote), join_dest, String(git.head)))
		return
	_start_file_download()


func _start_file_download() -> void:
	var s = join_session
	s.files.trust_risky = join_trust
	s.files.setup(join_dest, false, s.my_pid)
	s.files.load_state()
	s.files.manage_project_godot = true
	join_state = "downloading"
	join_done_bytes = 0
	join_total_bytes = int(join_plan.get("total", 0))
	s.files.begin_sync(false)
	render()


func _render_join_progress() -> void:
	var c := _card(_page)
	_label(c, "Downloading %s…" % join_session_project(), "Heading")
	var pb := ProgressBar.new()
	pb.name = "JoinProgress"
	pb.custom_minimum_size.y = 26
	pb.max_value = max(1, join_total_bytes)
	pb.value = join_done_bytes
	c.add_child(pb)
	var l := _label(c, "%s of %s  ·  %s" % [Util.human_bytes(join_done_bytes), Util.human_bytes(join_total_bytes), join_current], "Muted")
	l.name = "JoinProgressLabel"
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS


func _on_download_done(_summary: Dictionary) -> void:
	if join_state != "downloading":
		return
	var s = join_session
	var err := Installer.install_plugin(join_dest)
	if not err.is_empty():
		join_state = "error"
		join_error = "Downloaded, but couldn't set up the plugin: " + err
		render()
		return
	Installer.write_launch(join_dest, {"mode": "join", "invite": join_code, "token": s._token, "profile": profile, "trust": join_trust})
	var exact: Dictionary = installs.find_exact(s.host_info.get("godot", {}))
	s.end_session("Handing over to the editor")
	_add_recent("join", join_dest, String(s.host_info.get("project", "")))
	if exact.is_empty():
		join_state = "error"
		join_error = "Project downloaded to %s, but the matching Godot version isn't installed." % join_dest
	else:
		Installer.launch_editor(String(exact.path), join_dest)
		join_state = "done"
	render()
	if _quit_when_done:
		get_tree().quit()


func _on_version_download_done(ok: bool, msg: String) -> void:
	_dl_msg = ("Installed: " + msg) if ok else msg
	if ok:
		installs.scan()
	render()


# ==================================================================================================
# Godot versions

func _render_versions() -> void:
	_label(_page, "Godot versions", "Title")
	_label(_page, "Everyone in a session must use exactly the same Godot version. We find the editors on this computer and can download any official build.", "Muted", true)
	var c := _card(_page)
	if installs.installs.is_empty():
		_label(c, "No Godot editors found.", "Muted")
	for i in installs.installs:
		var r := _hrow(c)
		var v := VBoxContainer.new()
		v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		r.add_child(v)
		_label(v, "Godot " + String(i.label), "Subheading")
		_label(v, String(i.path), "Muted")
		_btn(r, "Show", func(): OS.shell_show_in_file_manager(String(i.path)))
	var br := _hrow(c)
	_btn(br, "Add an editor…", _locate_editor)
	_btn(br, "Rescan", func():
		installs.scan()
		render())
	var d := _card(_page, true)
	_label(d, "Download a version", "Subheading")
	var dr := _hrow(d)
	var ve := _line(dr, "4.7.2-stable", "e.g. 4.7.2-stable or 4.8-beta1")
	var net := CheckBox.new()
	net.text = ".NET (C#)"
	dr.add_child(net)
	_btn(dr, "Download", _download_typed_version.bind(ve, net), true)
	if installs.is_downloading():
		var pb := ProgressBar.new()
		pb.max_value = max(1, _dl_progress.y)
		pb.value = _dl_progress.x
		pb.custom_minimum_size.y = 22
		d.add_child(pb)
	if not _dl_msg.is_empty():
		_label(d, _dl_msg, "Muted", true)


func _download_typed_version(ve: LineEdit, net: CheckBox) -> void:
	var v := _parse_version(ve.text, net.button_pressed)
	if v.is_empty():
		toast("Use a version like 4.7.2-stable")
		return
	_download_version(v)


static func _parse_version(text: String, dotnet: bool) -> Dictionary:
	var t := text.strip_edges()
	var parts := t.split("-")
	var nums := parts[0].split(".")
	if nums.size() < 2 or not nums[0].is_valid_int() or not nums[1].is_valid_int():
		return {}
	return {"major": int(nums[0]), "minor": int(nums[1]), "patch": int(nums[2]) if nums.size() > 2 and nums[2].is_valid_int() else 0,
		"status": parts[1] if parts.size() > 1 else "stable", "dotnet": dotnet}


# ==================================================================================================
# Settings

func _render_settings() -> void:
	_label(_page, "Settings", "Title")
	var p := _card(_page)
	_label(p, "You", "Heading")
	var r := _hrow(p)
	var cp := ColorPickerButton.new()
	cp.color = Util.color_of(profile)
	cp.edit_alpha = false
	cp.custom_minimum_size = Vector2(44, 36)
	cp.color_changed.connect(func(col):
		profile.color = col.to_html(false)
		Util.save_profile(profile))
	r.add_child(cp)
	_line(r, String(profile.get("name", "")), "Your name", _on_name_changed)
	_line(p, String(profile.get("email", "")), "Email for git co-author credit (optional)", func(t):
		profile.email = t.strip_edges()
		Util.save_profile(profile))
	var n := _card(_page)
	_label(n, "Network", "Heading")
	_label(n, "Relay server (optional): makes connections work through any firewall and enables short codes like ABCD-EFGH. Everyone in a session uses the host's relay automatically.", "Muted", true)
	var rr := _hrow(n)
	_line(rr, String(settings.relay_host), "relay.example.com", func(t):
		settings.relay_host = t.strip_edges()
		_save_settings())
	var rp := SpinBox.new()
	rp.min_value = 1
	rp.max_value = 65000
	rp.value = int(settings.relay_port)
	rp.value_changed.connect(func(v):
		settings.relay_port = int(v)
		_save_settings())
	rr.add_child(rp)
	_label(n, "Invite web page (optional): host web/join/index.html anywhere (e.g. GitHub Pages) and paste its URL so invites become clickable https links.", "Muted", true)
	_line(n, String(settings.web_link_base), "https://you.github.io/godot-coop/join/", func(t):
		settings.web_link_base = t.strip_edges()
		_save_settings())
	var lk := _card(_page)
	_label(lk, "Invite links", "Heading")
	_label(lk, "Make godotcoop:// links open this app when clicked (current Windows user only).", "Muted", true)
	_btn(lk, "Register godotcoop:// links", func():
		var err := Installer.register_url_scheme()
		toast("Links registered." if err.is_empty() else err))
	var rl := _card(_page)
	_label(rl, "Relay server", "Heading")
	_label(rl, "Run a relay on this computer for your team. Forward UDP ports %d-%d on your router (or run it on a cheap server with: GodotCoop.exe --headless -- --relay)." % [Util.DEFAULT_RELAY_PORT, Util.DEFAULT_RELAY_PORT + 1], "Muted", true)
	var cb := CheckBox.new()
	cb.text = "Run a relay server here (UDP %d)" % Util.DEFAULT_RELAY_PORT
	cb.button_pressed = relay != null
	cb.toggled.connect(_on_relay_toggled)
	rl.add_child(cb)
	if relay != null:
		var l := _label(rl, "", "Muted")
		l.name = "RelayStats"
		l.text = _relay_stats()
	var f := _card(_page, true)
	_label(f, "Downloaded projects go to", "Subheading")
	var fr := _hrow(f)
	_line(fr, String(settings.projects_dir), "", func(t):
		settings.projects_dir = t.strip_edges()
		_save_settings())


func _on_name_changed(t: String) -> void:
	profile.name = t.strip_edges()
	Util.save_profile(profile)
	var ml = find_child("MeLabel", true, false)
	if ml != null:
		ml.text = profile.name


func _on_relay_toggled(on: bool) -> void:
	settings.run_relay = on
	_save_settings()
	if on:
		_start_relay()
	else:
		_stop_relay()
	render()


func _relay_stats() -> String:
	if relay == null:
		return ""
	return "Running · %d session(s) · %s forwarded" % [relay.rooms.size(), Util.human_bytes(int(relay.stats.forwarded_bytes))]


func _start_relay() -> void:
	if relay != null:
		return
	relay = Relay.new()
	relay.log_fn = func(s): print("[relay] ", s)
	if relay.start(Util.DEFAULT_RELAY_PORT) != OK:
		toast("Couldn't open UDP %d for the relay." % Util.DEFAULT_RELAY_PORT)
		relay = null


func _stop_relay() -> void:
	if relay != null:
		relay.stop()
		relay = null


func _run_relay_cli(args: PackedStringArray) -> void:
	_relay_cli = true
	var port := Util.DEFAULT_RELAY_PORT
	var i := args.find("--port")
	if i != -1 and i + 1 < args.size() and args[i + 1].is_valid_int():
		port = int(args[i + 1])
	relay = Relay.new()
	relay.log_fn = func(s): print("[relay] ", s)
	if relay.start(port) != OK:
		printerr("Couldn't bind UDP %d" % port)
		get_tree().quit(1)
		return
	print("Godot Co-op relay %s running on UDP %d (+%d). Ctrl+C to stop." % [APP_VERSION, port, port + 1])


# ==================================================================================================
# Frame loop

func _process(_delta: float) -> void:
	if relay != null:
		relay.poll()
		if _relay_cli and Util.now_ms() - _relay_log_at > 60000:
			_relay_log_at = Util.now_ms()
			print("[relay] %s" % _relay_stats())
	if _relay_cli:
		return
	if _short_net != null:
		_short_net.net.poll()
		if _short_net != null and Util.now_ms() > int(_short_net.until):
			_short_net.net.stop()
			_short_net = null
			join_state = "error"
			join_error = "Couldn't reach the relay to look up that code."
			render()
	if join_session != null:
		join_session.poll()
	if _clone_thread != null and not _clone_thread.is_alive():
		var res: Dictionary = _clone_thread.wait_to_finish()
		_clone_thread = null
		if not res.get("ok", false):
			toast("git clone failed - downloading files directly instead.")
		_start_file_download()
	if _toast_label.visible and Util.now_ms() > _toast_until:
		_toast_label.visible = false
	var now := Util.now_ms()
	if now - _refresh_at > 1000:
		_refresh_at = now
		if screen == "session" or (screen == "join" and join_state == "plan" and installs.is_downloading()) or (screen == "versions" and installs.is_downloading()):
			render()
		elif screen == "settings" and relay != null:
			var l = find_child("RelayStats", true, false)
			if l != null:
				l.text = _relay_stats()
	if screen == "join" and join_state == "downloading":
		var pb = find_child("JoinProgress", true, false)
		var pl = find_child("JoinProgressLabel", true, false)
		if pb != null:
			pb.max_value = max(1, join_total_bytes)
			pb.value = join_done_bytes
		if pl != null:
			pl.text = "%s of %s  ·  %s" % [Util.human_bytes(join_done_bytes), Util.human_bytes(join_total_bytes), join_current]


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		if join_session != null and join_session.state in ["connected", "connecting", "waiting_approval"]:
			join_session.end_session("App closed", true)
		_stop_relay()
