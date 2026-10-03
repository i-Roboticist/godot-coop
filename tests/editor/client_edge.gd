extends "res://coop_tests/test_base.gd"
## Joining side of the edge-case suite.


func start(plugin) -> void:
	setup(plugin, "client")
	await wait_mark("invite.txt", 90)
	P.join(FileAccess.get_file_as_string(shared.path_join("invite.txt")))
	var ok: bool = await until(func(): return P.live, 90)
	check("client_joined", ok)
	if not ok:
		await finish()
		return
	EditorInterface.edit_script(load("res://player.gd"))
	ok = await until(func(): return _live("res://player.gd"), 15)
	check("client_script_live", ok)
	mark("client_live")

	# 1. Type, close and reopen the script, then type again (the new editor's edit numbers start
	#    over, so they collide with the ones the host already saw).
	var first := code_edit_for("res://player.gd")
	if first != null:
		first.insert_text("# before close\n", first.get_line_count() - 1, 0)
		await wait(0.2)
		first.insert_text("# before close 2\n", first.get_line_count() - 1, 0)
		await wait(1.0)
	await close_script("res://player.gd")
	EditorInterface.edit_script(load("res://player.gd"))
	ok = await until(func(): return _live("res://player.gd"), 15)
	var ce := code_edit_for("res://player.gd")
	check("reopened_script_live", ok and ce != null)
	if ce != null:
		ce.insert_text("# after reopen\n", ce.get_line_count() - 1, 0)
	mark("client_reopened_typed")

	# 2. Type something, receive the host's edit, then use Godot's own undo.
	if ce != null:
		ce.insert_text("# client typed\n", ce.get_line_count() - 1, 0)
		await wait_mark("host_typed_top")
		ok = await until(func(): return ce.text.contains("# host line"), 10)
		check("host_edit_arrived", ok)
		ce.undo()
		ce.undo()
		await wait(0.3)
	mark("client_native_undo")

	# 3. In a script the host doesn't have open: type twice quickly (the second edit waits for the
	#    first to be confirmed) and save at once, so the saved file overtakes the second edit.
	EditorInterface.edit_script(load("res://main.gd"))
	ok = await until(func(): return _live("res://main.gd"), 15)
	var mce := code_edit_for("res://main.gd")
	check("second_script_live", ok and mce != null)
	if mce != null:
		mce.insert_text("# first\n", mce.get_line_count() - 1, 0)
		mce.insert_text("# typed then saved\n", mce.get_line_count() - 1, 0)
		var f := FileAccess.open("res://main.gd", FileAccess.WRITE)
		f.store_string(mce.text)
		f.close()
		mce.tag_saved_version()
		P.session.files.check_path("main.gd")
	mark("client_typed_and_saved")
	await wait(2.0)
	if mce != null:
		check("save_while_typing_no_duplicate_here", mce.text.count("# typed then saved") == 1, mce.text.c_escape().substr(0, 300))
	await wait_mark("host_checked_save", 30)
	await close_script("res://main.gd")

	# 4. Close the script.
	await close_script("res://player.gd")
	mark("client_closed_script")

	# 5. Create a script and type in it right away, before the host has the file.
	var nf := FileAccess.open("res://made_here.gd", FileAccess.WRITE)
	nf.store_string("extends Node\n")
	nf.close()
	EditorInterface.get_resource_filesystem().update_file("res://made_here.gd")
	EditorInterface.edit_script(load("res://made_here.gd"))
	ok = await until(func(): return _live("res://made_here.gd"), 15)
	var nce := code_edit_for("res://made_here.gd")
	if nce != null:
		nce.insert_text("# typed in new file\n", nce.get_line_count() - 1, 0)
	mark("client_new_script")
	await wait(2.0)
	check("new_script_buffer_kept", nce != null and nce.text.contains("extends Node") and nce.text.contains("# typed in new file"), nce.text.c_escape() if nce else "no editor")

	await wait_mark("host_scripts_done", 60)

	# --- Scenes ------------------------------------------------------------------------------
	EditorInterface.open_scene_from_path("res://main.tscn")
	ok = await until(func(): return P.scene_sync.trackers.has("res://main.tscn") and P.scene_sync.trackers["res://main.tscn"].ready, 20)
	check("client_scene_ready", ok)
	if not ok:
		await finish()
		return
	var main := scene_root("res://main.tscn")
	var tr = P.scene_sync.trackers["res://main.tscn"]
	mark("client_scene_ready")

	# S1. Change Type: Wall (StaticBody2D) becomes an Area2D; its child moves to the new node.
	replace_node(main.get_node("Wall"), Area2D.new())
	await wait(2.0)
	var wall := main.get_node_or_null("Wall")
	check("change_type_kept_here", wall is Area2D and wall.get_node_or_null("CollisionShape2D") != null, str(child_names(main)))
	mark("client_changed_type")

	# S2. Add "Coin" while our edits are held back (as on a slow link), so the host's own "Coin"
	#     gets there first. Ours must end up as Coin2 here too.
	tr.live = false
	var coin := Node2D.new()
	coin.name = "Coin"
	add_node(main, coin, main)
	await wait(0.4)
	mark("client_coin_held")
	await wait_mark("host_added_coin")
	ok = await until(func():
		for c in main.get_children():
			if c != coin and String(c.name) == "Coin":
				return true
		return false, 10)
	check("host_coin_arrived", ok, str(child_names(main)))
	tr.live = true
	P.scene_sync._send_unsent(tr)
	mark("client_coin_sent")
	await until(func(): return String(coin.name) == "Coin2", 10)
	await wait(1.0)
	write_shared("client_names.txt", ",".join(child_names(main)))
	mark("client_names_written")
	await wait_mark("host_names_written")
	check("same_name_adds_converge_here", String(coin.name) == "Coin2" and read_shared("client_names.txt") == read_shared("host_names.txt"),
		"host %s / client %s" % [read_shared("host_names.txt"), read_shared("client_names.txt")])

	# S3. Attach a script we just created: the change goes out before the file does.
	var lf := FileAccess.open("res://late.gd", FileAccess.WRITE)
	lf.store_string("extends Label\n# attached before the host had this file\n")
	lf.close()
	EditorInterface.get_resource_filesystem().update_file("res://late.gd")
	set_prop(main.get_node("Label"), "script", load("res://late.gd"))
	mark("client_attached_late_script")

	# S4. A built-in @tool script (code that would run in the host's editor).
	var bs := GDScript.new()
	bs.source_code = "@tool\nextends Node2D\n"
	bs.reload()
	set_prop(main.get_node("Player/Sprite2D"), "script", bs)
	mark("client_attached_builtin_tool")

	# S5. Change a property every frame for 3 s without any editor action, like a @tool script:
	#     only a handful of updates should go out, then the final value.
	EditorInterface.get_selection().clear()
	var label: Control = main.get_node("Label")
	var c0: int = tr.cseq
	var t_end := Time.get_ticks_msec() + 3000
	var frames := 0
	while Time.get_ticks_msec() < t_end:
		label.rotation += 0.05
		frames += 1
		await P.get_tree().process_frame
	var sent: int = tr.cseq - c0
	await wait(2.5)
	check("churn_throttled", sent <= 15, "%d batches for %d frames of changes" % [sent, frames])
	write_shared("client_rotation.txt", "%.6f" % label.rotation)
	mark("client_churn_done")

	# S6. Put Player under Label (held back) while the host puts Label under Player.
	tr.live = false
	var player := main.get_node("Player")
	var player_id := player.get_instance_id()
	var label_id := label.get_instance_id()
	reparent_node(player, label)
	await wait(0.4)
	mark("client_cycle_held")
	await wait_mark("host_moved_label")
	await wait(0.8)
	tr.live = true
	P.scene_sync._send_unsent(tr)
	await wait(2.5)
	mark("client_cycle_done")
	await wait_mark("host_tree_written")
	check("cycle_converges", tree_text(main) == read_shared("host_tree.txt"), "host %s / client %s" % [read_shared("host_tree.txt"), tree_text(main)])
	check("reconcile_keeps_nodes", is_instance_valid(player) and is_instance_valid(label) and main.find_child("Player", true, false) == player and main.find_child("Label", true, false) == label)

	# S8. The host deletes Wall and adds Ruby in the same frame: same sibling order here.
	mark("client_ready_s8")
	await wait_mark("host_order_written")
	await wait(0.5)
	check("delete_and_add_keep_sibling_order", ",".join(ordered_names(main)) == read_shared("host_order.txt"), "host %s / client %s" % [read_shared("host_order.txt"), ",".join(ordered_names(main))])
	mark("client_checked_s8")

	# S7. Leave main.tscn to the host, then change and save gem.tscn, which main.tscn instances.
	await wait_mark("host_instanced_gem")
	ok = await until(func(): return main.get_node_or_null("Gem") != null, 10)
	check("instance_arrived", ok)
	EditorInterface.open_scene_from_path("res://main.tscn")
	await wait(0.3)
	EditorInterface.close_scene()
	await wait(1.0)
	mark("client_closed_main")
	await wait_mark("host_unsaved_edit")
	EditorInterface.open_scene_from_path("res://gem.tscn")
	ok = await until(func(): return scene_root("res://gem.tscn") != null, 10)
	if ok:
		set_prop(scene_root("res://gem.tscn"), "modulate", Color(1, 0, 0, 1))
		EditorInterface.save_scene()
		P.session.files.check_path("gem.tscn")
	mark("client_saved_gem")

	await wait_mark("host_scenes_done", 90)
	await finish()

