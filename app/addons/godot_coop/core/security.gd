@tool
extends RefCounted
## Spots files that can run code on your machine the moment the Godot editor loads them.
## Incoming risky files are held for review (quarantine) unless you trust the sender.

const EXEC_EXT := ["exe", "dll", "so", "dylib", "bat", "cmd", "ps1", "vbs", "sh", "com", "scr", "msi", "jar", "py"]
const EXT_BINARY := ["gdextension"]
const SCRIPT_EXT := ["gd"]
## C# code and the build files around it: compiled into the assembly the editor loads, and MSBuild
## files can run commands when the project is built.
const DOTNET_EXT := ["cs", "csproj", "sln", "props", "targets"]
const SCAN_LIMIT := 64 * 1024 * 1024


## Returns a human-readable reason when `rel` (with content at `abs_path`) is risky, else "".
static func risk_reason(rel: String, abs_path: String) -> String:
	var ext := rel.get_extension().to_lower()
	if rel.begins_with("addons/") and rel.get_file() == "plugin.cfg":
		return "Editor plugin manifest (enables a plugin that runs inside the editor)"
	if ext in EXEC_EXT:
		return "Native executable / shell script"
	if ext in EXT_BINARY:
		return "GDExtension (loads native code into the editor)"
	if ext in DOTNET_EXT:
		return "C# code or build file (runs when the project is built)"
	if ext in SCRIPT_EXT:
		if rel.begins_with("addons/"):
			return "Script inside an editor plugin"
		if _contains(abs_path, "@tool".to_utf8_buffer()):
			return "@tool script (runs inside the editor)"
	if ext in ["tscn", "tres", "scn", "res"]:
		if _head(abs_path, 4).begins_with("RSCC"):
			return "Compressed binary scene/resource (can't be checked for embedded scripts)"
		if _contains(abs_path, "@tool".to_utf8_buffer()):
			return "Scene/resource with an embedded @tool script"
	if rel == "project.godot":
		var cfg := ConfigFile.new()
		if cfg.load(abs_path) == OK:
			if cfg.has_section("autoload") and not cfg.get_section_keys("autoload").is_empty():
				return "Project settings with autoload scripts"
			for p in cfg.get_value("editor_plugins", "enabled", PackedStringArray()):
				if String(p).find("godot_coop") == -1:
					return "Project settings that enable editor plugins"
	return ""


static func _contains(abs_path: String, needle: PackedByteArray) -> bool:
	var f := FileAccess.open(abs_path, FileAccess.READ)
	if f == null:
		return false
	var b := f.get_buffer(mini(SCAN_LIMIT, f.get_length()))
	var n := needle.size()
	var i := b.find(needle[0])
	while i != -1 and i + n <= b.size():
		if b.slice(i, i + n) == needle:
			return true
		i = b.find(needle[0], i + 1)
	return false


static func _head(abs_path: String, n: int) -> String:
	var f := FileAccess.open(abs_path, FileAccess.READ)
	if f == null:
		return ""
	var b := f.get_buffer(mini(n, f.get_length()))
	return b.get_string_from_utf8()


## Fast path-only check used before any content exists (e.g. to label rows in a plan).
static func path_might_be_risky(rel: String) -> bool:
	var ext := rel.get_extension().to_lower()
	return ext in EXEC_EXT or ext in EXT_BINARY or ext in SCRIPT_EXT or ext in DOTNET_EXT or rel == "project.godot" or rel.begins_with("addons/")
