extends Node
## Finds Godot editors on this computer and downloads the exact version a session needs.

const Util := preload("res://addons/godot_coop/core/util.gd")

signal download_progress(done: int, total: int)
signal download_finished(ok: bool, path_or_error: String)

var installs: Array = []         # [{"path", "version": {major, minor, patch, status, dotnet}, "label"}]
var _http: HTTPRequest = null
var _dl_zip := ""
var _dl_target := ""
var _dl_version := {}


static func parse_version_from_name(file_name: String) -> Dictionary:
	var re := RegEx.new()
	re.compile("Godot_v(\\d+)\\.(\\d+)(?:\\.(\\d+))?-([a-z0-9]+)_(mono_)?")
	var m := re.search(file_name)
	if m == null:
		return {}
	return {
		"major": int(m.get_string(1)), "minor": int(m.get_string(2)),
		"patch": int(m.get_string(3)) if not m.get_string(3).is_empty() else 0,
		"status": m.get_string(4), "dotnet": not m.get_string(5).is_empty(),
	}


func _data_dir() -> String:
	return Util.shared_data_dir().path_join("godot")


func _settings() -> Dictionary:
	return Util.read_json(Util.shared_data_dir().path_join("settings.json"), {})


func scan() -> Array:
	var found := {}
	var roots: Array = []
	var s := _settings()
	for p in s.get("godot_paths", []):
		roots.append(String(p).get_base_dir())
	roots.append(_data_dir())
	var home := OS.get_environment("USERPROFILE")
	if home.is_empty():
		home = OS.get_environment("HOME")
	for sub in ["Downloads", "Desktop", "Documents", "Applications", "Programs", "Tools", "Godot", "scoop/apps"]:
		roots.append(home.path_join(sub))
	for p in ["C:/Program Files", "C:/Program Files (x86)/Steam/steamapps/common/Godot Engine", "C:/Godot", "D:/Godot", "/usr/local/bin", "/opt"]:
		roots.append(p)
	# The engine running this app is a candidate too when running from source.
	var me := OS.get_executable_path()
	if not parse_version_from_name(me.get_file()).is_empty():
		_consider(me, found)
	for r in roots:
		_scan_dir(String(r).replace("\\", "/"), 0, found)
	for p in s.get("godot_paths", []):
		if FileAccess.file_exists(String(p)):
			_consider(String(p), found)
	installs = found.values()
	installs.sort_custom(func(a, b): return Util.version_label(a.version) > Util.version_label(b.version))
	return installs


func _scan_dir(dir: String, depth: int, found: Dictionary) -> void:
	if depth > 3 or not DirAccess.dir_exists_absolute(dir):
		return
	for f in DirAccess.get_files_at(dir):
		if f.begins_with("Godot_v") and (f.ends_with(".exe") or f.ends_with(".x86_64") or f.ends_with(".arm64")) and f.find("console") == -1:
			_consider(dir.path_join(f), found)
	for d in DirAccess.get_directories_at(dir):
		var low := d.to_lower()
		if depth == 0 and not (low.begins_with("godot") or low.find("godot") != -1):
			continue
		if d.ends_with(".app"):
			continue
		_scan_dir(dir.path_join(d), depth + 1, found)


func _consider(path: String, found: Dictionary) -> void:
	var v := parse_version_from_name(path.get_file())
	if v.is_empty() and path.get_file().to_lower().begins_with("godot"):
		v = _version_by_running(path)
	if v.is_empty():
		return
	found[path] = {"path": path, "version": v, "label": Util.version_label(v)}


static func _version_by_running(path: String) -> Dictionary:
	var out := []
	if OS.execute(path, ["--version"], out, true) != 0 or out.is_empty():
		return {}
	var s := String(out[0]).strip_edges().split("\n")[-1]
	var parts := s.split(".")
	if parts.size() < 3 or not parts[0].is_valid_int():
		return {}
	var v := {"major": int(parts[0]), "minor": int(parts[1]), "patch": 0, "status": "stable", "dotnet": s.find("mono") != -1}
	if parts[2].is_valid_int():
		v.patch = int(parts[2])
		if parts.size() > 3:
			v.status = parts[3]
	else:
		v.status = parts[2]
	return v


