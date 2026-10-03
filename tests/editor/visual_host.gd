extends "res://coop_tests/test_base.gd"
## End-to-end visual test, host side (windowed editor started by the companion app).


func shot(name: String) -> void:
	await P.get_tree().process_frame
	await P.get_tree().process_frame
	var img: Image = P.get_viewport().get_texture().get_image()
	img.save_png(shared.path_join(name + ".png"))
	say("screenshot " + name)


func dock_tab(i: int) -> void:
	P.dock._tabs.current_tab = i
	if P._editor_dock != null:
		P._editor_dock.make_visible()


func start(plugin) -> void:
	setup(plugin, "host")
	var ok: bool = await until(func(): return P.session != null and P.session.invites_ready, 40)
	check("app_started_hosting", ok)
	if not ok:
		await finish()
		return
	P.session.join_request.connect(_on_join_request)
	var f := FileAccess.open(shared.path_join("invite.txt"), FileAccess.WRITE)
	f.store_string(P.session.get_invite("editor").code)
	f.close()
	EditorInterface.open_scene_from_path("res://main.tscn")
	await wait(1.0)
	EditorInterface.set_main_screen_editor("2D")
	var main := scene_root("res://main.tscn")
	EditorInterface.get_selection().add_node(main.get_node("Player"))
	dock_tab(0)
	await wait(1.0)
	await shot("1_host_invite")
	ok = await wait_mark("client_live", 300)
	check("client_joined_via_app", ok)
	if not ok:
		await finish()
		return
	await wait(1.0)
	dock_tab(4)
	await wait(0.5)
	dock_tab(1)
	await wait(1.0)
	await shot("2_host_people")
	await wait_mark("client_selected_wall")
	await wait(2.0)
	P.update_overlays()
	await wait(0.5)
	await shot("3_host_2d_presence")
	mark("host_saw_2d")
	await wait_mark("client_shot_2d")
	check("sees_client_selection", P.session.presence.size() > 0)
	EditorInterface.open_scene_from_path("res://level_3d.tscn")
	await wait(1.0)
	EditorInterface.set_main_screen_editor("3D")
	await wait_mark("client_in_3d")
	await wait(2.0)
	P.update_overlays()
	await wait(0.5)
	await shot("4_host_3d_presence")
	mark("host_saw_3d")
	EditorInterface.edit_script(load("res://player.gd"))
	EditorInterface.set_main_screen_editor("Script")
	await wait_mark("client_typing")
	await wait(2.0)
	await shot("5_host_script_carets")
	var code := code_edit_for("res://player.gd")
	check("client_typing_arrived", code != null and code.text.find("hello from the other editor") != -1)
	await wait_mark("client_chatted")
	await wait(1.0)
	dock_tab(3)
	await wait(0.5)
	await shot("6_host_activity")
	dock_tab(2)
	await wait(0.5)
	await shot("7_host_chat")
	mark("host_shots_done")
	# Follow mode, for real: the client follows us while we pan + zoom the 2D view.
	await wait_mark("client_following")
	EditorInterface.open_scene_from_path("res://main.tscn")
	EditorInterface.set_main_screen_editor("2D")
	await wait(0.5)
	P.presence._set_2d_view(Vector2(900, 420), 1.5)
	await wait(1.0)
	var cam2d: Array = P.presence._gather_fast().get("cam2d", [])
	var f2 := FileAccess.open(shared.path_join("host_view.json"), FileAccess.WRITE)
	f2.store_string(JSON.stringify(cam2d))
	f2.close()
	say("host view " + str(cam2d))
	mark("host_view_set")
	await wait_mark("client_done", 60)
	await finish()


## Plays the human host: look at the popup, then click "Let in".
func _on_join_request(req: Dictionary) -> void:
	await wait(1.5)
	await shot("1b_host_join_request")
	await wait(0.5)
	for w in EditorInterface.get_base_control().get_tree().root.get_children():
		if w is AcceptDialog and w.title.begins_with("Godot Co-op"):
			w.hide()
	P.session.approve(req.id, "editor")
	say("approved " + String(req.name))
