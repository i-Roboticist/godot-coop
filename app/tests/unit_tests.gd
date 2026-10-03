extends SceneTree
## Unit tests for the core library. Run:
##   Godot --headless --path app -s res://tests/unit_tests.gd

const Util := preload("res://addons/godot_coop/core/util.gd")
const OT := preload("res://addons/godot_coop/core/ot.gd")
const OTClient := preload("res://addons/godot_coop/core/ot_client.gd")
const TextDoc := preload("res://addons/godot_coop/core/text_doc.gd")
const CryptoBox := preload("res://addons/godot_coop/core/crypto_box.gd")
const Invite := preload("res://addons/godot_coop/core/invite.gd")
const FileSync := preload("res://addons/godot_coop/core/file_sync.gd")
const SceneDoc := preload("res://addons/godot_coop/core/scene_doc.gd")
const Wire := preload("res://addons/godot_coop/core/wire.gd")
const Security := preload("res://addons/godot_coop/core/security.gd")

var failures := 0
var checks := 0


func check(cond: bool, what: String) -> void:
	checks += 1
	if not cond:
		failures += 1
		printerr("FAIL: ", what)


func _init() -> void:
	seed(12345)
	test_ot_basics()
	test_ot_fuzz()
	test_ot_client_server()
	test_crypto()
	test_invite()
	test_paths()
	test_plan()
	test_scene_doc()
	test_wire()
	test_security()
	print("unit tests: %d checks, %d failures" % [checks, failures])
	quit(1 if failures > 0 else 0)


func rand_text(n: int) -> String:
	var chars := "abcdefgh \nxyz{}"
	var s := ""
	for i in n:
		s += chars[randi() % chars.length()]
	return s


func rand_op(text: String) -> RefCounted:
	var op := OT.create()
	var i := 0
	var n := text.length()
	while i < n:
		var r := randi() % 10
		var len := 1 + randi() % maxi(1, mini(5, n - i))
		len = mini(len, n - i)
		if r < 5:
			op.retain(len)
			i += len
		elif r < 7:
			op.insert(rand_text(1 + randi() % 4))
		else:
			op.delete(len)
			i += len
	if randi() % 3 == 0:
		op.insert(rand_text(1 + randi() % 3))
	return op


func test_ot_basics() -> void:
	var op := OT.create()
	op.retain(5).insert(" world").delete(0)
	check(op.apply("hello") == "hello world", "ot apply insert")
	var d := OT.diff("hello world", "hello brave world")
	check(d.apply("hello world") == "hello brave world", "ot diff insert")
	var d2 := OT.diff("abcdef", "abXYef")
	check(d2.apply("abcdef") == "abXYef", "ot diff replace")
	var inv = d2.invert("abcdef")
	check(inv.apply("abXYef") == "abcdef", "ot invert")
	var arr: Array = d2.to_array()
	var back := OT.from_array(arr)
	check(back != null and back.apply("abcdef") == "abXYef", "ot array roundtrip")
	check(OT.from_array([1, 0]) == null, "ot rejects zero component")
	var ins = OT.create().retain(2).insert("ZZ").retain(3)
	check(ins.transform_index(1) == 1 and ins.transform_index(3) == 5 and ins.transform_index(2) == 4, "ot transform_index")


func test_ot_fuzz() -> void:
	var ok_t := true
	var ok_c := true
	var ok_i := true
	for i in 400:
		var s := rand_text(randi() % 30)
		var a := rand_op(s)
		var b := rand_op(s)
		var pair := OT.transform(a, b)
		if pair.is_empty():
			ok_t = false
			continue
		var x = pair[1].apply(a.apply(s))
		var y = pair[0].apply(b.apply(s))
		if x == null or x != y:
			ok_t = false
		var after_a: String = a.apply(s)
		var c := rand_op(after_a)
		var comp = a.compose(c)
		if comp == null or comp.apply(s) != c.apply(after_a):
			ok_c = false
		if a.invert(s).apply(after_a) != s:
			ok_i = false
	check(ok_t, "ot transform convergence (fuzz)")
	check(ok_c, "ot compose (fuzz)")
	check(ok_i, "ot invert (fuzz)")


