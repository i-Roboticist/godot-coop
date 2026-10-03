extends "res://coop_tests/test_base.gd"
## End-to-end visual test, joining side: this editor was downloaded + launched by the app.

const Net := preload("res://addons/godot_coop/core/net.gd")


func shot(name: String) -> void:
	await P.get_tree().process_frame
	await P.get_tree().process_frame
	var img: Image = P.get_viewport().get_texture().get_image()
	img.save_png(shared.path_join(name + ".png"))
	say("screenshot " + name)


func start(plugin) -> void:
	setup(plugin, "client")
	var ok: bool = await until(func(): return P.live, 240)
	check("editor_auto_joined_from_app", ok, P.session.state if P.session else "no session")
	if not ok:
		await finish()
		return
	check("plugin_installed_by_app", FileAccess.file_exists("res://addons/godot_coop/plugin.cfg"))
	check("project_downloaded", FileAccess.file_exists("res://main.tscn") and FileAccess.file_exists("res://player.gd"))
	EditorInterface.open_scene_from_path("res://main.tscn")
	await until(func(): return P.scene_sync.trackers.has("res://main.tscn") and P.scene_sync.trackers["res://main.tscn"].ready, 30)
	EditorInterface.set_main_screen_editor("2D")
	mark("client_live")
	var main := scene_root("res://main.tscn")
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(main.get_node("Wall"))
	await wait(0.5)
	# Pretend our mouse is hovering near the wall so the host sees a cursor.
	P.session.send({"t": "presence_fast", "mouse": [640, 230]}, Net.CH_FAST, false)
	mark("client_selected_wall")
	await wait_mark("host_saw_2d")
	var tr = P.scene_sync.current_tracker()
	var hp: Dictionary = P.session.presence.get(1, {})
	say("diag presence keys=%s host=%s" % [str(P.session.presence.keys()), str(hp)])
	say("diag others=%s" % str(P.presence._others_in_scene("res://main.tscn")))
	if tr != null:
		say("diag nodes=%s" % str(P.scene_sync.nodes_for_ids(tr, hp.get("sel", []))))
	check("sees_host_selection", tr != null and not P.scene_sync.nodes_for_ids(tr, hp.get("sel", [])).is_empty())
	P.update_overlays()
	await wait(0.5)
	await shot("8_client_2d")
	mark("client_shot_2d")
	EditorInterface.open_scene_from_path("res://level_3d.tscn")
	await wait(1.0)
	EditorInterface.set_main_screen_editor("3D")
	await until(func(): return P.scene_sync.trackers.has("res://level_3d.tscn") and P.scene_sync.trackers["res://level_3d.tscn"].ready, 20)
	var lvl := scene_root("res://level_3d.tscn")
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(lvl.get_node("Crate"))
	var cam := EditorInterface.get_editor_viewport_3d(0).get_camera_3d()
	if cam != null:
		cam.global_transform = Transform3D(Basis.looking_at(Vector3(-1, -0.4, -1)), Vector3(4, 3, 4))
	await wait(0.5)
	mark("client_in_3d")
	await wait_mark("host_saw_3d")
	EditorInterface.edit_script(load("res://player.gd"))
	EditorInterface.set_main_screen_editor("Script")
	await wait(1.5)
	var ce := code_edit_for("res://player.gd")
	if ce != null:
		await until(func(): return P.script_sync.trackers.has("res://player.gd") and P.script_sync.trackers["res://player.gd"].ready, 15)
		ce.set_caret_line(3)
		ce.set_caret_column(0)
		ce.insert_text_at_caret("# hello from the other editor\n")
		ce.set_caret_line(4)
		ce.set_caret_column(6)
	mark("client_typing")
	P.session.send({"t": "chat", "text": "Looks great - I'm on the wall collision!"})
	mark("client_chatted")
	await wait_mark("host_shots_done", 60)
	await shot("9_client_script")
	EditorInterface.set_main_screen_editor("2D")
	P.presence.follow(1)
	mark("client_following")
	await wait_mark("host_view_set")
	var want = JSON.parse_string(FileAccess.get_file_as_string(shared.path_join("host_view.json")))
	var ok2: bool = await until(func():
		var c: Array = P.presence._gather_fast().get("cam2d", [])
		return want is Array and want.size() == 3 and c.size() == 3 and absf(c[0] - want[0]) < 3.0 and absf(c[1] - want[1]) < 3.0 and absf(c[2] - want[2]) < 0.01, 10)
	check("follow_2d_matches_host_view", ok2, "host %s, me %s" % [str(want), str(P.presence._gather_fast().get("cam2d", []))])
	await shot("10_client_following")
	P.presence.stop_follow()
	await finish()
