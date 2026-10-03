extends "res://coop_tests/test_base.gd"
## Joining side of the two-editor integration test.


func start(plugin) -> void:
	setup(plugin, "client")
	await wait_mark("invite.txt", 90)
	var code := FileAccess.get_file_as_string(shared.path_join("invite.txt"))
	P.join(code)
	var ok: bool = await until(func(): return P.live, 90)
	check("client_joined_and_synced", ok, P.session.state + " " + P.session.state_detail if P.session else "no session")
	if not ok:
		await finish()
		return
	check("local_edit_resolved_by_host", FileAccess.get_file_as_string("res://player.gd").find("LOCAL EDIT") == -1)
	check("conflict_backup_made", not P.session.files.conflict_backups.is_empty())
	EditorInterface.open_scene_from_path("res://main.tscn")
	ok = await until(func(): return P.scene_sync.trackers.has("res://main.tscn") and P.scene_sync.trackers["res://main.tscn"].ready, 20)
	check("scene_doc_ready", ok)
	var main := scene_root("res://main.tscn")
	var player: Node2D = main.get_node("Player")
	mark("client_live")

	# 1. Move the player like the inspector would.
	set_prop(player, "position", Vector2(123, 45))
	mark("client_moved_player")

	# 2. The host adds "Coin"; rename it to "Gem".
	await wait_mark("host_added_coin")
	ok = await until(func(): return main.get_node_or_null("Coin") != null, 15)
	check("remote_add_node", ok)
	var coin: Node2D = main.get_node_or_null("Coin")
	check("remote_add_node_props", coin != null and coin.position == Vector2(50, 60), str(coin.position if coin else null))
	check("remote_add_owner", coin != null and coin.owner == main)
	if coin != null:
		set_prop(coin, "name", "Gem")
	mark("client_renamed_coin")

	# 3. The host deletes it.
	await wait_mark("host_deleted_gem")
	ok = await until(func(): return main.get_node_or_null("Gem") == null, 15)
	check("remote_delete", ok)

	# 4. Colour + resize the shared collision shape (a sub-resource).
	set_prop(main.get_node("Player/Sprite2D"), "modulate", Color(1, 0, 0, 1))
	var shape: RectangleShape2D = main.get_node("Player/CollisionShape2D").shape
	set_prop(shape, "size", Vector2(100, 40))
	mark("client_changed_sprite")

	# 5. Live script editing.
	EditorInterface.edit_script(load("res://player.gd"))
	await wait(1.0)
	mark("client_script_open")
	await wait_mark("host_script_open")
	var ce := code_edit_for("res://player.gd")
	check("client_has_code_edit", ce != null)
	if ce != null:
		await until(func(): return P.script_sync.trackers.has("res://player.gd") and P.script_sync.trackers["res://player.gd"].ready, 15)
		await wait_mark("host_typed")
		ce.set_caret_line(0)
		ce.set_caret_column(0)
		ce.insert_text_at_caret("# typed by client\n")
		await wait(0.3)
		mark("client_typed")
		check("opened_script_is_current", ce.text.find("LOCAL EDIT") == -1, ce.text.c_escape().substr(0, 160))
		ok = await until(func(): return ce.text.find("# typed by host") != -1, 15)
		check("client_sees_host_typing", ok)
		await wait(0.5)
		var ev := InputEventKey.new()
		ev.keycode = KEY_Z
		ev.ctrl_pressed = true
		ev.pressed = true
		ce.gui_input.emit(ev)
		ok = await until(func(): return ce.text.find("# typed by client") == -1, 5)
		check("own_undo_applied", ok and ce.text.find("# typed by host") != -1, ce.text.c_escape().substr(0, 200))
		mark("client_undid")

	# 6. Create a file.
	var f := FileAccess.open("res://notes.md", FileAccess.WRITE)
	f.store_string("hello from the client")
	f.close()
	mark("client_wrote_file")

	# 7. Host changes a project setting.
	await wait_mark("host_set_setting")
	ok = await until(func(): return String(ProjectSettings.get_setting("application/config/description", "")) == "changed by host", 15)
	check("project_setting_synced", ok, String(ProjectSettings.get_setting("application/config/description", "")))

	# 8. Select the player so the host can see it.
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(player)
	await wait(0.6)
	mark("client_selected")

	# 9. Edit while the host holds the lock: it must be undone.
	await wait_mark("host_locked")
	await until(func(): return P.scene_sync.trackers["res://main.tscn"].lock_holder == 1, 10)
	set_prop(player, "position", Vector2(999, 999))
	mark("client_tried_locked_edit")
	ok = await until(func(): return player.position == Vector2(123, 45), 10)
	check("locked_edit_reverted_locally", ok, str(player.position))

	# 10. Chat.
	P.session.send({"t": "chat", "text": "hi from client"})
	mark("client_chatted")
	ok = await until(func():
		for e in P.session.chat_log:
			if e.text == "hi from host":
				return true
		return false, 10)
	check("chat_received", ok)

	# 11. Follow the host.
	EditorInterface.set_main_screen_editor("2D")
	P.presence.follow(1)
	mark("client_following")
	await wait_mark("host_moved_2d")
	ok = await until(func():
		var fast: Dictionary = P.presence._gather_fast()
		if not fast.has("cam2d"):
			return false
		var c: Array = fast.cam2d
		# Headless editors have zero-size viewports, so only the zoom is meaningful here;
		# the windowed visual test checks the position too.
		return absf(c[2] - 2.0) < 0.01, 10)
	check("follow_2d_zoom", ok, str(P.presence._gather_fast()))
	mark("client_checked_2d")
	await wait_mark("host_moved_3d")
	ok = await until(func():
		var cam := EditorInterface.get_editor_viewport_3d(0).get_camera_3d()
		return cam != null and cam.global_position.distance_to(Vector3(3, 4, 5)) < 0.05, 10)
	check("follow_3d_camera", ok)
	P.presence.stop_follow()
	mark("client_checked_3d")

	# 12. Playtest tunnel: our "game client" talks to the host's "game server" through the session.
	await wait_mark("host_tunnel_ready")
	P.playtest.prepare({"game_port": 47911, "net": true})
	var args := Array(P.playtest.run_args(PackedStringArray()))
	check("client_run_args", args.has("--coop-role=client") and String(args[-1]).begins_with("--coop-connect=127.0.0.1:"), str(args))
	var game := PacketPeerUDP.new()
	game.set_dest_address("127.0.0.1", P.playtest._client_udp.get_local_port())
	game.put_packet("ping from game client".to_utf8_buffer())
	ok = await until(func(): return game.get_available_packet_count() > 0, 15)
	var reply := game.get_packet().get_string_from_utf8() if ok else ""
	check("tunnel_server_to_client", reply == "pong from game server", reply)
	mark("client_tunnel_done")

	# 13. The host ends the session from the companion app.
	ok = await until(func(): return P.session.state == "ended", 15)
	check("session_end_reaches_client", ok, P.session.state)
	await finish()
