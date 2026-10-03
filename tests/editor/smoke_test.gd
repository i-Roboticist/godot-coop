extends RefCounted
## Loaded by the plugin when GODOT_COOP_TEST points here. Just proves the plugin loads and the
## dock builds, then quits the editor.

func start(plugin) -> void:
	await plugin.get_tree().create_timer(2.0).timeout
	var out := {
		"plugin": plugin != null,
		"dock_built": plugin.dock != null and plugin.dock._built,
		"tabs": plugin.dock._tabs.get_tab_count() if plugin.dock._built else 0,
		"session": plugin.session != null,
	}
	var f := FileAccess.open(OS.get_environment("GODOT_COOP_RESULT"), FileAccess.WRITE)
	f.store_string(JSON.stringify(out))
	f.close()
	plugin.get_tree().quit()
