extends RefCounted
## Shared helpers for the two-editor integration test scripts.

var P                        # the Godot Co-op EditorPlugin
var shared := ""
var results := {}
var log_lines := []
var role := ""


func setup(plugin, who: String) -> void:
	P = plugin
	role = who
	shared = OS.get_environment("GODOT_COOP_SHARED")


func say(s: String) -> void:
	var line := "[%s %.1f] %s" % [role, Time.get_ticks_msec() / 1000.0, s]
	print(line)
	log_lines.append(line)


func check(name: String, ok: bool, detail := "") -> void:
	results[name] = ok
	say(("PASS " if ok else "FAIL ") + name + ("" if detail.is_empty() else " - " + detail))


func until(cond: Callable, timeout: float) -> bool:
	var end := Time.get_ticks_msec() + int(timeout * 1000)
	while Time.get_ticks_msec() < end:
		if cond.call():
			return true
		await P.get_tree().create_timer(0.1).timeout
	return cond.call()


func wait(sec: float) -> void:
	await P.get_tree().create_timer(sec).timeout


func mark(name: String) -> void:
	var f := FileAccess.open(shared.path_join(name), FileAccess.WRITE)
	f.store_string("1")
	f.close()
	say("mark " + name)


func wait_mark(name: String, timeout := 60.0) -> bool:
	var ok: bool = await until(func(): return FileAccess.file_exists(shared.path_join(name)), timeout)
	if not ok:
		say("timed out waiting for " + name)
	return ok


func finish() -> void:
	var f := FileAccess.open(shared.path_join(role + "_results.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify({"results": results, "log": log_lines}, "\t"))
	f.close()
	mark(role + "_done")
	await wait(1.0)
	P.get_tree().quit()


func scene_root(path: String) -> Node:
	for r in EditorInterface.get_open_scene_roots():
		if r != null and r.scene_file_path == path:
			return r
	return null


## Edit the way the inspector does, through the editor's undo/redo.
func set_prop(obj: Object, prop: String, value) -> void:
	var ur := EditorInterface.get_editor_undo_redo()
	ur.create_action("test: set " + prop)
	ur.add_do_property(obj, prop, value)
	ur.add_undo_property(obj, prop, obj.get(prop))
	ur.commit_action()


func add_node(parent: Node, node: Node, owner: Node) -> void:
	var ur := EditorInterface.get_editor_undo_redo()
	ur.create_action("test: add node")
	ur.add_do_method(parent, "add_child", node, true)
	ur.add_do_method(node, "set_owner", owner)
	ur.add_do_reference(node)
	ur.add_undo_method(parent, "remove_child", node)
	ur.commit_action()


func delete_node(node: Node) -> void:
	var parent := node.get_parent()
	var ur := EditorInterface.get_editor_undo_redo()
	ur.create_action("test: delete node")
	ur.add_do_method(parent, "remove_child", node)
	ur.add_undo_method(parent, "add_child", node, true)
	ur.add_undo_method(node, "set_owner", node.owner)
	ur.add_undo_reference(node)
	ur.commit_action()


## Closes a script tab the way a user would (middle-click in the script list). Marks it saved
## first so Godot doesn't stop to ask about unsaved changes.
func close_script(path: String) -> void:
	var ce := code_edit_for(path)
	if ce != null:
		ce.tag_saved_version()
	var se := EditorInterface.get_script_editor()
	for list in se.find_children("*", "ItemList", true, false):
		for i in list.item_count:
			if String(list.get_item_tooltip(i)).contains(path.trim_prefix("res://")) or list.get_item_text(i).trim_suffix("(*)") == path.get_file():
				list.item_clicked.emit(i, Vector2.ZERO, MOUSE_BUTTON_MIDDLE)
				await wait(0.3)
				return


func code_edit_for(path: String) -> CodeEdit:
	var se := EditorInterface.get_script_editor()
	var scripts := se.get_open_scripts()
	var eds := se.get_open_script_editors()
	for i in mini(scripts.size(), eds.size()):
		if scripts[i] != null and scripts[i].resource_path == path:
			var b = eds[i].get_base_editor()
			if b is CodeEdit:
				return b
	return null


func _live(path: String) -> bool:
	return P.script_sync.trackers.has(path) and P.script_sync.trackers[path].ready
