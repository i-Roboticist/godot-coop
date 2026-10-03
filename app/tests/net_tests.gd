extends SceneTree
## End-to-end networking tests: a relay, a host and joiners in one process over loopback UDP.
##   Godot --headless --path app -s res://tests/net_tests.gd

const Util := preload("res://addons/godot_coop/core/util.gd")
const Session := preload("res://addons/godot_coop/core/session.gd")
const Relay := preload("res://addons/godot_coop/core/relay_server.gd")
const Invite := preload("res://addons/godot_coop/core/invite.gd")
const OT := preload("res://addons/godot_coop/core/ot.gd")

var failures := 0
var checks := 0
var relay: Relay
var sessions: Array = []
var base_dir := ""


func check(cond: bool, what: String) -> void:
	checks += 1
	if not cond:
		failures += 1
		printerr("FAIL: ", what)
	else:
		print("  ok: ", what)


func pump(ms: int, until: Callable = Callable()) -> bool:
	var end := Time.get_ticks_msec() + ms
	while Time.get_ticks_msec() < end:
		if relay != null:
			relay.poll()
		for s in sessions:
			s.poll()
			if s.files != null and s.is_online():
				s.files.scan_step(5000)
		if until.is_valid() and until.call():
			return true
		OS.delay_msec(2)
	return until.is_valid() and until.call()


