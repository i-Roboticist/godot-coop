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
	await wait_mark("client_done", 120)
	await finish()