## Three clients edit concurrently with random delivery order; everyone must converge.
func test_ot_client_server() -> void:
	for round in 30:
		var start := rand_text(20)
		var server := TextDoc.new("res://t.gd", start)
		var clients := []
		var texts := []
		var to_server := []   # [client index, rev, op array, cseq]
		var inbox := [[], [], []]
		for c in 3:
			var cl := OTClient.new()
			cl.reset(0, server.epoch)
			var idx := c
			cl.send_op.connect(func(rev, op, cseq): to_server.append([idx, rev, op.to_array(), cseq]))
			clients.append(cl)
			texts.append(start)
		for step in 60:
			var c := randi() % 3
			var action := randi() % 4
			if action <= 1:
				var before: String = texts[c]
				var op := rand_op(before)
				texts[c] = op.apply(before)
				clients[c].apply_client(op, before)
			elif action == 2 and not to_server.is_empty():
				var m: Array = to_server.pop_front()
				var applied = server.receive(m[1], OT.from_array(m[2]), str(m[0]), m[3])
				if applied != null:
					for k in 3:
						inbox[k].append([m[0], applied.to_array()])
			elif action == 3 and not inbox[c].is_empty():
				var m: Array = inbox[c].pop_front()
				if m[0] == c:
					clients[c].server_ack()
				else:
					var op = clients[c].apply_server(OT.from_array(m[1]))
					texts[c] = op.apply(texts[c])
			elif action == 3 and clients[c].can_undo() and randi() % 4 == 0:
				var undo_op = clients[c].pop_undo()
				var before: String = texts[c]
				var res = undo_op.apply(before)
				if res != null:
					texts[c] = res
					clients[c].finish_undo_redo(undo_op, before)
		# drain everything
		var guard := 0
		while guard < 10000 and (not to_server.is_empty() or not inbox[0].is_empty() or not inbox[1].is_empty() or not inbox[2].is_empty()):
			guard += 1
			if not to_server.is_empty():
				var m: Array = to_server.pop_front()
				var applied = server.receive(m[1], OT.from_array(m[2]), str(m[0]), m[3])
				if applied != null:
					for k in 3:
						inbox[k].append([m[0], applied.to_array()])
			for c in 3:
				if not inbox[c].is_empty():
					var m: Array = inbox[c].pop_front()
					if m[0] == c:
						clients[c].server_ack()
					else:
						var op = clients[c].apply_server(OT.from_array(m[1]))
						texts[c] = op.apply(texts[c])
		var same: bool = texts[0] == server.text and texts[1] == server.text and texts[2] == server.text
		check(same, "ot 3-client convergence round %d" % round)
		if not same:
			print("server: ", server.text.c_escape(), "\nc0: ", texts[0].c_escape(), "\nc1: ", texts[1].c_escape(), "\nc2: ", texts[2].c_escape())
			return


func test_crypto() -> void:
	var secret := Util.random_bytes(16)
	var nc := Util.random_bytes(16)
	var nh := Util.random_bytes(16)
	var host := CryptoBox.new()
	var client := CryptoBox.new()
	host.setup(secret, nc, nh, true)
	client.setup(secret, nc, nh, false)
	var msg := {"t": "hello", "data": Util.random_bytes(100), "s": "x".repeat(5000)}
	var pkt := client.seal(1, msg)
	var got = host.open(1, pkt)
	check(got is Dictionary and got.s == msg.s and got.data == msg.data, "crypto roundtrip (compressed)")
	check(host.open(1, pkt) == null, "crypto replay rejected")
	var pkt2 := client.seal(1, {"t": "x"})
	pkt2[20] = pkt2[20] ^ 1
	check(host.open(1, pkt2) == null, "crypto tamper rejected")
	var pkt3 := client.seal(2, {"t": "y"})
	check(host.open(3, pkt3) == null, "crypto wrong channel rejected")
	var reflect := host.seal(0, {"t": "z"})
	check(host.open(0, reflect) == null, "crypto reflection rejected")
	var wrong := CryptoBox.new()
	wrong.setup(Util.random_bytes(16), nc, nh, true)
	check(wrong.open(0, client.seal(0, {"t": "q"})) == null, "crypto wrong secret rejected")
	check(client.open(0, host.seal(0, {"t": "back"})).t == "back", "crypto host->client")
	check(CryptoBox.decode_plain(CryptoBox.encode_plain({"t": "p"})).t == "p", "plain roundtrip")
	check(CryptoBox.decode_plain(PackedByteArray([1, 2, 3])) == null, "plain garbage rejected")


