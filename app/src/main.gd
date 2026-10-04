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

const APP_VERSION := "1.1.2"
const LABEL_COLUMN := 230

var installs: Node = null
var profile := {}
var settings := {}
var screen := ""
var _page: VBoxContainer = null
var _scroll: ScrollContainer = null
var _nav := {}
var _toast: PanelContainer = null
var _toast_label: Label = null
var _toast_until := 0
var _refresh_at := 0
var _status_chip: PanelContainer = null
var _status_dot: Control = null
var _status_text: Label = null
var _avatar_slot: Control = null
var _relay_footer: Label = null
var _search: LineEdit = null

# hosting
var host_dir := ""
var hosted := {}
var _host_exe_pick: OptionButton = null
var _host_status := {}
var _status_sig := ""

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
	get_window().min_size = Vector2i(960, 640)
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
	var di := args.find("--demo")
	if di != -1 and di + 1 < args.size():
		_demo_state(args[di + 1])
	for i in 12:
		await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	img.save_png(path)
	get_tree().quit()


## Developer aid for screenshots: fills a screen with sample data (--demo session|plan|downloading|done).
func _demo_state(kind: String) -> void:
	var fake := {"major": 4, "minor": 7, "patch": 2, "status": "stable", "dotnet": false}
	match kind:
		"session":
			var d := OS.get_user_data_dir().path_join("demo_session")
			Util.write_json(d.path_join(".coop/status.json"), {
				"state": "hosting", "ready": true, "ts": Util.unix_time(), "short": "QD2J8QE5",
				"invite": "gdc1.AdMpmZN26uE_Eo_xyTFvE1GyY8iH5fwAAQENMTkyLjE2OC44Ni4zM-q6AAAAAApTdGFyc2hpcCBBcmVuYQ",
				"viewer_invite": "gdc1.x", "peers": [
					{"name": "Hana", "color": "ff6b6b", "role": "owner", "online": true},
					{"name": "Cole", "color": "4dabf7", "role": "editor", "online": true},
					{"name": "Rio", "color": "51cf66", "role": "viewer", "online": false}]})
			hosted = {"dir": d, "project": "Starship Arena", "pid": 0}
			show_screen("session")
		"plan", "downloading", "done":
			join_session = Session.new()
			join_session.host_info = {"project": "Starship Arena", "host_name": "Hana", "godot": fake,
				"git": {"ok": true, "remote": "https://example.com/starship.git", "branch": "main", "head": "1a2b3c4d5e6f"}}
			join_plan = {"count": 214, "total": 48230000, "risky": [
				["addons/dialogue/plugin.cfg", "Editor plugin manifest (enables a plugin that runs inside the editor)"],
				["tools/level_baker.gd", "@tool script (runs inside the editor)"]]}
			join_dest = String(settings.projects_dir).path_join("Starship Arena")
			join_done_bytes = 19400000
			join_total_bytes = 48230000
			join_current = "art/ship_hull.png"
			join_state = kind
			show_screen("join")


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
# Layout

func _build_layout() -> void:
	var bg := Panel.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	add_child(root)

	# Top app bar: brand, invite field, status, avatar.
	var top := PanelContainer.new()
	top.theme_type_variation = "TopBar"
	root.add_child(top)
	var th := HBoxContainer.new()
	th.add_theme_constant_override("separation", 12)
	top.add_child(th)
	var left := HBoxContainer.new()
	left.add_theme_constant_override("separation", 12)
	left.custom_minimum_size.x = 300
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	th.add_child(left)
	left.add_child(AppTheme.tile("Co", AppTheme.TILE_BLUE, 32))
	var brand := Label.new()
	brand.text = "Godot Co-op"
	brand.theme_type_variation = "Brand"
	left.add_child(brand)
	var search := PanelContainer.new()
	search.theme_type_variation = "Search"
	search.custom_minimum_size = Vector2(440, 34)
	th.add_child(search)
	var sh := HBoxContainer.new()
	sh.add_theme_constant_override("separation", 6)
	search.add_child(sh)
	var si := TextureRect.new()
	si.texture = AppTheme.icon("search", 16, AppTheme.MUTED)
	si.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	sh.add_child(si)
	_search = LineEdit.new()
	_search.theme_type_variation = "Flat"
	_search.placeholder_text = "Paste an invite code or link to join"
	_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search.text_submitted.connect(_on_search_submitted)
	sh.add_child(_search)
	var right := HBoxContainer.new()
	right.add_theme_constant_override("separation", 12)
	right.custom_minimum_size.x = 300
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.alignment = BoxContainer.ALIGNMENT_END
	th.add_child(right)
	th = right
	_status_chip = PanelContainer.new()
	_status_chip.theme_type_variation = "Chip"
	_status_chip.visible = false
	_status_chip.mouse_filter = Control.MOUSE_FILTER_STOP
	_status_chip.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_status_chip.gui_input.connect(_on_chip_input)
	th.add_child(_status_chip)
	var ch := HBoxContainer.new()
	ch.add_theme_constant_override("separation", 7)
	_status_chip.add_child(ch)
	_status_dot = _dot(AppTheme.GOOD_TEXT, 8)
	ch.add_child(_status_dot)
	_status_text = Label.new()
	_status_text.add_theme_font_override("font", AppTheme.semibold)
	_status_text.add_theme_font_size_override("font_size", 13)
	ch.add_child(_status_text)
	_avatar_slot = Control.new()
	_avatar_slot.custom_minimum_size = Vector2(32, 32)
	_avatar_slot.mouse_filter = Control.MOUSE_FILTER_STOP
	_avatar_slot.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_avatar_slot.gui_input.connect(_on_avatar_input)
	th.add_child(_avatar_slot)
	_refresh_avatar()

	# Body: side navigation + scrolling page.
	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 0)
	root.add_child(body)
	var side := PanelContainer.new()
	side.theme_type_variation = "Sidebar"
	side.custom_minimum_size.x = 236
	body.add_child(side)
	var sv := VBoxContainer.new()
	sv.add_theme_constant_override("separation", 2)
	side.add_child(sv)
	var group := ButtonGroup.new()
	_nav_section(sv, "COLLABORATE", false)
	for item in [["home", "Home", "home"], ["host", "Host a project", "host"], ["join", "Join a session", "join"], ["session", "Live session", "live"]]:
		_nav_item(sv, item, group)
	_nav_section(sv, "MANAGE", true)
	for item in [["versions", "Godot versions", "layers"], ["settings", "Settings", "settings"]]:
		_nav_item(sv, item, group)
	var fill := Control.new()
	fill.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sv.add_child(fill)
	_relay_footer = Label.new()
	_relay_footer.theme_type_variation = "Muted"
	_relay_footer.visible = false
	sv.add_child(_relay_footer)
	var ver := Label.new()
	ver.text = "Version " + APP_VERSION
	ver.theme_type_variation = "Caps"
	sv.add_child(ver)
	_scroll = ScrollContainer.new()
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body.add_child(_scroll)
	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.add_theme_constant_override("margin_left", 40)
	margin.add_theme_constant_override("margin_right", 40)
	margin.add_theme_constant_override("margin_top", 30)
	margin.add_theme_constant_override("margin_bottom", 40)
	_scroll.add_child(margin)
	_page = VBoxContainer.new()
	_page.add_theme_constant_override("separation", 18)
	_page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.add_child(_page)

	# Toast
	_toast = PanelContainer.new()
	var tsb := AppTheme._box(Color("#323232"), 8, Color("#454545"), 1, 0)
	tsb.content_margin_left = 14
	tsb.content_margin_right = 18
	tsb.content_margin_top = 10
	tsb.content_margin_bottom = 10
	tsb.shadow_color = Color(0, 0, 0, 0.45)
	tsb.shadow_size = 12
	_toast.add_theme_stylebox_override("panel", tsb)
	_toast.visible = false
	add_child(_toast)
	var tr := HBoxContainer.new()
	tr.add_theme_constant_override("separation", 10)
	_toast.add_child(tr)
	var ti := TextureRect.new()
	ti.texture = AppTheme.icon("check", 18, AppTheme.GOOD_TEXT)
	ti.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	tr.add_child(ti)
	_toast_label = Label.new()
	tr.add_child(_toast_label)


