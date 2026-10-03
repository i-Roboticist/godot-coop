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
	await finish()

