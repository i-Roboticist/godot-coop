@tool
extends RefCounted
## Small shared helpers. Everything here is static so any script can use it via preload().

const APP_NAME := "Godot Co-op"
const ADDON_PATH := "addons/godot_coop"
const COOP_DIR := ".coop"
const PROTOCOL_VERSION := 2
const URL_SCHEME := "godotcoop"
const DEFAULT_PORT := 47500
const DEFAULT_RELAY_PORT := 47600

## Folders that are never synced (first path segment).
const IGNORED_ROOTS := [".godot", ".git", ".coop", ".svn", ".hg", ".import", ".mono", ".vs", ".idea"]
## File names that are never synced.
const IGNORED_FILES := ["thumbs.db", ".ds_store", "desktop.ini", ".coopignore.local"]   # compared lowercased
## Folders never synced at any depth (a nested repository's hooks would run code).
const IGNORED_ANYWHERE := [".git", ".svn", ".hg", ".coop"]
const RESERVED_NAMES := ["CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$",
	"COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
	"LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"]

const USER_COLORS := [
	Color("#ff6b6b"), Color("#4dabf7"), Color("#51cf66"), Color("#fcc419"),
	Color("#cc5de8"), Color("#ff922b"), Color("#22b8cf"), Color("#f06595"),
	Color("#94d82d"), Color("#845ef7"),
]


static func now_ms() -> int:
	return Time.get_ticks_msec()


static func unix_time() -> float:
	return Time.get_unix_time_from_system()


static func clock_string(unix: float) -> String:
	var dt := Time.get_datetime_dict_from_unix_time(int(unix + _tz_offset_seconds()))
	return "%02d:%02d" % [dt.hour, dt.minute]


static func _tz_offset_seconds() -> int:
	var tz := Time.get_time_zone_from_system()
	return int(tz.get("bias", 0)) * 60


static func random_bytes(n: int) -> PackedByteArray:
	return Crypto.new().generate_random_bytes(n)


static func random_hex(n_bytes: int) -> String:
	return random_bytes(n_bytes).hex_encode()


static func b64url_encode(data: PackedByteArray) -> String:
	return Marshalls.raw_to_base64(data).replace("+", "-").replace("/", "_").replace("=", "")