func _nav_section(parent: Control, text: String, gap: bool) -> void:
	if gap:
		var s := Control.new()
		s.custom_minimum_size.y = 16
		parent.add_child(s)
	var l := Label.new()
	l.text = text
	l.theme_type_variation = "Caps"
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", 12)
	m.add_theme_constant_override("margin_bottom", 6)
	m.add_child(l)
	parent.add_child(m)


func _nav_item(parent: Control, item: Array, group: ButtonGroup) -> void:
	var b := Button.new()
	b.text = item[1]
	b.icon = AppTheme.icon(item[2], 20)
	b.theme_type_variation = "Nav"
	b.toggle_mode = true
	b.button_group = group
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.custom_minimum_size.y = 38
	b.pressed.connect(show_screen.bind(item[0]))
	parent.add_child(b)
	_nav[item[0]] = b


func _refresh_avatar() -> void:
	for c in _avatar_slot.get_children():
		c.queue_free()
	var a := AppTheme.avatar(String(profile.get("name", "")), Util.color_of(profile), 32)
	_avatar_slot.add_child(a)
	_avatar_slot.tooltip_text = "%s · Settings" % profile.get("name", "")


func _on_search_submitted(t: String) -> void:
	if t.strip_edges().is_empty():
		return
	_search.clear()
	_search.release_focus()
	show_screen("join")
	_start_join(t)


func _on_avatar_input(e: InputEvent) -> void:
	if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
		show_screen("settings")


func _on_chip_input(e: InputEvent) -> void:
	if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
		show_screen("session" if not hosted.is_empty() else "join")


# ==================================================================================================
# Widgets

func _dot(color: Color, size := 10) -> Control:
	var p := Panel.new()
	p.add_theme_stylebox_override("panel", AppTheme._box(color, size, Color(0, 0, 0, 0), 0, 0))
	p.custom_minimum_size = Vector2(size, size)
	p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return p


func _label(parent: Control, text: String, variation := "", wrap := false) -> Label:
	var l := Label.new()
	l.text = text
	if not variation.is_empty():
		l.theme_type_variation = variation
	if wrap:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size.x = 160
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(l)
	return l


## kind: "" (outline), "Primary", "Quiet", "Link", "OnColor", "OnColorOutline".
func _btn(parent: Control, text: String, cb: Callable, kind := "", icon := "") -> Button:
	var b := Button.new()
	b.text = text
	if not kind.is_empty():
		b.theme_type_variation = kind
	if not icon.is_empty():
		b.icon = AppTheme.icon(icon, 18)
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	b.pressed.connect(cb)
	parent.add_child(b)
	return b


func _hrow(parent: Control, sep := 10) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", sep)
	parent.add_child(h)
	return h


func _spacer(parent: Control) -> void:
	var c := Control.new()
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(c)


## A card with an optional title line; returns the content box.
func _card(parent: Control, title := "", variation := "Card") -> VBoxContainer:
	var pc := PanelContainer.new()
	pc.theme_type_variation = variation
	pc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(pc)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 14)
	pc.add_child(v)
	if not title.is_empty():
		_label(v, title, "Heading")
	return v


func _hover(panel: PanelContainer, normal: String, hover: String) -> void:
	panel.mouse_entered.connect(func(): panel.theme_type_variation = hover)
	panel.mouse_exited.connect(func(): panel.theme_type_variation = normal)


func _line(parent: Control, text: String, placeholder: String, cb := Callable()) -> LineEdit:
	var e := LineEdit.new()
	e.text = text
	e.placeholder_text = placeholder
	e.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	e.custom_minimum_size.y = 34
	if cb.is_valid():
		e.text_changed.connect(cb)
	parent.add_child(e)
	return e