func add_path(path: String) -> bool:
	var s := _settings()
	var paths: Array = s.get("godot_paths", [])
	if not paths.has(path):
		paths.append(path)
	s["godot_paths"] = paths
	Util.write_json(Util.shared_data_dir().path_join("settings.json"), s)
	scan()
	for i in installs:
		if i.path == path:
			return true
	return false


## Exact match (needed to join someone's session).
func find_exact(v: Dictionary) -> Dictionary:
	for i in installs:
		if Util.versions_match(i.version, v):
			return i
	return {}


## Any editor that can open a project declaring `feature` (e.g. "4.7"), newest stable first.
func find_for_feature(feature: String, dotnet := false) -> Array:
	var out := []
	var want := feature.split(".")
	for i in installs:
		var v: Dictionary = i.version
		if want.size() >= 2 and (int(want[0]) != int(v.major) or int(want[1]) != int(v.minor)):
			continue
		if bool(v.dotnet) != dotnet:
			continue
		out.append(i)
	out.sort_custom(func(a, b): return (a.version.status == "stable") and not (b.version.status == "stable") or a.version.patch > b.version.patch)
	return out


# --- downloads ----------------------------------------------------------------------------------

static func download_url(v: Dictionary) -> String:
	var ver := "%d.%d" % [int(v.major), int(v.minor)]
	if int(v.patch) > 0:
		ver += ".%d" % int(v.patch)
	var tag := "%s-%s" % [ver, String(v.status)]
	var mono := bool(v.get("dotnet", false))
	var file := ""
	match OS.get_name():
		"Windows":
			file = "Godot_v%s_mono_win64.zip" % tag if mono else "Godot_v%s_win64.exe.zip" % tag
		"macOS":
			file = "Godot_v%s_mono_macos.universal.zip" % tag if mono else "Godot_v%s_macos.universal.zip" % tag
		_:
			file = "Godot_v%s_mono_linux_x86_64.zip" % tag if mono else "Godot_v%s_linux.x86_64.zip" % tag
	return "https://github.com/godotengine/godot-builds/releases/download/%s/%s" % [tag, file]


func is_downloading() -> bool:
	return _http != null


func download(v: Dictionary) -> void:
	if _http != null:
		return
	_dl_version = v
	_dl_target = _data_dir().path_join(Util.version_label(v).replace(" (.NET)", "-dotnet").replace(" ", ""))
	Util.ensure_dir(_dl_target)
	_dl_zip = _dl_target.path_join("download.zip")
	_http = HTTPRequest.new()
	_http.download_file = _dl_zip
	_http.download_chunk_size = 262144
	_http.request_completed.connect(_on_done)
	add_child(_http)
	var err := _http.request(download_url(v))
	if err != OK:
		_finish(false, "Couldn't start the download (%s)" % error_string(err))


func _process(_delta: float) -> void:
	if _http != null:
		download_progress.emit(_http.get_downloaded_bytes(), _http.get_body_size())


func _on_done(result: int, code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		_finish(false, "Download failed (HTTP %d, result %d). Is that version published on github.com/godotengine/godot-builds?" % [code, result])
		return
	var exe := extract(_dl_zip, _dl_target)
	DirAccess.remove_absolute(_dl_zip)
	if exe.is_empty():
		_finish(false, "Downloaded, but couldn't find the editor inside the archive.")
		return
	add_path(exe)
	_finish(true, exe)


func _finish(ok: bool, msg: String) -> void:
	if _http != null:
		_http.queue_free()
		_http = null
	download_finished.emit(ok, msg)


## Unzips `zip_path` into `dest` and returns the editor executable's path ("" if none).
static func extract(zip_path: String, dest: String) -> String:
	var z := ZIPReader.new()
	if z.open(zip_path) != OK:
		return ""
	var exe := ""
	for f in z.get_files():
		if f.ends_with("/"):
			continue
		if f.find("..") != -1 or f.begins_with("/"):
			continue
		var out := dest.path_join(f)
		Util.ensure_dir(out.get_base_dir())
		var fa := FileAccess.open(out, FileAccess.WRITE)
		if fa == null:
			continue
		fa.store_buffer(z.read_file(f))
		fa.close()
		var name := f.get_file()
		if name.begins_with("Godot_v") and name.find("console") == -1 and (name.ends_with(".exe") or name.ends_with(".x86_64") or name.ends_with(".arm64")):
			exe = out
	z.close()
	if not exe.is_empty() and OS.get_name() != "Windows":
		OS.execute("chmod", ["+x", exe])
	return exe
