extends "res://coop_tests/test_base.gd"
## Host side of the two-editor integration test.


func start(plugin) -> void:
	setup(plugin, "host")
	say("waiting for invites")
	var ok: bool = await until(func(): return P.session != null and P.session.invites_ready, 30)
	check("host_invites_ready", ok)
	if not ok:
		await finish()
		return
	var f := FileAccess.open(shared.path_join("invite.txt"), FileAccess.WRITE)
	f.store_string(P.session.get_invite("editor").code)
	f.close()
	EditorInterface.open_scene_from_path("res://main.tscn")
	await wait_mark("client_live", 90)
	var main := scene_root("res://main.tscn")
	check("host_scene_open", main != null)
	var player: Node2D = main.get_node_or_null("Player") if main else null

	# 1. A teammate's property edit shows up here.
	await wait_mark("client_moved_player")
	ok = await until(func(): return player != null and player.position == Vector2(123, 45), 15)
	check("remote_property_edit", ok, str(player.position if player else null))

	# 2. Add a node here; the client checks it, renames it, we check the rename.
	var coin := Node2D.new()
	coin.name = "Coin"
	coin.position = Vector2(50, 60)
	add_node(main, coin, main)
	mark("host_added_coin")
	await wait_mark("client_renamed_coin")
	ok = await until(func(): return main.get_node_or_null("Gem") != null, 15)
	check("remote_rename", ok)

	# 3. Delete it here; the client checks it's gone.
	var gem := main.get_node_or_null("Gem")
	if gem != null:
		delete_node(gem)
	mark("host_deleted_gem")

	# 4. Sub-resource + visual property edits from the client.
	await wait_mark("client_changed_sprite")
	var sprite: Sprite2D = main.get_node_or_null("Player/Sprite2D")
	var shape: CollisionShape2D = main.get_node_or_null("Player/CollisionShape2D")
	ok = await until(func(): return sprite != null and sprite.modulate == Color(1, 0, 0, 1), 15)
	check("remote_modulate", ok)
	ok = await until(func(): return shape != null and shape.shape is RectangleShape2D and shape.shape.size == Vector2(100, 40), 15)
	check("remote_subresource_in_place", ok, str(shape.shape.size if shape and shape.shape else null))
	check("shared_subresource_still_shared", main.get_node_or_null("Wall/CollisionShape2D") != null)

	# 5. Live script editing: both type at the same time.
	EditorInterface.edit_script(load("res://player.gd"))
	await wait(1.0)
	mark("host_script_open")
	await wait_mark("client_script_open")
	var code := code_edit_for("res://player.gd")
	check("host_has_code_edit", code != null)
	if code != null:
		await until(func(): return P.script_sync.trackers.has("res://player.gd") and P.script_sync.trackers["res://player.gd"].ready, 15)
		code.set_caret_line(code.get_line_count() - 1)
		code.set_caret_column(code.get_line(code.get_line_count() - 1).length())
		code.insert_text_at_caret("\n# typed by host")
		mark("host_typed")
		await wait_mark("client_typed")
		ok = await until(func(): return code.text.find("# typed by host") != -1 and code.text.find("# typed by client") != -1, 15)
		check("concurrent_typing_merged", ok)
		check("no_stale_script_pushed", code.text.find("LOCAL EDIT") == -1 and code.text.find("@export var speed") != -1, code.text.c_escape().substr(0, 160))
		await wait_mark("client_undid")
		ok = await until(func(): return code.text.find("# typed by client") == -1 and code.text.find("# typed by host") != -1, 15)
		check("per_user_undo_only_undoes_theirs", ok, code.text.c_escape().substr(0, 200))
		check("remote_caret_known", not P.script_sync.trackers["res://player.gd"].remote.is_empty())

	# 6. A file created on the client arrives here.
	await wait_mark("client_wrote_file")
	ok = await until(func(): return FileAccess.file_exists("res://notes.md") and FileAccess.get_file_as_string("res://notes.md") == "hello from the client", 15)
	check("file_sync_new_file", ok)

	# 7. Project settings change here reaches the client.
	ProjectSettings.set_setting("application/config/description", "changed by host")
	ProjectSettings.save()
	P._on_project_settings_changed()
	mark("host_set_setting")

	# 8. Presence: the client selected the Player.
	await wait_mark("client_selected")
	ok = await until(func():
		for pid in P.session.presence:
			var pr: Dictionary = P.session.presence[pid]
			if pid != 1 and String(pr.get("scene", "")) == "res://main.tscn" and not Array(pr.get("sel", [])).is_empty():
				return true
		return false, 10)
	check("presence_selection_received", ok, str(P.session.presence))
	check("presence_describe", P.presence.describe(2).find("main.tscn") != -1, P.presence.describe(2))

	# 9. Lock the scene: the client's edit must be undone.
	P.session.send({"t": "lock", "path": "res://main.tscn", "on": true}, 1)
	await wait(0.5)
	mark("host_locked")
	await wait_mark("client_tried_locked_edit")
	await wait(1.5)
	check("locked_edit_rejected", player.position == Vector2(123, 45), str(player.position))
	P.session.send({"t": "lock", "path": "res://main.tscn", "on": false}, 1)

	# 10. Chat both ways.
	P.session.send({"t": "chat", "text": "hi from host"})
	await wait_mark("client_chatted")
	ok = await until(func():
		for e in P.session.chat_log:
			if e.text == "hi from client":
				return true
		return false, 10)
	check("chat_received", ok)
	check("activity_has_entries", P.session.activity_log.size() > 5, str(P.session.activity_log.size()))

	# 11. Follow mode: the client follows us; we move our 2D view, then our 3D camera.
	await wait_mark("client_following")
	EditorInterface.open_scene_from_path("res://main.tscn")
	EditorInterface.set_main_screen_editor("2D")
	await wait(0.5)
	P.presence._set_2d_view(Vector2(1234, 567), 2.0)
	await wait(0.5)
	say("host 2d view: " + str(P.presence._gather_fast()))
	mark("host_moved_2d")
	await wait_mark("client_checked_2d")
	EditorInterface.set_main_screen_editor("3D")
	await wait(0.5)
	var cam := EditorInterface.get_editor_viewport_3d(0).get_camera_3d()
	cam.global_transform = Transform3D(Basis.looking_at(Vector3(0, -0.5, -1)), Vector3(3, 4, 5))
	await wait(0.5)
	mark("host_moved_3d")
	await wait_mark("client_checked_3d")
	EditorInterface.set_main_screen_editor("2D")

	# 12. Playtest tunnel: a fake game server here, a fake game client on the other side.
	var srv := PacketPeerUDP.new()
	check("game_server_port_free", srv.bind(47911, "127.0.0.1") == OK)
	P.playtest.prepare({"game_port": 47911, "net": true})
	check("host_run_args", Array(P.playtest.run_args(PackedStringArray())).has("--coop-role=server"))
	mark("host_tunnel_ready")
	ok = await until(func(): return srv.get_available_packet_count() > 0, 15)
	var got := srv.get_packet().get_string_from_utf8() if ok else ""
	check("tunnel_client_to_server", got == "ping from game client", got)
	if ok:
		srv.set_dest_address(srv.get_packet_ip(), srv.get_packet_port())
		srv.put_packet("pong from game server".to_utf8_buffer())
	await wait_mark("client_tunnel_done")

	# 13. The companion app's "End session" button.
	Util_write(P.project_dir.path_join(".coop/control.json"), {"cmd": "end"})
	ok = await until(func(): return P.session.state == "ended" or P.session.state == "ending", 10)
	check("app_end_session_command", ok, P.session.state)
	await wait_mark("client_done", 60)
	await finish()


func Util_write(path: String, data: Dictionary) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(data))
	f.close()