## Label column + control column, Spectrum form style. Returns the control column.
func _form_row(parent: Control, label: String, help := "") -> HBoxContainer:
	var h := _hrow(parent, 16)
	var lv := VBoxContainer.new()
	lv.custom_minimum_size.x = LABEL_COLUMN
	lv.add_theme_constant_override("separation", 2)
	h.add_child(lv)
	var l := _label(lv, label, "Body")
	l.add_theme_color_override("font_color", AppTheme.MUTED)
	if not help.is_empty():
		var hl := _label(lv, help, "Muted", true)
		hl.add_theme_color_override("font_color", AppTheme.FAINT)
		hl.add_theme_font_size_override("font_size", 12)
	var right := HBoxContainer.new()
	right.add_theme_constant_override("separation", 10)
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	h.add_child(right)
	return right


func _detail(parent: Control, key: String, value: String, color := AppTheme.TEXT) -> Label:
	var r := _form_row(parent, key)
	var v := _label(r, value, "", true)
	v.add_theme_color_override("font_color", color)
	return v


func _switch(parent: Control, text: String, on: bool, cb: Callable) -> CheckButton:
	var row := _hrow(parent, 10)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var s := CheckButton.new()
	s.button_pressed = on
	s.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	s.toggled.connect(cb)
	row.add_child(s)
	var l := _label(row, text, "Body", true)
	l.mouse_filter = Control.MOUSE_FILTER_STOP
	l.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	l.gui_input.connect(_on_switch_label_input.bind(s))
	return s


func _on_switch_label_input(e: InputEvent, s: CheckButton) -> void:
	if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
		s.button_pressed = not s.button_pressed


func _icon_rect(name: String, size: int, color: Color) -> TextureRect:
	var t := TextureRect.new()
	t.texture = AppTheme.icon(name, size, color)
	t.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	t.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return t


func _progress(parent: Control, value: float, max_value: float, indeterminate := false) -> ProgressBar:
	var pb := ProgressBar.new()
	pb.custom_minimum_size.y = 6
	pb.show_percentage = false
	pb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pb.max_value = max(1.0, max_value)
	pb.value = value
	pb.indeterminate = indeterminate
	parent.add_child(pb)
	return pb


func _initials(name: String) -> String:
	var words := name.strip_edges().replace("_", " ").split(" ", false)
	if words.is_empty():
		return "?"
	if words.size() == 1:
		return words[0].substr(0, 2).capitalize()
	return (words[0].substr(0, 1) + words[1].substr(0, 1)).to_upper()


func toast(text: String) -> void:
	_toast_label.text = text
	_toast.visible = true
	_toast.reset_size()
	_toast.position = Vector2((size.x - _toast.size.x + 236) * 0.5, size.y - _toast.size.y - 28)
	_toast_until = Util.now_ms() + 2800


func _copy(text: String, what: String) -> void:
	if text.is_empty():
		return
	DisplayServer.clipboard_set(text)
	toast("%s copied. Paste it to your teammate." % what)


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
	_scroll.scroll_vertical = 0
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
	_update_chrome()


## Top-bar status chip and sidebar footer.
func _update_chrome() -> void:
	var text := ""
	var col := AppTheme.GOOD_TEXT
	if not hosted.is_empty():
		var st: Dictionary = Util.read_json(String(hosted.dir).path_join(".coop/status.json"), {})
		var live: bool = not st.is_empty() and Util.unix_time() - float(st.get("ts", 0)) < 8.0 and st.get("state") == "hosting"
		var people := 0
		for p in st.get("peers", []):
			if p.get("online", false):
				people += 1
		text = "Live · %s · %d %s" % [hosted.project, people, "person" if people == 1 else "people"] if live else "Starting Godot · %s" % hosted.project
		col = AppTheme.GOOD_TEXT if live else AppTheme.WARN
	elif join_state == "downloading":
		var pct := int(100.0 * join_done_bytes / max(1, join_total_bytes))
		text = "Downloading · %d%%" % pct
		col = AppTheme.ACCENT_HOVER
	elif join_state in ["connecting", "approval", "loading_plan", "plan"]:
		text = "Joining a session"
		col = AppTheme.ACCENT_HOVER
	_status_chip.visible = not text.is_empty()
	_status_text.text = text
	_status_text.add_theme_color_override("font_color", AppTheme.BODY)
	(_status_dot.get_theme_stylebox("panel") as StyleBoxFlat).bg_color = col
	_relay_footer.visible = relay != null
	_relay_footer.text = "Relay running · %d session(s)" % relay.rooms.size() if relay != null else ""


func _page_header(title: String, subtitle := "") -> void:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	_page.add_child(v)
	_label(v, title, "Title")
	if not subtitle.is_empty():
		_label(v, subtitle, "Muted", true)


# ==================================================================================================
# Home

