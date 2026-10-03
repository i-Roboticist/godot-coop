@tool
extends EditorContextMenuPlugin
## Adds "Ping for everyone" to the Scene dock, 2D viewport, script editor and FileSystem menus.

var plugin
var slot := 0


func _popup_menu(paths: PackedStringArray) -> void:
	if plugin == null or plugin.session == null or not plugin.session.is_online():
		return
	var icon: Texture2D = EditorInterface.get_editor_theme().get_icon("Signals", "EditorIcons")
	add_context_menu_item("Ping for Everyone (Co-op)", _on_ping, icon)


func _on_ping(arg) -> void:
	var items: Array = arg if arg is Array else [arg]
	match slot:
		CONTEXT_SLOT_SCENE_TREE:
			var nodes := []
			var root := EditorInterface.get_edited_scene_root()
			for it in items:
				if it is Node:
					nodes.append(it)
				elif root != null and (it is String or it is NodePath):
					var n := root.get_node_or_null(NodePath(String(it)))
					if n != null:
						nodes.append(n)
			if nodes.is_empty():
				nodes = EditorInterface.get_selection().get_selected_nodes()
			plugin.presence.ping_nodes(nodes)
		CONTEXT_SLOT_2D_EDITOR:
			var sel := EditorInterface.get_selection().get_selected_nodes()
			if not sel.is_empty():
				plugin.presence.ping_nodes(sel)
			else:
				plugin.presence.ping_position(plugin.presence.last_canvas_click)
		CONTEXT_SLOT_SCRIPT_EDITOR_CODE:
			var se := EditorInterface.get_script_editor()
			var s := se.get_current_script()
			var ed := se.get_current_editor()
			if s != null and ed != null and ed.get_base_editor() is CodeEdit:
				plugin.presence.ping_line(s.resource_path, ed.get_base_editor().get_caret_line())
		CONTEXT_SLOT_FILESYSTEM:
			for it in items:
				if it is String and String(it).begins_with("res://"):
					plugin.presence.ping_file(String(it))
					return
