extends RefCounted
## Installs the Godot Co-op editor plugin into a project and starts the editor.

const Util := preload("res://addons/godot_coop/core/util.gd")

const PAYLOAD_ZIP := "res://payload/godot_coop_addon.zip"
const PLUGIN_CFG := "res://addons/godot_coop/plugin.cfg"


## Copies addons/godot_coop into `project_dir` and enables it. Returns "" or an error message.
static func install_plugin(project_dir: String) -> String:
	if not FileAccess.file_exists(project_dir.path_join("project.godot")):
		return "No project.godot in that folder."
	var dest := project_dir.path_join("addons/godot_coop")
	var files := _payload_files()
	if files.is_empty():
		return "The plugin files are missing from this build of the app."
	for rel in files:
		var out := dest.path_join(rel)
		Util.ensure_dir(out.get_base_dir())
		var f := FileAccess.open(out, FileAccess.WRITE)
		if f == null:
			return "Couldn't write %s (%s)" % [out, error_string(FileAccess.get_open_error())]
		f.store_buffer(files[rel])
		f.close()
	var err := enable_plugin(project_dir)
	if not err.is_empty():
		return err
	Util.ensure_coop_dir(project_dir)
	return ""


## rel path (inside addons/godot_coop) -> bytes. Exported builds read a zip bundled with the app;
## running from source reads the addon folder directly.
static func _payload_files() -> Dictionary:
	var out := {}
	# (From source, a zip left over from an earlier build would install an outdated plugin.)
	if OS.has_feature("template") and FileAccess.file_exists(PAYLOAD_ZIP):
		var z := ZIPReader.new()
		if z.open(PAYLOAD_ZIP) == OK:
			for f in z.get_files():
				if not f.ends_with("/") and f.find("..") == -1:
					out[f] = z.read_file(f)
			z.close()
			if not out.is_empty():
				return out
	_collect("res://addons/godot_coop", "", out)
	return out


static func _collect(dir: String, rel: String, out: Dictionary) -> void:
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".uid") or f.ends_with(".import"):
			continue
		var bytes := FileAccess.get_file_as_bytes(dir.path_join(f))
		out[f if rel.is_empty() else rel + "/" + f] = bytes
	for d in DirAccess.get_directories_at(dir):
		_collect(dir.path_join(d), d if rel.is_empty() else rel + "/" + d, out)


## Adds our plugin to [editor_plugins] enabled=… without disturbing the rest of project.godot.
static func enable_plugin(project_dir: String) -> String:
	var path := project_dir.path_join("project.godot")
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		return "Couldn't read project.godot"
	if text.find(PLUGIN_CFG) != -1:
		return ""
	var lines := text.replace("\r\n", "\n").split("\n")
	var section := ""
	var done := false
	for i in lines.size():
		var l := lines[i].strip_edges()
		if l.begins_with("[") and l.ends_with("]"):
			section = l
			continue
		if section == "[editor_plugins]" and l.begins_with("enabled="):
			var inner := l.substr(l.find("(") + 1, l.rfind(")") - l.find("(") - 1).strip_edges()
			var entry := "\"%s\"" % PLUGIN_CFG
			lines[i] = "enabled=PackedStringArray(%s)" % (entry if inner.is_empty() else inner + ", " + entry)
			done = true
			break
	var result := "\n".join(lines)
	if not done:
		if text.find("[editor_plugins]") != -1:
			result = result.replace("[editor_plugins]", "[editor_plugins]\n\nenabled=PackedStringArray(\"%s\")" % PLUGIN_CFG)
		else:
			result = result.rstrip("\n") + "\n\n[editor_plugins]\n\nenabled=PackedStringArray(\"%s\")\n" % PLUGIN_CFG
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return "Couldn't write project.godot"
	f.store_string(result)
	f.close()
	return ""


static func write_launch(project_dir: String, data: Dictionary) -> void:
	var d := data.duplicate(true)
	d["created"] = Util.unix_time()
	Util.write_json(project_dir.path_join(".coop/launch.json"), d)


static func launch_editor(godot_exe: String, project_dir: String) -> int:
	var args := PackedStringArray(["--editor", "--path", project_dir])
	# Debugging aid: extra editor arguments separated by "|" (e.g. "--log-file|C:/tmp/editor.log").
	var extra := OS.get_environment("GODOT_COOP_EDITOR_ARGS")
	if not extra.is_empty():
		args.append_array(extra.split("|", false))
	return OS.create_process(godot_exe, args)


static func project_info(project_dir: String) -> Dictionary:
	if not FileAccess.file_exists(project_dir.path_join("project.godot")):
		return {}
	var cfg := ConfigFile.new()
	cfg.load(project_dir.path_join("project.godot"))
	var feats: PackedStringArray = cfg.get_value("application", "config/features", PackedStringArray())
	var dotnet := false
	for f in feats:
		if String(f) == "C#" or String(f) == "Mono":
			dotnet = true
	for f in DirAccess.get_files_at(project_dir):
		if f.ends_with(".csproj"):
			dotnet = true
	var plugins = cfg.get_value("editor_plugins", "enabled", PackedStringArray())
	return {
		"name": String(cfg.get_value("application", "config/name", project_dir.get_file())),
		"feature": Util.project_feature_version(project_dir),
		"dotnet": dotnet,
		"plugin_installed": FileAccess.file_exists(project_dir.path_join("addons/godot_coop/plugin.cfg")),
		"plugin_enabled": Array(plugins).has(PLUGIN_CFG),
	}


## Register godotcoop:// links (current user only, no admin needed). Windows only.
static func register_url_scheme() -> String:
	if OS.get_name() != "Windows":
		return "Link registration is only automated on Windows for now."
	var exe := OS.get_executable_path().replace("/", "\\")
	var cmd := "\"%s\"" % exe
	if OS.has_feature("editor") or not OS.has_feature("template"):
		cmd += " --path \"%s\"" % ProjectSettings.globalize_path("res://").trim_suffix("/").replace("/", "\\")
	cmd += " -- \"%1\""
	var esc := cmd.replace("\\", "\\\\").replace("\"", "\\\"")
	var reg := "Windows Registry Editor Version 5.00\r\n\r\n"
	reg += "[HKEY_CURRENT_USER\\Software\\Classes\\%s]\r\n@=\"URL:Godot Co-op invite\"\r\n\"URL Protocol\"=\"\"\r\n\r\n" % Util.URL_SCHEME
	reg += "[HKEY_CURRENT_USER\\Software\\Classes\\%s\\shell\\open\\command]\r\n@=\"%s\"\r\n" % [Util.URL_SCHEME, esc]
	var file := OS.get_user_data_dir().path_join("register_links.reg")
	var f := FileAccess.open(file, FileAccess.WRITE)
	if f == null:
		return "Couldn't write the registry file."
	f.store_buffer(PackedByteArray([0xFF, 0xFE]) + reg.to_utf16_buffer())
	f.close()
	var out := []
	var code := OS.execute("reg", ["import", file.replace("/", "\\")], out, true)
	if code != 0:
		return "Windows refused the change: %s" % (String(out[0]) if not out.is_empty() else str(code))
	return ""