func write(dir: String, rel: String, text: String) -> void:
	var p := dir.path_join(rel)
	Util.ensure_dir(p.get_base_dir())
	var f := FileAccess.open(p, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func read(dir: String, rel: String) -> String:
	var p := dir.path_join(rel)
	return FileAccess.get_file_as_string(p) if FileAccess.file_exists(p) else "<missing>"


func rmdir(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	for d in DirAccess.get_directories_at(path):
		rmdir(path.path_join(d))
	for f in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(f))
	DirAccess.remove_absolute(path)


func _init() -> void:
	base_dir = OS.get_user_data_dir().path_join("net_tests")
	rmdir(base_dir)
	Util.ensure_dir(base_dir)
	var host_dir := base_dir.path_join("host")
	write(host_dir, "project.godot", "config_version=5\n[application]\nconfig/name=\"Net Test\"\n")
	write(host_dir, "player.gd", "extends Node\n\nvar speed = 200\n")
	write(host_dir, "levels/level1.tscn", "[gd_scene format=3]\n\n[node name=\"Level\" type=\"Node2D\"]\n")
	var big := PackedByteArray()
	big.resize(700 * 1024)
	for i in big.size():
		big[i] = (i * 7) % 251
	var bf := FileAccess.open(host_dir.path_join("art/big.bin"), FileAccess.WRITE) if DirAccess.make_dir_recursive_absolute(host_dir.path_join("art")) == OK else null
	bf.store_buffer(big)
	bf.close()
	write(host_dir, "tools/editor_tool.gd", "@tool\nextends EditorScript\n")

	relay = Relay.new()
	check(relay.start(47690) == OK, "relay starts")

	var host := Session.new()
	sessions.append(host)
	var join_requests := []
	host.join_request.connect(func(req): join_requests.append(req))
	var err := host.host(host_dir, {"name": "Hana", "color": "ff6b6b", "uuid": "host-uuid", "email": "hana@example.com"},
		{"port": 47520, "use_upnp": false, "relay_host": "127.0.0.1", "relay_port": 47690, "include_loopback": true})
	check(err == OK, "host starts")
	check(pump(8000, func(): return host.invites_ready and host.get_invite("editor").short != ""), "invites ready with relay short code")
	var code: String = host.get_invite("editor").code
	print("  invite: ", code, " (", code.length(), " chars), short: ", host.get_invite("editor").short)

	# --- Joiner 1: companion-style download into an empty folder (direct connection) ---------------
	var dl_dir := base_dir.path_join("dl")
	var dl := Session.new()
	sessions.append(dl)
	dl.join(code, {"name": "Dex", "color": "4dabf7", "uuid": "dex-uuid"}, "download", dl_dir)
	check(pump(6000, func(): return not join_requests.is_empty()), "host receives join request")
	check(dl.state == "waiting_approval", "joiner waits for approval (%s)" % dl.state)
	host.approve(join_requests[0].id, "editor")
	check(pump(4000, func(): return dl.state == "connected"), "joiner admitted")
	check(dl.connection_kind == "direct", "joiner used a direct path (%s)" % dl.connection_kind)
	var preview := []
	dl.files.plan_preview.connect(func(p): preview.append(p))
	dl.files.begin_sync(true)
	check(pump(4000, func(): return not preview.is_empty()), "download preview plan arrives")
	if not preview.is_empty():
		check(int(preview[0].count) == 5 and int(preview[0].total) > 700000, "preview lists 5 files / size (%s files)" % preview[0].count)
		var risky_paths := []
		for r in preview[0].risky:
			risky_paths.append(r[0])
		check(risky_paths.has("tools/editor_tool.gd"), "preview flags the @tool script")
	var done := []
	dl.files.sync_finished.connect(func(s): done.append(s))
	dl.files.trust_risky = true
	dl.files.begin_sync(false)
	check(pump(10000, func(): return not done.is_empty()), "download completes")
	check(read(dl_dir, "player.gd") == read(host_dir, "player.gd"), "download: script identical")
	check(FileAccess.get_sha256(dl_dir.path_join("art/big.bin")) == FileAccess.get_sha256(host_dir.path_join("art/big.bin")), "download: 700KB chunked file identical")
	check(read(dl_dir, "project.godot") == read(host_dir, "project.godot"), "download: project.godot included")
	var token := dl._token
	dl.leave()
	sessions.erase(dl)

	# --- The editor reconnects with the companion's token: no second approval --------------------
	var ed1 := Session.new()
	sessions.append(ed1)
	ed1.join(code, {"name": "Dex", "color": "4dabf7", "uuid": "dex-uuid"}, "editor", dl_dir, token)
	ed1.state_changed.connect(func(st, d): print("  [ed1 state] ", st, " ", d, " t=", Time.get_ticks_msec()))
	ed1.log_line.connect(func(l): print("  [ed1] ", l))
	check(pump(6000, func(): return ed1.state == "connected"), "editor joins with token (no approval)")
	check(join_requests.size() == 1, "no extra approval request")
	check(pump(3000, func(): return not ed1.files.is_syncing()), "editor initial sync completes")

	# --- Joiner 2: relay only (no direct candidates) --------------------------------------------
	var inv := Invite.decode(code)
	inv.cands = []
	var relay_only := Invite.encode(inv)
	var ed2_dir := base_dir.path_join("ed2")
	var ed2 := Session.new()
	sessions.append(ed2)
	ed2.join(relay_only, {"name": "Rio", "color": "51cf66", "uuid": "rio-uuid"}, "editor", ed2_dir)
	check(pump(8000, func(): return join_requests.size() == 2), "relay joiner request arrives")
	host.approve(join_requests[1].id, "editor")
	check(pump(6000, func(): return ed2.state == "connected"), "relay joiner admitted")
	check(ed2.connection_kind == "relay" or ed2.connection_kind == "direct", "relay joiner connected via %s" % ed2.connection_kind)
	ed2.files.trust_risky = true
	check(pump(12000, func(): return not ed2.files.is_syncing() and read(ed2_dir, "player.gd") == read(host_dir, "player.gd")), "relay joiner synced files")
	check(not FileAccess.file_exists(ed2_dir.path_join("project.godot")), "editor-mode sync leaves project.godot to settings sync")
	check(host.roster.size() == 3, "roster has 3 people (%d)" % host.roster.size())

	# --- Live file changes in every direction --------------------------------------------------
	write(host_dir, "notes.txt", "from host")
	check(pump(6000, func(): return read(dl_dir, "notes.txt") == "from host" and read(ed2_dir, "notes.txt") == "from host"), "host change reaches both joiners")
	write(ed2_dir, "player.gd", "extends Node\n\nvar speed = 250\n")
	check(pump(6000, func(): return read(host_dir, "player.gd").find("250") != -1 and read(dl_dir, "player.gd").find("250") != -1), "joiner change reaches host and other joiner")
	DirAccess.remove_absolute(dl_dir.path_join("notes.txt"))
	check(pump(6000, func(): return not FileAccess.file_exists(host_dir.path_join("notes.txt")) and not FileAccess.file_exists(ed2_dir.path_join("notes.txt"))), "deletes propagate")
	write(ed2_dir, "tools/sneaky.gd", "@tool\nextends Node\nfunc _ready(): OS.shell_open(\"x\")\n")
	check(pump(5000, func(): return host.files.quarantine.has("tools/sneaky.gd")), "host quarantines a new @tool script")
	check(not FileAccess.file_exists(host_dir.path_join("tools/sneaky.gd")), "quarantined file not written")
	host.files.reject_quarantined("tools/sneaky.gd")
	check(pump(5000, func(): return not FileAccess.file_exists(ed2_dir.path_join("tools/sneaky.gd"))), "rejected file removed from sender")

	# --- Roles: viewers can't write ------------------------------------------------------------
	host.set_peer_role(ed2.my_pid, "viewer")
	check(pump(3000, func(): return ed2.role == "viewer"), "role change reaches joiner")
	write(ed2_dir, "player.gd", "VIEWER EDIT")
	check(pump(6000, func(): return read(ed2_dir, "player.gd").find("250") != -1), "viewer edit reverted from host")
	check(read(host_dir, "player.gd").find("VIEWER") == -1, "viewer edit never reached host")
	host.set_peer_role(ed2.my_pid, "editor", ["res://art"])
	pump(500)
	write(ed2_dir, "art/sprite.txt", "allowed")
	write(ed2_dir, "player.gd", "NOT ALLOWED")
	check(pump(6000, func(): return read(host_dir, "art/sprite.txt") == "allowed" and read(ed2_dir, "player.gd").find("250") != -1), "folder-restricted editor: allowed folder syncs, others revert")
	host.set_peer_role(ed2.my_pid, "editor", [])
	pump(300)

	# --- Live text editing (OT) ---------------------------------------------------------------
	var tx := {1: [], ed1.my_pid: [], ed2.my_pid: []}
	var states := {}
	for s in [host, ed1, ed2]:
		var me = s
		s.message.connect(func(m):
			if String(m.get("t", "")).begins_with("tx_"):
				tx[me.my_pid].append(m))
	for s in [host, ed1, ed2]:
		s.send({"t": "tx_open", "path": "res://player.gd"}, Session.CH_LIVE)
	check(pump(3000, func():
		for k in tx:
			var has := false
			for m in tx[k]:
				if m.t == "tx_state":
					has = true
					states[k] = m
			if not has:
				return false
		return true), "everyone gets tx_state")
	var base_text: String = states[1].text if states.has(1) else ""
	var epoch: String = states[1].epoch if states.has(1) else ""
	var op1 := OT.diff(base_text, "# A\n" + base_text)
	var op2 := OT.diff(base_text, base_text + "# B\n")
	ed1.send({"t": "tx_op", "path": "res://player.gd", "rev": 0, "op": op1.to_array(), "cseq": 1, "epoch": epoch}, Session.CH_LIVE)
	ed2.send({"t": "tx_op", "path": "res://player.gd", "rev": 0, "op": op2.to_array(), "cseq": 1, "epoch": epoch}, Session.CH_LIVE)
	check(pump(3000, func():
		var n := 0
		for m in tx[1]:
			if m.t == "tx_op":
				n += 1
		return n == 2), "host broadcasts both concurrent edits")
	var doc = host.docs.texts.get("res://player.gd")
	check(doc != null and doc.text.begins_with("# A\n") and doc.text.ends_with("# B\n"), "concurrent edits both survive (transformed)")

	# Reopening a script starts a new client whose sequence numbers start over: its first edit must
	# not be dropped as a duplicate of the old client's.
	ed1.send({"t": "tx_close", "path": "res://player.gd"}, Session.CH_LIVE)
	tx[ed1.my_pid].clear()
	ed1.send({"t": "tx_open", "path": "res://player.gd"}, Session.CH_LIVE)
	check(pump(3000, func(): return tx[ed1.my_pid].any(func(m): return m.t == "tx_state")), "reopened script gets the document")
	var st2: Dictionary = tx[ed1.my_pid].filter(func(m): return m.t == "tx_state")[0] if tx[ed1.my_pid].any(func(m): return m.t == "tx_state") else {}
	var t2 := String(st2.get("text", ""))
	ed1.send({"t": "tx_op", "path": "res://player.gd", "rev": int(st2.get("rev", 0)), "op": OT.diff(t2, t2 + "# after reopen\n").to_array(), "cseq": 1, "cid": "reopened", "epoch": epoch}, Session.CH_LIVE)
	check(pump(3000, func(): return doc.text.contains("# after reopen")), "first edit after reopening is applied")

	# A live editor saves while one of its edits is still on its way: the save must not be merged
	# into the document as well (that duplicated text), and the edit must land once.
	ed1.files.live_fn = func(rel): return rel == "player.gd"
	var live_rev: int = doc.rev
	var live_text: String = doc.text
	var with_edit := live_text + "# saved before sent\n"
	write(dl_dir, "player.gd", with_edit)
	ed1.files.check_path("player.gd")
	check(pump(4000, func(): return read(host_dir, "player.gd") == with_edit), "live save reaches the host's disk")
	check(not doc.text.contains("# saved before sent"), "live save isn't merged into the document")
	ed1.send({"t": "tx_op", "path": "res://player.gd", "rev": live_rev, "op": OT.diff(live_text, with_edit).to_array(), "cseq": 2, "cid": "reopened", "epoch": epoch}, Session.CH_LIVE)
	check(pump(3000, func(): return doc.text.contains("# saved before sent")), "the edit itself arrives")
	check(doc.text.count("# saved before sent") == 1, "and appears once")
	ed1.files.live_fn = Callable()

	# Someone without the file open live (an external editor) changes it: merged in, live edits kept.
	check(pump(4000, func(): return read(ed2_dir, "player.gd") == read(host_dir, "player.gd")), "the save reaches the other joiner")
	var unsaved_rev: int = doc.rev
	var unsaved_text: String = doc.text
	ed1.send({"t": "tx_op", "path": "res://player.gd", "rev": unsaved_rev, "op": OT.diff(unsaved_text, unsaved_text + "# live, not saved\n").to_array(), "cseq": 3, "cid": "reopened", "epoch": epoch}, Session.CH_LIVE)
	check(pump(3000, func(): return doc.text.contains("# live, not saved")), "a live edit after the save")
	write(ed2_dir, "player.gd", "# external edit\n" + read(ed2_dir, "player.gd"))
	check(pump(4000, func(): return doc.text.begins_with("# external edit\n")), "external edit merged into the live document")
	check(doc.text.contains("# live, not saved") and doc.text.contains("# after reopen") and doc.text.count("# saved before sent") == 1, "live edits survive the external edit (%s)" % doc.text.c_escape())

	# A script just created on a joiner: the host doesn't have it yet, so the opener's text wins.
	tx[ed2.my_pid].clear()
	ed2.send({"t": "tx_open", "path": "res://brand_new.gd"}, Session.CH_LIVE)
	check(pump(3000, func(): return tx[ed2.my_pid].any(func(m): return m.t == "tx_state" and m.path == "res://brand_new.gd" and m.get("missing", false))), "opening a file the host doesn't have yet says so")
	ed2.send({"t": "tx_close", "path": "res://brand_new.gd"}, Session.CH_LIVE)

	# --- Live scene doc --------------------------------------------------------------------------
	var sc := {1: [], ed1.my_pid: []}
	for s in [host, ed1]:
		var me = s
		s.message.connect(func(m):
			if String(m.get("t", "")).begins_with("sc_") or m.get("t") == "lock_state":
				sc[me.my_pid].append(m))
	ed1.send({"t": "sc_open", "path": "res://levels/level1.tscn"}, Session.CH_LIVE)
	check(pump(2000, func(): return sc[ed1.my_pid].any(func(m): return m.t == "sc_need_snapshot")), "first opener is asked for a snapshot")
	ed1.send({"t": "sc_snapshot", "path": "res://levels/level1.tscn", "nodes": [{"id": "root", "p": "", "n": "Level", "c": "Node2D", "props": {}}]}, Session.CH_LIVE)
	host.send({"t": "sc_open", "path": "res://levels/level1.tscn"}, Session.CH_LIVE)
	check(pump(2000, func(): return sc[1].any(func(m): return m.t == "sc_state")), "second opener gets the doc state")
	ed1.send({"t": "sc_ops", "path": "res://levels/level1.tscn", "cseq": 1, "ops": [{"k": "add", "id": "n1", "p": "root", "n": "Enemy", "c": "CharacterBody2D", "props": {"position": Vector2(5, 5)}}]}, Session.CH_LIVE)
	check(pump(2000, func(): return sc[1].any(func(m): return m.t == "sc_ops" and m.ops.size() == 1)), "scene op broadcast to other watcher")
	host.send({"t": "lock", "path": "res://levels/level1.tscn", "on": true}, Session.CH_LIVE)
	pump(300)
	ed1.send({"t": "sc_ops", "path": "res://levels/level1.tscn", "cseq": 2, "ops": [{"k": "set", "id": "n1", "props": {"position": Vector2(9, 9)}}]}, Session.CH_LIVE)
	check(pump(2000, func(): return sc[ed1.my_pid].any(func(m): return m.t == "sc_reject" and m.reason == "locked")), "locked scene rejects other editors")

	# --- Chat / activity / presence ---------------------------------------------------------------
	var chats := []
	ed2.chat_received.connect(func(e): chats.append(e))
	ed1.send({"t": "chat", "text": "hello team"})
	check(pump(2000, func(): return chats.size() == 1 and chats[0].name == "Dex"), "chat reaches others")
	check(ed2.activity_log.size() > 3, "activity feed populated (%d)" % ed2.activity_log.size())

	# --- Reconnect: drop ed2's network and let it come back ------------------------------------------
	# ed2 alone has a script open with an edit in it. When it drops, the host keeps the document so
	# the reconnect resumes it (replaying what was missed) instead of starting over from the file.
	tx[ed2.my_pid].clear()
	ed2.send({"t": "tx_open", "path": "res://tools/editor_tool.gd"}, Session.CH_LIVE)
	check(pump(3000, func(): return tx[ed2.my_pid].any(func(m): return m.t == "tx_state" and m.path == "res://tools/editor_tool.gd")), "joiner opens a script only it is editing")
	var solo: Dictionary = tx[ed2.my_pid].filter(func(m): return m.t == "tx_state" and m.path == "res://tools/editor_tool.gd")[0]
	var solo_op: Array = OT.diff(String(solo.text), String(solo.text) + "# solo edit\n").to_array()
	var solo_msg := {"t": "tx_op", "path": "res://tools/editor_tool.gd", "rev": int(solo.rev), "op": solo_op, "cseq": 1, "cid": "solo", "epoch": String(solo.epoch)}
	ed2.send(solo_msg, Session.CH_LIVE)
	check(pump(3000, func(): return host.docs.texts.has("res://tools/editor_tool.gd") and host.docs.texts["res://tools/editor_tool.gd"].text.contains("# solo edit")), "solo edit applied")
	var ed2_pid := ed2.my_pid
	ed2.net.stop()
	ed2._conn = null
	ed2._start_reconnect("test drop")
	check(pump(20000, func(): return ed2.state == "connected"), "joiner reconnects automatically")
	check(ed2.my_pid == ed2_pid, "reconnect keeps the same peer id")
	check(host.docs.texts.has("res://tools/editor_tool.gd"), "host kept the dropped joiner's document")
	tx[ed2.my_pid].clear()
	ed2.send({"t": "tx_open", "path": "res://tools/editor_tool.gd", "epoch": String(solo.epoch), "rev": int(solo.rev)}, Session.CH_LIVE)
	check(pump(3000, func(): return tx[ed2.my_pid].any(func(m): return m.t == "tx_state" and m.since is Array and m.epoch == solo.epoch)), "reconnect resumes the same document with a replay")
	ed2.send(solo_msg, Session.CH_LIVE)  # resent after the reconnect, as the client does
	pump(500)
	check(host.docs.texts["res://tools/editor_tool.gd"].text.count("# solo edit") == 1, "a resent edit isn't applied twice")
	write(host_dir, "after_reconnect.txt", "yes")
	check(pump(6000, func(): return read(ed2_dir, "after_reconnect.txt") == "yes"), "sync works after reconnect")

	# --- A different Godot version is turned away (with the version it needs) ---------------------
	var odd := Session.new()
	sessions.append(odd)
	var denials := []
	odd.message.connect(func(m):
		if m.get("t") == "denied":
			denials.append(m))
	odd.version_override = {"major": 3, "minor": 5, "patch": 0, "status": "stable", "dotnet": false}
	odd.join(code, {"name": "Old", "color": "999999", "uuid": "old"}, "editor", base_dir.path_join("odd"))
	check(pump(6000, func(): return odd.state == "failed"), "version mismatch is refused")
	check(not denials.is_empty() and denials[0].code == "version" and int(denials[0].need.minor) == Engine.get_version_info().minor, "refusal says which version is needed")
	sessions.erase(odd)

	# --- Kick / end ------------------------------------------------------------------------------
	host.kick(ed2.my_pid)
	check(pump(3000, func(): return ed2.state == "ended"), "kicked joiner is told")
	host.end_session()
	check(pump(3000, func(): return ed1.state == "ended"), "ending the session reaches joiners (%s: %s)" % [ed1.state, ed1.state_detail])
	relay.stop()
	print("net tests: %d checks, %d failures" % [checks, failures])
	quit(1 if failures > 0 else 0)