func _render_home() -> void:
	_page_header("Welcome back, %s" % String(profile.get("name", "there")), "Edit the same Godot project together, live.")
	var banner := AppTheme.banner(214)
	_page.add_child(banner)
	var bm := MarginContainer.new()
	for side in ["left", "right"]:
		bm.add_theme_constant_override("margin_" + side, 36)
	for side in ["top", "bottom"]:
		bm.add_theme_constant_override("margin_" + side, 30)
	banner.add_child(bm)
	var bh := HBoxContainer.new()
	bm.add_child(bh)
	var bv := VBoxContainer.new()
	bv.add_theme_constant_override("separation", 10)
	bv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bv.size_flags_stretch_ratio = 1.5
	bh.add_child(bv)
	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bh.add_child(gap)
	_label(bv, "Build together, live.", "Hero")
	_label(bv, "Scenes, scripts, files and project settings stay in sync between everyone's editor. Like Google Docs, for your game.", "HeroBody", true)
	var sp := Control.new()
	sp.custom_minimum_size.y = 6
	bv.add_child(sp)
	var br := _hrow(bv, 12)
	_btn(br, "Host a project", _home_host, "OnColor")
	_btn(br, "Join a session", show_screen.bind("join"), "OnColorOutline")

	_label(_page, "Quick actions", "Heading")
	var grid := _hrow(_page, 16)
	_action_card(grid, "Ho", AppTheme.TILE_BLUE, "Host a project", "Share a project from this PC. Teammates join with an invite code.", "Choose a project", _home_host)
	_action_card(grid, "Jn", AppTheme.TILE_GREEN, "Join a session", "Paste an invite. We download the project and the right Godot for you.", "Paste an invite", show_screen.bind("join"))
	var n: int = installs.installs.size()
	_action_card(grid, "Gd", AppTheme.TILE_PURPLE, "Godot versions", ("%d editor%s found on this PC." % [n, "" if n == 1 else "s"]) if n > 0 else "No editors found yet. Add or download one.", "Manage versions", show_screen.bind("versions"))

	_label(_page, "Recent", "Heading")
	var recent: Array = Util.read_json(Util.shared_data_dir().path_join("recent.json"), [])
	var rc := _card(_page)
	if recent.is_empty():
		_label(rc, "Projects you host or join appear here.", "Muted")
		return
	rc.add_theme_constant_override("separation", 2)
	var hdr := _hrow(rc, 16)
	var hm := MarginContainer.new()
	hm.add_theme_constant_override("margin_left", 10)
	hm.add_theme_constant_override("margin_right", 10)
	hm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hdr.add_child(hm)
	var hh := HBoxContainer.new()
	hh.add_theme_constant_override("separation", 16)
	hm.add_child(hh)
	_col(hh, "NAME", 0, 3.0)
	_col(hh, "TYPE", 90, 0.0)
	_col(hh, "LOCATION", 0, 4.0)
	_col(hh, "", 190, 0.0)
	for r in recent.slice(0, 8):
		_recent_row(rc, r)


func _col(parent: Control, text: String, width: int, ratio: float) -> Label:
	var l := Label.new()
	l.text = text
	l.theme_type_variation = "Caps"
	l.custom_minimum_size.x = width
	if ratio > 0.0:
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		l.size_flags_stretch_ratio = ratio
	parent.add_child(l)
	return l


func _recent_row(parent: Control, r: Dictionary) -> void:
	var row := PanelContainer.new()
	row.theme_type_variation = "Row"
	_hover(row, "Row", "RowHover")
	parent.add_child(row)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 16)
	row.add_child(h)
	var name_box := HBoxContainer.new()
	name_box.add_theme_constant_override("separation", 12)
	name_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_box.size_flags_stretch_ratio = 3.0
	h.add_child(name_box)
	var hosting: bool = r.get("kind") == "host"
	name_box.add_child(AppTheme.tile(_initials(String(r.get("project", "?"))), AppTheme.TILE_BLUE if hosting else AppTheme.TILE_GREEN, 32))
	var nl := _label(name_box, String(r.get("project", "?")), "Subheading")
	nl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	nl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var tb := MarginContainer.new()
	tb.custom_minimum_size.x = 90
	var bd := AppTheme.badge("Hosted" if hosting else "Joined", AppTheme.ACCENT_HOVER if hosting else AppTheme.GOOD_TEXT)
	bd.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	tb.add_child(bd)
	h.add_child(tb)
	var pl := _label(h, String(r.get("path", "")), "Muted")
	pl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	pl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pl.size_flags_stretch_ratio = 4.0
	pl.tooltip_text = String(r.get("path", ""))
	pl.mouse_filter = Control.MOUSE_FILTER_PASS
	var acts := HBoxContainer.new()
	acts.custom_minimum_size.x = 190
	acts.alignment = BoxContainer.ALIGNMENT_END
	acts.add_theme_constant_override("separation", 6)
	h.add_child(acts)
	if hosting:
		_btn(acts, "Host again", _host_again.bind(String(r.get("path", ""))))
	else:
		_btn(acts, "Open", _open_recent.bind(r))
	var fb := _btn(acts, "", func(): OS.shell_show_in_file_manager(String(r.get("path", ""))), "Quiet", "folder")
	fb.tooltip_text = "Show in folder"


func _action_card(parent: Control, mono: String, colors: Array, title: String, text: String, action: String, cb: Callable) -> void:
	var pc := PanelContainer.new()
	pc.theme_type_variation = "Card"
	pc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pc.mouse_filter = Control.MOUSE_FILTER_STOP
	pc.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_hover(pc, "Card", "CardHover")
	pc.gui_input.connect(_on_card_input.bind(cb))
	parent.add_child(pc)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pc.add_child(v)
	var t := AppTheme.tile(mono, colors, 48)
	t.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	v.add_child(t)
	var tl := _label(v, title, "Subheading")
	tl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var dl := _label(v, text, "Muted", true)
	dl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var push := Control.new()
	push.size_flags_vertical = Control.SIZE_EXPAND_FILL
	push.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(push)
	var b := _btn(v, action, cb, "Link", "arrow")
	b.icon_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	b.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN


func _on_card_input(e: InputEvent, cb: Callable) -> void:
	if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
		cb.call()


func _home_host() -> void:
	show_screen("host")
	if host_dir.is_empty():
		_choose_host_folder()


func _host_again(path: String) -> void:
	host_dir = path
	show_screen("host")