func test_invite() -> void:
	var info := Invite.make(Util.random_bytes(16), Util.random_bytes(6), "viewer",
		[[Invite.KIND_LAN, "192.168.1.20", 47500], [Invite.KIND_PUBLIC, "203.0.113.9", 47500]],
		"relay.example.com", 47600, "a1b2c3d4e5", "My Game")
	var code := Invite.encode(info)
	var back := Invite.decode(code)
	check(not back.is_empty() and back.secret == info.secret and back.iid == info.iid, "invite roundtrip keys")
	check(back.role == "viewer" and back.cands.size() == 2 and back.cands[1][1] == "203.0.113.9", "invite roundtrip cands")
	check(back.relay_host == "relay.example.com" and back.relay_port == 47600 and back.room == "a1b2c3d4e5" and back.project == "My Game", "invite roundtrip relay")
	check(not Invite.decode("godotcoop://join/" + code).is_empty(), "invite from link")
	check(not Invite.decode("https://x.github.io/join/#" + code).is_empty(), "invite from web link")
	check(Invite.decode("gdc1.!!!").is_empty() and Invite.decode("hello").is_empty(), "invite garbage")
	check(code.length() < 200, "invite code is reasonably short (%d)" % code.length())
	var sc := Invite.random_short_code()
	check(Invite.is_short_code(Invite.pretty_short_code(sc)), "short code format")


func test_paths() -> void:
	for good in ["a.gd", "scenes/level 1/x.tscn", ".gitignore", "addons/foo/plugin.cfg"]:
		check(Util.is_safe_rel_path(good), "safe path " + good)
	for bad in ["", "../x", "a/../../x", "/etc/passwd", "C:/x", "a\\b", "a//b", "con.txt", "x/./y", "dir/name. ", "a\u0001b"]:
		check(not Util.is_safe_rel_path(bad), "unsafe path " + bad)
	check(Util.is_ignored(".godot/imported/x.ctex"), "ignore .godot")
	check(Util.is_ignored(".coop/state.json"), "ignore .coop")
	check(Util.is_ignored("addons/godot_coop/plugin.gd"), "ignore own addon")
	check(not Util.is_ignored("addons/other/plugin.gd"), "don't ignore other addons")
	check(Util.is_ignored("x.tscn.tmp") and Util.is_ignored("art/~$doc.docx"), "ignore temp files")
	check(Util.is_ignored("build/out.exe", PackedStringArray(["build/"])), "coopignore dir")
	check(Util.is_ignored("a/b.psd", PackedStringArray(["*.psd"])), "coopignore glob")
	check(Util.is_safe_res_path("res://a/b.png") and not Util.is_safe_res_path("res://../x") and not Util.is_safe_res_path("user://x"), "res paths")


func test_plan() -> void:
	var host := {"same": "1", "host_changed": "2b", "client_changed": "3", "both": "4h", "host_new": "5", "client_deleted": "6", "host_deleted_gone": ""}
	host.erase("host_deleted_gone")
	var client := {
		"same": ["1", "1"], "host_changed": ["2", "2"], "client_changed": ["3c", "3"], "both": ["4c", "4"],
		"client_deleted": ["", "6"], "client_new": ["7", ""], "host_deleted": ["8", "8"],
	}
	var allow := func(_r): return true
	var plan := FileSync.plan_sync(host, client, allow)
	check(plan.send.has("host_changed") and plan.send.has("both") and plan.send.has("host_new"), "plan send")
	check(plan.upload.has("client_changed") and plan.upload.has("client_new"), "plan upload")
	check(plan.host_delete.has("client_deleted"), "plan host delete")
	check(plan.delete.has("host_deleted"), "plan client delete")
	check(plan.conflicts.has("both") and plan.conflicts.size() == 1, "plan conflicts")
	check(not plan.send.has("same") and not plan.upload.has("same"), "plan unchanged")
	var deny := func(_r): return false
	var p2 := FileSync.plan_sync(host, client, deny)
	check(p2.upload.is_empty() and p2.send.has("client_changed") and p2.conflicts.has("client_changed"), "plan read-only peer: host wins")


