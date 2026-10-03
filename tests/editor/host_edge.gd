extends "res://coop_tests/test_base.gd"
## Host side of the edge-case suite (python tests/editor/run_editor_tests.py --suite edge).


func start(plugin) -> void:
	setup(plugin, "host")
	var ok: bool = await until(func(): return P.session != null and P.session.invites_ready, 30)
	check("host_invites_ready", ok)
	if not ok:
		await finish()
		return
	var f := FileAccess.open(shared.path_join("invite.txt"), FileAccess.WRITE)
	f.store_string(P.session.get_invite("editor").code)
	f.close()
	EditorInterface.open_scene_from_path("res://main.tscn")
	EditorInterface.edit_script(load("res://player.gd"))
	await wait_mark("client_live", 90)
	var code := code_edit_for("res://player.gd")
	ok = code != null and await until(func(): return _live("res://player.gd"), 15)
	check("host_script_live", ok)
	if not ok:
		await finish()
		return

	# 1. The client closes and reopens the script, then types: it must arrive.
	await wait_mark("client_reopened_typed")
	ok = await until(func(): return code.text.contains("# after reopen"), 10)
	check("reopened_script_edit_arrives", ok, code.text.c_escape().substr(0, 200))

	# 2. Our edit reaches the client, which then uses Godot's own undo (Edit > Undo): that must not
	#    revert our edit for everyone.
	code.insert_text("# host line\n", 0, 0)
	mark("host_typed_top")
	await wait_mark("client_native_undo")
	await wait(1.5)
	check("native_undo_cannot_revert_teammate", code.text.contains("# host line"), code.text.c_escape().substr(0, 200))

	# 3. The client types and saves at once in main.gd (not open here): the text must be in the
	#    live document exactly once.
	await wait_mark("client_typed_and_saved")
	var main_doc := func(): return String(P.session.docs.texts["res://main.gd"].text) if P.session.docs.texts.has("res://main.gd") else ""
	ok = await until(func(): return main_doc.call().contains("# typed then saved"), 10)
	await wait(1.5)
	say("main.gd document: " + main_doc.call().c_escape())
	check("save_while_typing_no_duplicate", ok and main_doc.call().count("# typed then saved") == 1 and main_doc.call().count("# first") == 1, main_doc.call().c_escape().substr(0, 300))
	mark("host_checked_save")

	# 4. The client closes the script: its caret disappears here.
	await wait_mark("client_closed_script")
	ok = await until(func(): return P.script_sync.trackers.has("res://player.gd") and P.script_sync.trackers["res://player.gd"].remote.is_empty(), 10)
	check("closed_teammate_caret_removed", ok)

	# 5. The client creates a new script and starts typing in it straight away.
	await wait_mark("client_new_script")
	ok = await until(func():
		var d = P.session.docs.texts.get("res://made_here.gd")
		return d != null and String(d.text).contains("extends Node") and String(d.text).contains("# typed in new file"), 15)
	check("new_script_document_has_creator_text", ok, String(P.session.docs.texts["res://made_here.gd"].text).c_escape() if P.session.docs.texts.has("res://made_here.gd") else "no doc")

	mark("host_scripts_done")

	# --- Scenes ------------------------------------------------------------------------------
	await wait_mark("client_scene_ready", 60)
	var main := scene_root("res://main.tscn")

	# S1. The client changes Wall's type (Change Type): it arrives as an Area2D still named Wall,
	#     with its child.
	await wait_mark("client_changed_type")
	ok = await until(_wall_is_area.bind(main), 10)
	check("change_type_synced", ok and main.get_node_or_null("Wall2") == null, str(child_names(main)))

	# S2. Both add a node called "Coin" at the same moment (the client's edit is held back so it
	#     reaches the host second). Ours keeps the name, theirs becomes Coin2, both editors agree.
	await wait_mark("client_coin_held")
	var coin := Node2D.new()
	coin.name = "Coin"
	add_node(main, coin, main)
	mark("host_added_coin")
	await wait_mark("client_coin_sent")
	ok = await until(func(): return main.get_node_or_null("Coin2") != null, 10)
	await wait(1.0)
	write_shared("host_names.txt", ",".join(child_names(main)))
	mark("host_names_written")
	await wait_mark("client_names_written")
	check("same_name_adds_converge", ok and String(coin.name) == "Coin" and read_shared("client_names.txt") == read_shared("host_names.txt"),
		"host %s / client %s" % [read_shared("host_names.txt"), read_shared("client_names.txt")])

	# S3. The client attaches a script it just created: the change arrives before the file does.
	await wait_mark("client_attached_late_script")
	var label: Node = main.get_node("Label")
	ok = await until(func(): return label.get_script() != null and label.get_script().resource_path == "res://late.gd", 15)
	check("script_attached_before_file_arrives", ok, str(label.get_script()))

	# S4. A built-in @tool script from a teammate we don't trust must not run here.
	await wait_mark("client_attached_builtin_tool")
	await wait(2.0)
	var spr: Node = main.get_node_or_null("Player/Sprite2D")
	check("builtin_tool_script_not_run_here", spr != null and spr.get_script() == null, str(spr.get_script()) if spr else "no sprite")

	# S5. A property the client changes every frame (like a @tool script would): the value it
	#     settles on arrives.
	await wait_mark("client_churn_done")
	var target := float(read_shared("client_rotation.txt"))
	ok = await until(func(): return absf(label.rotation - target) < 0.001, 8)
	check("churn_final_value_arrives", ok, "%f vs %f" % [label.rotation, target])

	# S6. Opposite reparents at the same moment (we put Label under Player, the client put Player
	#     under Label): one must lose, and both editors must end up with the same tree.
	await wait_mark("client_cycle_held")
	reparent_node(main.get_node("Label"), main.get_node("Player"))
	mark("host_moved_label")
	await wait_mark("client_cycle_done")
	await wait(1.0)
	var label_now := main.find_child("Label", true, false)
	check("cycle_host_keeps_its_move", label_now != null and label_now.get_parent() == main.get_node("Player"), tree_text(main))
	write_shared("host_tree.txt", tree_text(main))
	mark("host_tree_written")

	# S7. We have main.tscn open alone, with an unsaved live edit, and a teammate saves a scene it
	#     instances. The reload that refreshes the instance must not lose the edit.
	var gem_root := Sprite2D.new()
	gem_root.name = "Gem"
	var ps := PackedScene.new()
	ps.pack(gem_root)
	ResourceSaver.save(ps, "res://gem.tscn")
	gem_root.free()
	EditorInterface.get_resource_filesystem().update_file("res://gem.tscn")
	P.session.files.check_path("gem.tscn")
	await wait(0.5)
	add_node(main, load("res://gem.tscn").instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE), main)
	mark("host_instanced_gem")
	await wait_mark("client_closed_main")
	await wait(1.0)
	set_prop(main.get_node("Player"), "position", Vector2(777, 1))
	await wait(0.6)
	var old_root := main.get_instance_id()
	mark("host_unsaved_edit")
	await wait_mark("client_saved_gem")
	var reloaded: bool = await until(func(): return scene_root("res://main.tscn") != null and scene_root("res://main.tscn").get_instance_id() != old_root, 15)
	ok = await until(func(): return scene_root("res://main.tscn") != null and scene_root("res://main.tscn").get_node_or_null("Gem") != null and scene_root("res://main.tscn").get_node("Gem").modulate == Color(1, 0, 0, 1), 10)
	check("teammate_save_refreshes_instance", reloaded and ok)
	ok = await until(func(): return scene_root("res://main.tscn") != null and scene_root("res://main.tscn").get_node("Player").position == Vector2(777, 1), 10)
	check("reload_keeps_unsaved_live_edit", reloaded and ok, str(scene_root("res://main.tscn").get_node("Player").position) if scene_root("res://main.tscn") else "no scene")

	mark("host_scenes_done")
	await wait_mark("client_done", 120)
	await finish()


func _wall_is_area(main: Node) -> bool:
	var w := main.get_node_or_null("Wall")
	return w is Area2D and w.get_node_or_null("CollisionShape2D") != null