func _open_recent(r: Dictionary) -> void:
	var path := String(r.get("path", ""))
	var info := Installer.project_info(path)
	var exe := _pick_editor_for(String(info.get("feature", "")), bool(info.get("dotnet", false)))
	if exe.is_empty():
		toast("No matching Godot editor found. See Godot versions.")
		return
	Installer.launch_editor(exe, path)
	toast("Opening %s. Use Rejoin in the Co-op dock to reconnect." % r.get("project", ""))


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
	_page_header("Host a project", "Share a project from this PC. Godot opens with an invite code for your teammates.")
	var c := _card(_page, "Project")
	var fr := _form_row(c, "Project folder", "The folder that contains project.godot.")
	var path_edit := _line(fr, host_dir, "C:/Users/you/Documents/MyGame")
	path_edit.text_submitted.connect(func(t):
		host_dir = t.strip_edges().replace("\\", "/")
		render())
	_btn(fr, "Browse", _choose_host_folder, "", "folder")
	if host_dir.is_empty():
		_action_bar(false)
		return
	var info := Installer.project_info(host_dir)
	if info.is_empty():
		var w := _hrow(c, 8)
		w.add_child(_icon_rect("warning", 18, AppTheme.BAD))
		_label(w, "There's no project.godot in that folder.", "Body").add_theme_color_override("font_color", AppTheme.BAD)
		_action_bar(false)
		return
	c.add_child(HSeparator.new())
	_detail(c, "Project", String(info.name))
	_detail(c, "Made with", "Godot %s%s" % [info.feature, " (.NET)" if info.dotnet else ""])
	var matches: Array = installs.find_for_feature(String(info.feature), bool(info.dotnet))
	var er := _form_row(c, "Open with")
	_host_exe_pick = OptionButton.new()
	_host_exe_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_host_exe_pick.custom_minimum_size.y = 34
	for i in installs.installs:
		_host_exe_pick.add_item("Godot %s   %s" % [i.label, String(i.path).get_file()])
		_host_exe_pick.set_item_metadata(_host_exe_pick.item_count - 1, i.path)
		if not matches.is_empty() and i.path == matches[0].path:
			_host_exe_pick.select(_host_exe_pick.item_count - 1)
	er.add_child(_host_exe_pick)
	if matches.is_empty():
		var w := _hrow(c, 8)
		w.add_child(_icon_rect("warning", 18, AppTheme.WARN))
		_label(w, "None of your Godot editors match %s. Add or download one under Godot versions." % info.feature, "Body", true).add_theme_color_override("font_color", AppTheme.WARN)
	var pr := _form_row(c, "Co-op plugin")
	if info.plugin_installed:
		pr.add_child(AppTheme.badge("Installed", AppTheme.GOOD_TEXT))
	else:
		_label(pr, "Added to addons/godot_coop when you start. Teammates get it automatically.", "Body", true)
	var o := _card(_page, "Connection")
	_switch(o, "Open the port on my router automatically (UPnP)", bool(settings.use_upnp), func(on):
		settings.use_upnp = on
		_save_settings())
	_switch(o, "Let viewers (read-only invite) in without asking", bool(settings.auto_accept_viewers), func(on):
		settings.auto_accept_viewers = on
		_save_settings())
	if String(settings.relay_host).is_empty():
		_label(o, "On different networks, people connect directly when your router supports UPnP. For guaranteed connections and short codes, add a relay server in Settings.", "Muted", true)
	else:
		_label(o, "Relay %s:%d is used when a direct connection isn't possible." % [settings.relay_host, int(settings.relay_port)], "Muted", true)
	_action_bar(not installs.installs.is_empty())


func _action_bar(enabled: bool) -> void:
	var bar := _hrow(_page, 12)
	_spacer(bar)
	var go := _btn(bar, "Start hosting", _start_hosting, "Primary", "host")
	go.disabled = not enabled


func _start_hosting() -> void:
	var info := Installer.project_info(host_dir)
	if info.is_empty():
		return
	var exe := ""
	if _host_exe_pick != null and is_instance_valid(_host_exe_pick) and _host_exe_pick.selected >= 0:
		exe = String(_host_exe_pick.get_item_metadata(_host_exe_pick.selected))
	if exe.is_empty():
		exe = _pick_editor_for(String(info.feature), bool(info.dotnet))
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
			"web_link_base": String(settings.web_link_base), "include_loopback": bool(settings.get("include_loopback", false))},
	})
	var pid := Installer.launch_editor(exe, host_dir)
	if pid <= 0:
		toast("Couldn't start Godot.")
		return
	hosted = {"dir": host_dir, "project": info.name, "pid": pid, "started": Util.unix_time()}
	_add_recent("host", host_dir, String(info.name))
	show_screen("session")


# ==================================================================================================
# Live session (read from the editor plugin's .coop/status.json)

func _render_session() -> void:
	if hosted.is_empty():
		_page_header("Live session", "You're not hosting anything from this app right now.")
		return
	_host_status = Util.read_json(String(hosted.dir).path_join(".coop/status.json"), {})
	var fresh := not _host_status.is_empty() and Util.unix_time() - float(_host_status.get("ts", 0)) < 8.0
	var live: bool = fresh and _host_status.get("state") == "hosting"
	var head := _hrow(_page, 14)
	var hv := VBoxContainer.new()
	hv.add_theme_constant_override("separation", 4)
	hv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(hv)
	var tl := _hrow(hv, 12)
	_label(tl, "Hosting %s" % hosted.project, "Title")
	tl.add_child(AppTheme.badge("Live" if live else ("Starting" if not fresh else String(_host_status.get("state", "")).capitalize()), AppTheme.GOOD_TEXT if live else AppTheme.WARN))
	_label(hv, "Godot is open. You approve people inside Godot, in the Co-op dock." if live else "Godot is starting. The first launch imports the project, which can take a minute.", "Muted", true)
	var c := _card(_page, "Invite")
	if not fresh or not bool(_host_status.get("ready", false)):
		_label(c, "Preparing your invite. Checking your router and relay.", "Muted")
		_progress(c, 0, 1, true)
	else:
		var code := String(_host_status.get("invite", ""))
		var ce := LineEdit.new()
		ce.text = code
		ce.editable = false
		ce.custom_minimum_size.y = 40
		ce.add_theme_font_size_override("font_size", 13)
		c.add_child(ce)
		var r := _hrow(c, 10)
		_btn(r, "Copy invite", func(): _copy(code, "Invite code"), "Primary", "copy")
		_btn(r, "Copy link", func(): _copy(Invite.link(code), "Invite link"), "", "link")
		_btn(r, "Copy read-only invite", func(): _copy(String(_host_status.get("viewer_invite", "")), "Read-only invite"), "", "user")
		if not String(settings.web_link_base).is_empty():
			_btn(r, "Copy web link", func(): _copy(Invite.web_link(String(settings.web_link_base), code), "Web link"), "", "globe")
		var short := String(_host_status.get("short", ""))
		if not short.is_empty():
			c.add_child(HSeparator.new())
			var sr := _form_row(c, "Short code", "Works with this relay for 24 hours.")
			var sl := _label(sr, Invite.pretty_short_code(short), "Title")
			sl.add_theme_color_override("font_color", AppTheme.ACCENT_HOVER)
			var cb := _btn(sr, "", func(): _copy(Invite.pretty_short_code(short), "Short code"), "Quiet", "copy")
			cb.tooltip_text = "Copy short code"
		_label(c, "Send the code or link over Discord, email or anything else. Your teammate pastes it into Godot Co-op.", "Muted", true)
	var peers: Array = _host_status.get("peers", [])
	var pc := _card(_page, "People")
	if peers.is_empty():
		_label(pc, "Nobody here yet.", "Muted")
	for p in peers:
		var row := _hrow(pc, 12)
		var online: bool = p.get("online", false)
		row.add_child(AppTheme.avatar(String(p.get("name", "?")), Color.from_string(String(p.get("color", "fff")), Color.WHITE) if online else Color("#4a4a4a"), 30))
		var nl := _label(row, String(p.get("name", "?")), "Subheading")
		nl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var role := String(p.get("role", ""))
		row.add_child(AppTheme.badge({"owner": "Host", "editor": "Editor", "viewer": "Viewer"}.get(role, role.capitalize()), AppTheme.ACCENT_HOVER))
		row.add_child(AppTheme.badge("Online" if online else "Offline", AppTheme.GOOD_TEXT if online else AppTheme.MUTED))
	var br := _hrow(_page, 10)
	_btn(br, "Open project folder", func(): OS.shell_show_in_file_manager(String(hosted.dir)), "", "folder")
	_btn(br, "End session", _end_hosted_session, "", "stop")
	_spacer(br)
	_btn(br, "Forget this session", _forget_session, "Quiet")