func test_scene_doc() -> void:
	var doc := SceneDoc.new("res://a.tscn")
	var ok := doc.load_snapshot([
		{"id": "r", "p": "", "n": "Root", "c": "Node2D", "props": {}},
		{"id": "a", "p": "r", "n": "A", "c": "Sprite2D", "props": {"position": Vector2(1, 2)}},
		{"id": "b", "p": "r", "n": "B", "c": "Node2D", "props": {}},
	])
	check(ok, "scene doc load")
	check(doc.path_of("a") == "A" and doc.path_of("r") == ".", "scene doc paths")
	var r = doc.apply({"k": "add", "id": "c", "p": "r", "n": "A", "c": "Node", "si": 0})
	check(r != null and r.n == "A2" and r.fixed, "scene doc dedupes names")
	check(doc.children["r"][0] == "c", "scene doc insert index")
	check(doc.apply({"k": "move", "id": "r", "p": "a"}) == null, "scene doc can't move root")
	check(doc.apply({"k": "move", "id": "a", "p": "b", "si": 0}) != null and doc.path_of("a") == "B/A", "scene doc move")
	check(doc.apply({"k": "move", "id": "b", "p": "a"}) == null, "scene doc no cycles")
	check(doc.apply({"k": "set", "id": "a", "props": {"z_index": 3}, "reset": ["position"]}) != null, "scene doc set")
	check(doc.nodes["a"].props.has("z_index") and not doc.nodes["a"].props.has("position"), "scene doc set/reset applied")
	check(doc.apply({"k": "del", "id": "b"}) != null and not doc.nodes.has("a"), "scene doc delete subtree")
	check(doc.apply({"k": "set", "id": "a", "props": {}}) == null, "scene doc reject missing")
	var snap := doc.snapshot()
	var doc2 := SceneDoc.new("res://a.tscn")
	check(doc2.load_snapshot(snap) and doc2.snapshot() == snap, "scene doc snapshot roundtrip")


func test_wire() -> void:
	var w := Wire.new()
	var shape := RectangleShape2D.new()
	shape.size = Vector2(10, 20)
	var wf = w.to_wire(shape)
	check(wf is Dictionary and wf.has("$sub") and wf.cls == "RectangleShape2D", "wire sub-resource")
	var w2 := Wire.new()
	var shape_b := RectangleShape2D.new()
	var back = w2.from_wire(wf, shape_b)
	check(back == shape_b and shape_b.size == Vector2(10, 20), "wire updates resource in place")
	var fresh = w2.from_wire(wf, null)
	check(fresh == shape_b, "wire reuses rid mapping")
	var typed: Array[int] = [1, 2, 3]
	var tw = w.to_wire(typed)
	var tb = w.from_wire(tw)
	check(tb is Array and tb.is_typed() and tb.get_typed_builtin() == TYPE_INT and tb == typed, "wire typed array")
	var d := {"a": 1, "b": [Vector2(1, 1)], 3: Color.RED}
	check(w.from_wire(w.to_wire(d)) == d, "wire dictionary")
	check(w.to_wire(Vector3(1, 2, 3)) == Vector3(1, 2, 3), "wire primitive")
	check(Util.same(w.to_wire(shape), w.to_wire(shape)), "wire stable for comparison")
	check(Wire.describe(Vector2(1, 2)) == "(1.0, 2.0)", "wire describe")


func test_security() -> void:
	var dir := OS.get_user_data_dir().path_join("sec_test")
	Util.ensure_dir(dir)
	var f := FileAccess.open(dir.path_join("t.gd"), FileAccess.WRITE)
	f.store_string("@tool\nextends Node\n")
	f.close()
	var g := FileAccess.open(dir.path_join("n.gd"), FileAccess.WRITE)
	g.store_string("extends Node\n")
	g.close()
	check(not Security.risk_reason("t.gd", dir.path_join("t.gd")).is_empty(), "security flags @tool")
	check(Security.risk_reason("n.gd", dir.path_join("n.gd")).is_empty(), "security ignores plain script")
	check(not Security.risk_reason("bin/x.dll", dir.path_join("n.gd")).is_empty(), "security flags dll")
	var s := FileAccess.open(dir.path_join("s.tscn"), FileAccess.WRITE)
	s.store_string("[sub_resource type=\"GDScript\"]\nscript/source = \"@tool\\nextends Node\"\n")
	s.close()
	check(not Security.risk_reason("s.tscn", dir.path_join("s.tscn")).is_empty(), "security flags embedded tool script")