static func b64url_decode(s: String) -> PackedByteArray:
	var t := s.strip_edges().replace("-", "+").replace("_", "/")
	for c in t:
		if not (c in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"):
			return PackedByteArray()
	while t.length() % 4 != 0:
		t += "="
	return Marshalls.base64_to_raw(t)


static func sha256_hex(data: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(data)
	return ctx.finish().hex_encode()


static func file_hash(abs_path: String) -> String:
	if not FileAccess.file_exists(abs_path):
		return ""
	return FileAccess.get_sha256(abs_path)


## Same value and same type (plain `==` errors on some mixed-type comparisons).
static func same(a, b) -> bool:
	return typeof(a) == typeof(b) and a == b


## A project-relative path coming from the network must pass this before we touch the disk.
static func is_safe_rel_path(p: String) -> bool:
	if p.is_empty() or p.length() > 400:
		return false
	if p.begins_with("/"):
		return false
	for i in p.length():
		var ch := p.unicode_at(i)
		# Control characters, and characters Windows can't have in a name (\ : * ? " < > |).
		if ch < 32 or ch == 127 or "\\:*?\"<>|".contains(char(ch)):
			return false
	for part in p.split("/"):
		if part == "" or part == "." or part == "..":
			return false
		if part.ends_with(" ") or part.ends_with("."):
			return false
		if part.length() > 200:
			return false
		# Windows device names, whatever follows the first dot ("NUL.tar.gz" is still NUL).
		if part.get_slice(".", 0).to_upper() in RESERVED_NAMES:
			return false
	return true


## res:// path coming from the network (resource references inside scenes).
static func is_safe_res_path(p: String) -> bool:
	if not p.begins_with("res://") and not p.begins_with("uid://"):
		return false
	if p.begins_with("uid://"):
		return p.length() < 64
	return is_safe_rel_path(p.substr(6))


static func res_to_rel(p: String) -> String:
	return p.substr(6) if p.begins_with("res://") else p


static func rel_to_res(p: String) -> String:
	return "res://" + p


static func is_ignored(rel: String, patterns: PackedStringArray = PackedStringArray()) -> bool:
	# Compared without case: on Windows and macOS ".Coop/prefs.json" *is* ".coop/prefs.json".
	var low := rel.to_lower()
	var parts := low.split("/")
	if parts[0] in IGNORED_ROOTS:
		return true
	for i in parts.size() - 1:
		if parts[i] in IGNORED_ANYWHERE:
			return true
	if low.begins_with(ADDON_PATH + "/"):
		return true
	var fname := rel.get_file()
	if fname.to_lower() in IGNORED_FILES or fname.begins_with("._"):
		return true
	if fname.ends_with(".tmp") or fname.ends_with("~") or fname.begins_with("~$") or fname.ends_with(".part"):
		return true
	for pat in patterns:
		if pat.is_empty():
			continue
		if pat.ends_with("/"):
			if rel.begins_with(pat) or ("/" + rel).find("/" + pat) != -1:
				return true
		elif rel.match(pat) or fname.match(pat):
			return true
	return false


static func read_ignore_patterns(project_dir: String) -> PackedStringArray:
	var out := PackedStringArray()
	var p := project_dir.path_join(".coopignore")
	if FileAccess.file_exists(p):
		for line in FileAccess.get_file_as_string(p).split("\n"):
			var l := line.strip_edges()
			if l.is_empty() or l.begins_with("#"):
				continue
			out.append(l.trim_prefix("/"))
	return out


static func ensure_dir(abs_dir: String) -> void:
	if not DirAccess.dir_exists_absolute(abs_dir):
		DirAccess.make_dir_recursive_absolute(abs_dir)


## Creates <project>/.coop with marker files so neither Godot's importer nor git looks inside.
static func ensure_coop_dir(project_dir: String) -> String:
	var d := project_dir.path_join(COOP_DIR)
	ensure_dir(d)
	if not FileAccess.file_exists(d.path_join(".gdignore")):
		var f := FileAccess.open(d.path_join(".gdignore"), FileAccess.WRITE)
		if f != null:
			f.close()
	if not FileAccess.file_exists(d.path_join(".gitignore")):
		var g := FileAccess.open(d.path_join(".gitignore"), FileAccess.WRITE)
		if g != null:
			g.store_string("*\n")
			g.close()
	return d


static func read_json(abs_path: String, fallback = {}):
	if not FileAccess.file_exists(abs_path):
		return fallback
	var txt := FileAccess.get_file_as_string(abs_path)
	if txt.is_empty():
		return fallback
	var j := JSON.new()
	if j.parse(txt) != OK:
		return fallback
	return j.data


static func write_json(abs_path: String, data) -> bool:
	ensure_dir(abs_path.get_base_dir())
	var tmp := abs_path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(data, "\t"))
	f.close()
	return DirAccess.rename_absolute(tmp, abs_path) == OK


## Write bytes atomically (temp file + rename).
static func write_bytes_atomic(abs_path: String, data: PackedByteArray) -> bool:
	ensure_dir(abs_path.get_base_dir())
	var tmp := abs_path + "." + random_hex(3) + ".part"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return false
	f.store_buffer(data)
	f.close()
	if DirAccess.rename_absolute(tmp, abs_path) != OK:
		DirAccess.remove_absolute(tmp)
		return false
	return true


static func move_file(from_abs: String, to_abs: String) -> bool:
	ensure_dir(to_abs.get_base_dir())
	return DirAccess.rename_absolute(from_abs, to_abs) == OK


static func normalize_ip(addr: String) -> String:
	if addr.begins_with("::ffff:"):
		return addr.substr(7)
	return addr


static func is_ipv4(addr: String) -> bool:
	var parts := addr.split(".")
	if parts.size() != 4:
		return false
	for p in parts:
		if not p.is_valid_int() or int(p) < 0 or int(p) > 255:
			return false
	return true


static func _is_private_v4(a: String) -> bool:
	if a.begins_with("10.") or a.begins_with("192.168."):
		return true
	if a.begins_with("172."):
		var second := int(a.get_slice(".", 1))
		return second >= 16 and second <= 31
	return false


## Local IPv4 addresses that a teammate might be able to reach (LAN first, then VPN-ish ones).
static func reachable_ipv4s(max_count := 4) -> PackedStringArray:
	var lan := PackedStringArray()
	var other := PackedStringArray()
	for a in IP.get_local_addresses():
		if not is_ipv4(a):
			continue
		if a.begins_with("127.") or a.begins_with("169.254.") or a.begins_with("0."):
			continue
		if _is_private_v4(a):
			lan.append(a)
		else:
			other.append(a)
	var out := lan + other
	if out.size() > max_count:
		out = out.slice(0, max_count)
	return out


static func human_bytes(n: int) -> String:
	if n < 1024:
		return "%d B" % n
	if n < 1024 * 1024:
		return "%.1f KB" % (n / 1024.0)
	if n < 1024 * 1024 * 1024:
		return "%.1f MB" % (n / 1048576.0)
	return "%.2f GB" % (n / 1073741824.0)


## Directory shared by the companion app and the editor plugin (profile, Godot installs).
static func shared_data_dir() -> String:
	var d := OS.get_data_dir().path_join("GodotCoop")
	var override := OS.get_environment("GODOT_COOP_DATA_DIR")
	if not override.is_empty():
		d = override
	ensure_dir(d)
	return d


static func load_profile() -> Dictionary:
	var p: Dictionary = read_json(shared_data_dir().path_join("profile.json"), {})
	if not p.has("uuid"):
		p["uuid"] = random_hex(8)
	if String(p.get("name", "")).strip_edges().is_empty():
		var user := OS.get_environment("USERNAME")
		if user.is_empty():
			user = OS.get_environment("USER")
		p["name"] = user if not user.is_empty() else "Player"
	if not p.has("color"):
		p["color"] = USER_COLORS[randi() % USER_COLORS.size()].to_html(false)
	if not p.has("email"):
		p["email"] = git_config_email()
	return p


static func save_profile(p: Dictionary) -> void:
	write_json(shared_data_dir().path_join("profile.json"), p)


static func git_config_email() -> String:
	var out := []
	var code := OS.execute("git", ["config", "--global", "user.email"], out, true)
	if code != 0 or out.is_empty():
		return ""
	return String(out[0]).strip_edges()


## Godot version as a comparable dictionary (works for the current engine).
static func engine_version() -> Dictionary:
	var v := Engine.get_version_info()
	return {
		"major": v.major, "minor": v.minor, "patch": v.patch, "status": String(v.status),
		"dotnet": ClassDB.class_exists("CSharpScript"),
	}


static func version_label(v: Dictionary) -> String:
	if v.is_empty():
		return "?"
	var s := "%d.%d" % [int(v.get("major", 0)), int(v.get("minor", 0))]
	if int(v.get("patch", 0)) > 0:
		s += ".%d" % int(v.get("patch", 0))
	s += "-" + String(v.get("status", "stable"))
	if v.get("dotnet", false):
		s += " (.NET)"
	return s


static func versions_match(a: Dictionary, b: Dictionary) -> bool:
	for k in ["major", "minor", "patch", "status", "dotnet"]:
		if not same(a.get(k), b.get(k)):
			return false
	return true


static func project_name_from_dir(project_dir: String) -> String:
	var cfg := ConfigFile.new()
	if cfg.load(project_dir.path_join("project.godot")) == OK:
		return String(cfg.get_value("application", "config/name", project_dir.get_file()))
	return project_dir.get_file()


## Reads the minimum engine version declared in project.godot's config/features ("4.7").
static func project_feature_version(project_dir: String) -> String:
	var cfg := ConfigFile.new()
	if cfg.load(project_dir.path_join("project.godot")) != OK:
		return ""
	var feats = cfg.get_value("application", "config/features", PackedStringArray())
	for f in feats:
		var s := String(f)
		if s.length() >= 3 and s[0].is_valid_int() and s.find(".") != -1:
			return s
	return ""


static func color_of(peer: Dictionary) -> Color:
	return Color.from_string(String(peer.get("color", "ffffff")), Color.WHITE)


static func short_text(s: String, n := 60) -> String:
	s = s.replace("\n", " ")
	return s if s.length() <= n else s.substr(0, n - 1) + "…"