func _end_hosted_session() -> void:
	Util.write_json(String(hosted.dir).path_join(".coop/control.json"), {"cmd": "end"})
	toast("Asked Godot to end the session.")


func _forget_session() -> void:
	hosted = {}
	show_screen("home")


func _session_signature() -> String:
	if hosted.is_empty():
		return ""
	var st: Dictionary = Util.read_json(String(hosted.dir).path_join(".coop/status.json"), {})
	var fresh := not st.is_empty() and Util.unix_time() - float(st.get("ts", 0)) < 8.0
	st.erase("ts")
	return JSON.stringify(st) + str(fresh)


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
		join_error = "Short codes are looked up on a relay server. Add one in Settings, or paste the full invite code."
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


func _cancel_and_render() -> void:
	_cancel_join()
	render()


func _waiting_card(title: String, text: String) -> void:
	var c := _card(_page)
	_label(c, title, "Heading")
	_label(c, text, "Muted", true)
	_progress(c, 0, 1, true)
	var r := _hrow(c)
	_btn(r, "Cancel", _cancel_and_render)


func _render_join() -> void:
	_page_header("Join a session", "Paste the invite your teammate sent. We download the project and open it in the right Godot.")
	match join_state:
		"", "error":
			var c := _card(_page)
			var fr := _form_row(c, "Invite", "A code, a godotcoop:// link, or a short code.")
			var e := _line(fr, join_code if join_state == "error" else "", "gdc1.…")
			e.text_submitted.connect(_start_join)
			_btn(fr, "Connect", func(): _start_join(e.text), "Primary")
			if join_state == "error":
				var w := _hrow(c, 8)
				w.add_child(_icon_rect("warning", 18, AppTheme.BAD))
				_label(w, join_error, "Body", true).add_theme_color_override("font_color", AppTheme.BAD)
		"connecting":
			_waiting_card("Reaching the host", "Trying a direct connection first, then the relay if there is one.")
		"approval":
			_waiting_card("Waiting for the host to let you in", "They'll see your request inside Godot.")
		"loading_plan":
			_waiting_card("You're in", "Checking what needs to be downloaded.")
		"plan":
			_render_join_plan()
		"downloading":
			_render_join_progress()
		"done":
			var c := _card(_page)
			var h := _hrow(c, 16)
			h.add_child(AppTheme.icon_tile("check", AppTheme.TILE_GREEN, 48))
			var v := VBoxContainer.new()
			v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			h.add_child(v)
			_label(v, "You're in", "Heading")
			_label(v, "Godot is opening %s and connects to the session by itself. The first launch imports the project, which can take a minute." % join_session_project(), "Muted", true)
			var r := _hrow(c, 10)
			_btn(r, "Open project folder", func(): OS.shell_show_in_file_manager(join_dest), "", "folder")
			_btn(r, "Back to home", _back_home, "Quiet")


func _back_home() -> void:
	join_state = ""
	show_screen("home")


func join_session_project() -> String:
	if join_session != null:
		return String(join_session.host_info.get("project", "the project"))
	return "the project"


