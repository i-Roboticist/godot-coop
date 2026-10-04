extends SceneTree
## Hosts or joins over the real internet, to test connections between two different networks.
##   Godot --headless --path app -s res://tests/inet_probe.gd -- host [--topic T] [--no-upnp] [--seconds 600]
##   Godot --headless --path app -s res://tests/inet_probe.gd -- join (<invite> | --topic T) [--no-upnp] [--keep-lan]
## With --topic, the host posts its invite to ntfy.sh/<T> and the joiner picks it up from there.
## The joiner downloads the host's little test project and checks every byte arrived. Unless
## --keep-lan is given, it drops the host's LAN addresses from the invite, so only the internet
## path can work. Exit code 0 means it worked.

const Util := preload("res://addons/godot_coop/core/util.gd")
const Session := preload("res://addons/godot_coop/core/session.gd")
const Invite := preload("res://addons/godot_coop/core/invite.gd")

var args := {}
var session: Session = null
var t0 := 0


func say(s: String) -> void:
	print("[%6.1fs] %s" % [(Time.get_ticks_msec() - t0) / 1000.0, s])


func _initialize() -> void:
	t0 = Time.get_ticks_msec()
	var a := OS.get_cmdline_user_args()
	var i := 0
	var pos := []
	while i < a.size():
		if a[i].begins_with("--"):
			var k := a[i].substr(2)
			if i + 1 < a.size() and not a[i + 1].begins_with("--") and k in ["topic", "seconds"]:
				args[k] = a[i + 1]
				i += 1
			else:
				args[k] = true
		else:
			pos.append(a[i])
		i += 1
	var role := String(pos[0]) if not pos.is_empty() else ""
	var ok := false
	if role == "host":
		ok = run_host()
	elif role == "join":
		ok = run_join(String(pos[1]) if pos.size() > 1 else "")
	else:
		printerr("usage: inet_probe.gd -- host|join ...")
	if session != null and session.net != null:
		session.net.stop()
	say("RESULT: " + ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)


