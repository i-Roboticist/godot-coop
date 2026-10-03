extends SceneTree
## Tests for the companion app's helpers (installer, Godot version handling).
##   Godot --headless --path app -s res://tests/app_tests.gd

const Util := preload("res://addons/godot_coop/core/util.gd")
const Installer := preload("res://src/installer.gd")
const Installs := preload("res://src/godot_installs.gd")

var failures := 0
var checks := 0


func check(cond: bool, what: String) -> void:
	checks += 1
	if not cond:
		failures += 1
		printerr("FAIL: ", what)


func write(path: String, text: String) -> void:
	Util.ensure_dir(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _init() -> void:
	var dir := OS.get_user_data_dir().path_join("app_tests")
	# --- enabling the plugin in project.godot -----------------------------------------------------
	var p1 := dir.path_join("p1")
	write(p1.path_join("project.godot"), "; header\nconfig_version=5\n\n[application]\n\nconfig/name=\"A\"\nconfig/features=PackedStringArray(\"4.7\", \"Forward Plus\")\n")
	check(Installer.enable_plugin(p1).is_empty(), "enable plugin (no section)")
	var t1 := FileAccess.get_file_as_string(p1.path_join("project.godot"))
	check(t1.begins_with("; header") and t1.find("[editor_plugins]\n\nenabled=PackedStringArray(\"res://addons/godot_coop/plugin.cfg\")") != -1, "adds [editor_plugins]")
	Installer.enable_plugin(p1)
	check(FileAccess.get_file_as_string(p1.path_join("project.godot")).count("godot_coop") == 1, "enabling twice is a no-op")
	var p2 := dir.path_join("p2")
	write(p2.path_join("project.godot"), "config_version=5\n\n[editor_plugins]\n\nenabled=PackedStringArray(\"res://addons/other/plugin.cfg\")\n\n[rendering]\n\nx=1\n")
	Installer.enable_plugin(p2)
	var cfg := ConfigFile.new()
	check(cfg.load(p2.path_join("project.godot")) == OK, "result still parses")
	var en: PackedStringArray = cfg.get_value("editor_plugins", "enabled", PackedStringArray())
	check(en.size() == 2 and en.has("res://addons/other/plugin.cfg") and en.has("res://addons/godot_coop/plugin.cfg"), "keeps other plugins enabled")
	check(cfg.get_value("rendering", "x", 0) == 1, "other sections untouched")
	# --- installing the files ------------------------------------------------------------------------
	check(Installer.install_plugin(p1).is_empty(), "install plugin")
	check(FileAccess.file_exists(p1.path_join("addons/godot_coop/plugin.gd")) and FileAccess.file_exists(p1.path_join("addons/godot_coop/core/session.gd")), "plugin files copied")
	check(FileAccess.file_exists(p1.path_join(".coop/.gdignore")) and FileAccess.file_exists(p1.path_join(".coop/.gitignore")), ".coop is hidden from Godot and git")
	check(not Installer.install_plugin(dir.path_join("nope")).is_empty(), "refuses folders without project.godot")
	var info := Installer.project_info(p1)
	check(info.name == "A" and info.feature == "4.7" and info.plugin_enabled and info.plugin_installed, "project info")
	# --- Godot versions -------------------------------------------------------------------------------
	var v := Installs.parse_version_from_name("Godot_v4.7.2-stable_win64.exe")
	check(v.major == 4 and v.minor == 7 and v.patch == 2 and v.status == "stable" and not v.dotnet, "parse version from file name")
	var v2 := Installs.parse_version_from_name("Godot_v4.8-beta2_mono_win64.exe")
	check(v2.minor == 8 and v2.patch == 0 and v2.status == "beta2" and v2.dotnet, "parse .NET beta")
	check(Installs.parse_version_from_name("notepad.exe").is_empty(), "ignore other exes")
	var url := Installs.download_url({"major": 4, "minor": 7, "patch": 2, "status": "stable", "dotnet": false})
	check(url == "https://github.com/godotengine/godot-builds/releases/download/4.7.2-stable/Godot_v4.7.2-stable_win64.exe.zip", "download url: " + url)
	var url0 := Installs.download_url({"major": 4, "minor": 6, "patch": 0, "status": "rc1", "dotnet": false})
	check(url0.ends_with("/4.6-rc1/Godot_v4.6-rc1_win64.exe.zip"), "download url without patch: " + url0)
	# A fake release zip extracts and the editor inside is found.
	var zp := dir.path_join("fake.zip")
	var z := ZIPPacker.new()
	z.open(zp)
	z.start_file("Godot_v9.9-stable_win64.exe")
	z.write_file("MZ fake".to_utf8_buffer())
	z.close_file()
	z.start_file("Godot_v9.9-stable_win64_console.exe")
	z.write_file("MZ".to_utf8_buffer())
	z.close_file()
	z.close()
	var exe := Installs.extract(zp, dir.path_join("extract"))
	check(exe.ends_with("Godot_v9.9-stable_win64.exe") and FileAccess.file_exists(exe), "extract finds the editor exe")
	print("app tests: %d checks, %d failures" % [checks, failures])
	quit(1 if failures > 0 else 0)