func _render_join_plan() -> void:
	var s = join_session
	var hi: Dictionary = s.host_info
	var need: Dictionary = hi.get("godot", {})
	var c := _card(_page)
	var head := _hrow(c, 14)
	head.add_child(AppTheme.tile(_initials(String(hi.get("project", "?"))), AppTheme.TILE_BLUE, 48))
	var hv := VBoxContainer.new()
	hv.add_theme_constant_override("separation", 2)
	head.add_child(hv)
	_label(hv, String(hi.get("project", "")), "Heading")
	_label(hv, "Hosted by %s" % hi.get("host_name", "your teammate"), "Muted")
	c.add_child(HSeparator.new())
	var count := int(join_plan.get("count", 0))
	var total := int(join_plan.get("total", 0))
	_detail(c, "To download", ("%d files, %s" % [count, Util.human_bytes(total)]) if count > 0 else "Nothing. You're up to date.")
	var exact: Dictionary = installs.find_exact(need)
	var vr := _form_row(c, "Godot version")
	_label(vr, Util.version_label(need))
	vr.add_child(AppTheme.badge("Installed" if not exact.is_empty() else "Not installed", AppTheme.GOOD_TEXT if not exact.is_empty() else AppTheme.WARN))
	if exact.is_empty():
		var dr := _form_row(c, "")
		if installs.is_downloading():
			var dv := VBoxContainer.new()
			dv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			dr.add_child(dv)
			_progress(dv, _dl_progress.x, _dl_progress.y)
			_label(dv, "%s of %s" % [Util.human_bytes(_dl_progress.x), Util.human_bytes(_dl_progress.y)], "Muted")
		else:
			_btn(dr, "Download Godot %s" % Util.version_label(need), _download_version.bind(need), "Primary", "download")
			_btn(dr, "Locate it", _locate_editor, "", "folder")
		if not _dl_msg.is_empty():
			_label(c, _dl_msg, "Muted", true)
	var sr := _form_row(c, "Save to")
	var de := _line(sr, join_dest, "")
	de.text_submitted.connect(_set_join_dest)
	_btn(sr, "Change", func(): _pick_folder("Where should the project go?", String(settings.projects_dir), _set_join_dest), "", "folder")
	var git: Dictionary = hi.get("git", {})
	if git.get("ok", false) and not String(git.get("remote", "")).is_empty() and Git.available():
		var gr := _form_row(c, "Git")
		_switch(gr, "Clone the repository first (%s at %s) so your history matches" % [git.get("branch", ""), String(git.get("head", "")).substr(0, 8)], join_clone, func(on): join_clone = on)
	var risky: Array = join_plan.get("risky", [])
	if not risky.is_empty():
		var rc := _card(_page, "", "Callout")
		var rh := _hrow(rc, 12)
		var wi := _icon_rect("warning", 22, AppTheme.WARN)
		wi.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		rh.add_child(wi)
		var rv := VBoxContainer.new()
		rv.add_theme_constant_override("separation", 8)
		rv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		rh.add_child(rv)
		_label(rv, "%d file%s in this project can run code inside Godot" % [risky.size(), "" if risky.size() == 1 else "s"], "Subheading")
		_label(rv, "Editor plugins, @tool scripts and native libraries run as soon as Godot opens the project. Only continue if you trust %s." % hi.get("host_name", "the host"), "Muted", true)
		var list := RichTextLabel.new()
		list.fit_content = true
		list.bbcode_enabled = true
		list.scroll_active = false
		var t := ""
		for r in risky.slice(0, 30):
			t += "[b]%s[/b]   [color=#9b9b9b]%s[/color]\n" % [String(r[0]).replace("[", "[lb]"), r[1]]
		if risky.size() > 30:
			t += "[color=#9b9b9b]and %d more[/color]" % (risky.size() - 30)
		list.text = t
		rv.add_child(list)
		var tc := CheckBox.new()
		tc.text = "I trust %s. Allow these files." % hi.get("host_name", "the host")
		tc.button_pressed = join_trust
		tc.toggled.connect(func(on):
			join_trust = on
			render())
		rv.add_child(tc)
	var bar := _hrow(_page, 12)
	if exact.is_empty():
		_label(bar, "Install Godot %s first. Everyone in a session needs the exact same version." % Util.version_label(need), "Muted", true)
	else:
		_spacer(bar)
	_btn(bar, "Cancel", _cancel_and_render)
	var go := _btn(bar, "Download and open in Godot", _begin_download, "Primary", "download")
	go.disabled = exact.is_empty() or (not risky.is_empty() and not join_trust)


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
		join_current = "Cloning the git repository"
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
	var h := _hrow(c, 12)
	_label(h, "Downloading %s" % join_session_project(), "Heading")
	_spacer(h)
	var pct := _label(h, "0%", "Heading")
	pct.name = "JoinPercent"
	pct.add_theme_color_override("font_color", AppTheme.ACCENT_HOVER)
	var pb := _progress(c, join_done_bytes, join_total_bytes)
	pb.name = "JoinProgress"
	var l := _label(c, "", "Muted")
	l.name = "JoinProgressLabel"
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_update_join_progress()


func _update_join_progress() -> void:
	var pb = find_child("JoinProgress", true, false)
	var pl = find_child("JoinProgressLabel", true, false)
	var pc = find_child("JoinPercent", true, false)
	if pb != null:
		pb.max_value = max(1, join_total_bytes)
		pb.value = join_done_bytes
	if pc != null:
		pc.text = "%d%%" % int(100.0 * join_done_bytes / max(1, join_total_bytes))
	if pl != null:
		pl.text = "%s of %s%s" % [Util.human_bytes(join_done_bytes), Util.human_bytes(join_total_bytes), ("    " + join_current) if not join_current.is_empty() else ""]


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
	_page_header("Godot versions", "Everyone in a session needs the exact same Godot version. We find the editors on this PC and can download any official build.")
	var c := _card(_page)
	var head := _hrow(c, 8)
	_label(head, "Installed", "Heading")
	_spacer(head)
	_btn(head, "Add an editor", _locate_editor, "Quiet", "plus")
	_btn(head, "Rescan", _rescan, "Quiet", "refresh")
	if installs.installs.is_empty():
		_label(c, "No Godot editors found on this PC yet.", "Muted")
	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 2)
	c.add_child(list)
	for i in installs.installs:
		var row := PanelContainer.new()
		row.theme_type_variation = "Row"
		_hover(row, "Row", "RowHover")
		list.add_child(row)
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 14)
		row.add_child(h)
		var v: Dictionary = i.version
		h.add_child(AppTheme.tile("%d.%d" % [int(v.major), int(v.minor)], AppTheme.TILE_PURPLE if v.get("dotnet", false) else AppTheme.TILE_BLUE, 38))
		var tv := VBoxContainer.new()
		tv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tv.add_theme_constant_override("separation", 0)
		h.add_child(tv)
		_label(tv, "Godot " + String(i.label), "Subheading")
		var pl := _label(tv, String(i.path), "Muted")
		pl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		var sb := _btn(h, "", func(): OS.shell_show_in_file_manager(String(i.path)), "Quiet", "folder")
		sb.tooltip_text = "Show in folder"
	var d := _card(_page, "Download a version")
	var dr := _form_row(d, "Version", "For example 4.7.2-stable or 4.8-beta1.")
	var ve := _line(dr, "4.7.2-stable", "4.7.2-stable")
	var net := CheckBox.new()
	net.text = ".NET (C#)"
	dr.add_child(net)
	_btn(dr, "Download", _download_typed_version.bind(ve, net), "Primary", "download")
	if installs.is_downloading():
		_progress(d, _dl_progress.x, _dl_progress.y)
		_label(d, "%s of %s" % [Util.human_bytes(_dl_progress.x), Util.human_bytes(_dl_progress.y)], "Muted")
	if not _dl_msg.is_empty():
		_label(d, _dl_msg, "Muted", true)