static func content(n: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(n)
	for k in n:
		b[k] = (k * 31 + 7) % 253
	return b


func pump(ms: int, until: Callable) -> bool:
	var end := Time.get_ticks_msec() + ms
	while Time.get_ticks_msec() < end:
		session.poll()
		if session.files != null and session.is_online():
			session.files.scan_step(5000)
		if until.call():
			return true
		OS.delay_msec(3)
	return until.call()


func hook_logs() -> void:
	session.log_line.connect(func(l): say("log: " + l))
	session.state_changed.connect(func(st, d): say("state: %s %s" % [st, d]))


func run_host() -> bool:
	var dir := OS.get_user_data_dir().path_join("inet_probe/host")
	Util.ensure_dir(dir.path_join("art"))
	var f := FileAccess.open(dir.path_join("project.godot"), FileAccess.WRITE)
	f.store_string("config_version=5\n[application]\nconfig/name=\"Internet Probe\"\n")
	f.close()
	f = FileAccess.open(dir.path_join("art/blob.bin"), FileAccess.WRITE)
	f.store_buffer(content(300 * 1024))
	f.close()
	f = FileAccess.open(dir.path_join("main.gd"), FileAccess.WRITE)
	f.store_string("extends Node\n# made by the internet probe\n")
	f.close()
	session = Session.new()
	hook_logs()
	var err := session.host(dir, {"name": "Probe host", "color": "ff6b6b", "uuid": "probe-host"},
		{"port": 47540, "use_upnp": not args.has("no-upnp"), "auto_accept_all": true})
	if err != OK:
		say("couldn't host: %s" % session.state_detail)
		return false
	pump(15000, func(): return session.invites_ready and session.public_ip != "" or session.nat_type == "blocked")
	var code: String = session.get_invite("editor").code
	say("invite: " + code)
	say(session.internet_status())
	say(session.upnp_status)
	if args.has("topic"):
		say("posted invite to ntfy topic: %s" % post_ntfy(String(args.topic), code))
	var joined := false
	var left := false
	session.roster_changed.connect(func():
		for pid in session.roster:
			var r: Dictionary = session.roster[pid]
			if int(pid) != 1 and r.online:
				joined = true
			if int(pid) != 1 and joined and not r.online:
				left = true)
	var seconds := int(args.get("seconds", "600"))
	pump(seconds * 1000, func(): return left)
	say("joiner connected: %s, left: %s" % [joined, left])
	session.end_session("Probe done.", true)
	return joined


func run_join(code: String) -> bool:
	if code.is_empty() and args.has("topic"):
		say("waiting for an invite on ntfy topic %s…" % args.topic)
		var end := Time.get_ticks_msec() + 300000
		while code.is_empty() and Time.get_ticks_msec() < end:
			code = fetch_ntfy(String(args.topic))
			if code.is_empty():
				OS.delay_msec(3000)
	var inv := Invite.decode(code)
	if inv.is_empty():
		say("no valid invite")
		return false
	say("host candidates in the invite: %s, flags %d" % [inv.cands, int(inv.get("flags", 0))])
	if not args.has("keep-lan"):
		inv.cands = []
		code = Invite.encode(inv)
	var dir := OS.get_user_data_dir().path_join("inet_probe/join_%d" % Time.get_ticks_msec())
	session = Session.new()
	hook_logs()
	session.settings.use_upnp = not args.has("no-upnp")
	var started := Time.get_ticks_msec()
	session.join(code, {"name": "Probe joiner", "color": "4dabf7", "uuid": "probe-join-%d" % started}, "download", dir)
	var ok := pump(60000, func(): return session.state == "connected" or session.state == "failed")
	say("our side: %s" % [session._rdv_info])
	if session.state != "connected":
		say("not connected: %s" % session.state_detail)
		return false
	var rtt: int = session.net.link_rtt(session._conn.link)
	say("CONNECTED via %s to %s in %d ms, round trip %d ms" % [session.connection_kind, session._conn.link.remote, Time.get_ticks_msec() - started, rtt])
	var done := []
	session.files.sync_finished.connect(func(s): done.append(s))
	session.files.trust_risky = true
	session.files.begin_sync(false)
	ok = pump(120000, func(): return not done.is_empty())
	var blob := FileAccess.get_file_as_bytes(dir.path_join("art/blob.bin"))
	var intact := ok and blob == content(300 * 1024) and FileAccess.get_file_as_string(dir.path_join("main.gd")).contains("internet probe")
	say("download finished: %s, files intact: %s" % [ok, intact])
	session.leave()
	pump(1500, func(): return false)
	return intact


func _https(method: int, path: String, body := "") -> String:
	var h := HTTPClient.new()
	if h.connect_to_host("ntfy.sh", 443, TLSOptions.client()) != OK:
		return ""
	var end := Time.get_ticks_msec() + 15000
	var sent := false
	var out := PackedByteArray()
	while Time.get_ticks_msec() < end:
		h.poll()
		var s := h.get_status()
		if s == HTTPClient.STATUS_CONNECTED and not sent:
			h.request(method, path, ["User-Agent: GodotCoopProbe"], body)
			sent = true
		elif s == HTTPClient.STATUS_BODY:
			out.append_array(h.read_response_body_chunk())
		elif sent and s == HTTPClient.STATUS_CONNECTED:
			break
		elif s in [HTTPClient.STATUS_DISCONNECTED, HTTPClient.STATUS_CANT_CONNECT, HTTPClient.STATUS_CANT_RESOLVE, HTTPClient.STATUS_CONNECTION_ERROR, HTTPClient.STATUS_TLS_HANDSHAKE_ERROR]:
			break
		OS.delay_msec(10)
	h.close()
	return out.get_string_from_utf8()


func post_ntfy(topic: String, text: String) -> String:
	return "ok" if _https(HTTPClient.METHOD_POST, "/" + topic, text).contains("\"id\"") else "failed"


func fetch_ntfy(topic: String) -> String:
	var res := _https(HTTPClient.METHOD_GET, "/%s/json?poll=1&since=10m" % topic)
	var code := ""
	for line in res.split("\n", false):
		var ev = JSON.parse_string(line)
		if ev is Dictionary and String(ev.get("message", "")).begins_with(Invite.PREFIX):
			code = String(ev.message)
	return code