func _rescan() -> void:
	installs.scan()
	render()


func _download_typed_version(ve: LineEdit, net: CheckBox) -> void:
	var v := _parse_version(ve.text, net.button_pressed)
	if v.is_empty():
		toast("Use a version like 4.7.2-stable.")
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
	_page_header("Settings")
	var p := _card(_page, "Profile")
	var cr := _form_row(p, "Colour", "How teammates see you.")
	var cp := ColorPickerButton.new()
	cp.color = Util.color_of(profile)
	cp.edit_alpha = false
	cp.custom_minimum_size = Vector2(56, 34)
	cp.color_changed.connect(func(col):
		profile.color = col.to_html(false)
		Util.save_profile(profile)
		_refresh_avatar())
	cr.add_child(cp)
	_line(_form_row(p, "Name"), String(profile.get("name", "")), "Your name", _on_name_changed)
	_line(_form_row(p, "Email", "Optional. Used for git co-author credit."), String(profile.get("email", "")), "you@example.com", func(t):
		profile.email = t.strip_edges()
		Util.save_profile(profile))
	var n := _card(_page, "Network")
	var rr := _form_row(n, "Relay server", "Optional. Lets people connect through any firewall and enables short codes.")
	_line(rr, String(settings.relay_host), "relay.example.com", func(t):
		settings.relay_host = t.strip_edges()
		_save_settings())
	var rp := SpinBox.new()
	rp.min_value = 1
	rp.max_value = 65000
	rp.value = int(settings.relay_port)
	rp.custom_minimum_size.x = 110
	rp.value_changed.connect(func(v):
		settings.relay_port = int(v)
		_save_settings())
	rr.add_child(rp)
	_line(_form_row(n, "Invite web page", "Optional. Host web/join/index.html anywhere so invites become clickable https links."), String(settings.web_link_base), "https://you.github.io/godot-coop/join/", func(t):
		settings.web_link_base = t.strip_edges()
		_save_settings())
	var pr := _form_row(n, "Host port", "UDP port used when you host.")
	var ps := SpinBox.new()
	ps.min_value = 1024
	ps.max_value = 65000
	ps.value = int(settings.port)
	ps.custom_minimum_size.x = 110
	ps.value_changed.connect(func(v):
		settings.port = int(v)
		_save_settings())
	pr.add_child(ps)
	var lk := _card(_page, "Invite links")
	var lr := _form_row(lk, "godotcoop:// links", "Makes invite links open this app. Current Windows user only.")
	_btn(lr, "Register links", _register_links, "", "link")
	var rl := _card(_page, "Relay server")
	var rs := _form_row(rl, "Run here", "Forward UDP ports %d and %d on your router. On a server, run: GodotCoop.console.exe --headless -- --relay" % [Util.DEFAULT_RELAY_PORT, Util.DEFAULT_RELAY_PORT + 1])
	_switch(rs, "Run a relay server on this PC (UDP %d)" % Util.DEFAULT_RELAY_PORT, relay != null, _on_relay_toggled)
	if relay != null:
		var l := _label(rl, _relay_stats(), "Muted")
		l.name = "RelayStats"
	var f := _card(_page, "Storage")
	var fr := _form_row(f, "Downloaded projects", "Where projects you join are saved.")
	var fe := _line(fr, String(settings.projects_dir), "", func(t):
		settings.projects_dir = t.strip_edges()
		_save_settings())
	_btn(fr, "Browse", _browse_projects_dir.bind(fe), "", "folder")


func _register_links() -> void:
	var err := Installer.register_url_scheme()
	toast("Links registered." if err.is_empty() else err)


func _browse_projects_dir(fe: LineEdit) -> void:
	_pick_folder("Downloaded projects folder", String(settings.projects_dir), _set_projects_dir.bind(fe))


func _set_projects_dir(d: String, fe: LineEdit) -> void:
	settings.projects_dir = d.replace("\\", "/")
	_save_settings()
	if is_instance_valid(fe):
		fe.text = settings.projects_dir


func _on_name_changed(t: String) -> void:
	profile.name = t.strip_edges()
	Util.save_profile(profile)
	_refresh_avatar()


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
	print("Godot Co-op relay %s running on UDP %d (+%d). Press Ctrl+C to stop." % [APP_VERSION, port, port + 1])


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
			toast("git clone failed, so the files are being downloaded directly.")
		_start_file_download()
	if _toast.visible and Util.now_ms() > _toast_until:
		_toast.visible = false
	var now := Util.now_ms()
	if now - _refresh_at > 1000:
		_refresh_at = now
		if screen == "session":
			var sig := _session_signature()
			if sig != _status_sig:
				_status_sig = sig
				render()
		elif (screen == "join" and join_state == "plan" and installs.is_downloading()) or (screen == "versions" and installs.is_downloading()):
			render()
		elif screen == "settings" and relay != null:
			var l = find_child("RelayStats", true, false)
			if l != null:
				l.text = _relay_stats()
		_update_chrome()
	if screen == "join" and join_state == "downloading":
		_update_join_progress()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		if join_session != null and join_session.state in ["connected", "connecting", "waiting_approval"]:
			join_session.end_session("App closed", true)
		_stop_relay()
