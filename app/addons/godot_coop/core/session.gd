@tool
extends RefCounted
## A collaboration session, either hosting or joined.
##
## Handles invites, connecting (direct / hole-punched / relayed), the encrypted handshake, host
## approval, roles, reconnects, chat, activity, presence fan-out and message routing. File sync
## (FileSync) and the live-document referee (HostDocs) plug into it. The editor plugin and the
## companion app only talk to this object: `send()` to reach the host and the `message` signal
## for everything coming back. On the host, the host's own editor is just peer 1.

const Util := preload("res://addons/godot_coop/core/util.gd")
const Net := preload("res://addons/godot_coop/core/net.gd")
const CryptoBox := preload("res://addons/godot_coop/core/crypto_box.gd")
const Invite := preload("res://addons/godot_coop/core/invite.gd")
const FileSync := preload("res://addons/godot_coop/core/file_sync.gd")
const HostDocs := preload("res://addons/godot_coop/core/host_docs.gd")
const Git := preload("res://addons/godot_coop/core/git.gd")

signal state_changed(state: String, detail: String)
signal message(msg: Dictionary)
signal join_request(req: Dictionary)
signal join_request_cancelled(req_id: String)
signal roster_changed()
signal invites_changed()
signal chat_received(entry: Dictionary)
signal activity_received(entry: Dictionary, replaced: bool)
signal welcomed(info: Dictionary)
signal log_line(text: String)

const CH_CTRL := Net.CH_CTRL
const CH_LIVE := Net.CH_LIVE
const CH_FILES := Net.CH_FILES
const CH_FAST := Net.CH_FAST
const CH_TUNNEL := Net.CH_TUNNEL

const CONNECT_TIMEOUT_MS := 15000
const RELAY_GRACE_MS := 1500
const TOKEN_TTL_S := 900.0
const MAX_CHAT := 200
const MAX_ACTIVITY := 300

var is_host := false
var mode := "editor"                 # "editor" (a Godot editor) or "download" (companion app)
var project_dir := ""
var profile := {}
var settings := {
	"port": Util.DEFAULT_PORT, "use_upnp": true, "relay_host": "", "relay_port": Util.DEFAULT_RELAY_PORT,
	"auto_accept_viewers": false, "auto_accept_all": false, "include_loopback": false,
	"game_port": 7777, "web_link_base": "",
}
var state := "idle"
var state_detail := ""
var my_pid := 0
var role := "editor"
var paths := PackedStringArray()
var roster := {}                     # pid -> {pid, name, color, role, paths, online, via, mode, email}
var presence := {}                   # pid -> last presence message
var host_info := {}
var chat_log: Array = []
var activity_log: Array = []
var net: Net = null
var files: FileSync = null
var docs: HostDocs = null
var connection_kind := ""            # "direct" / "relay" (joined side)
var version_override := {}           # tests only: pretend to be another Godot version

# host state
var _conns := {}                     # link id -> conn
var _peers := {}                     # pid -> record
var _invites := {}                   # iid hex -> {"iid", "secret", "role", "code", "short", "revoked"}
var _pending := {}                   # request id -> {"link_id", "join"}
var _next_pid := 2
var _candidates: Array = []
var _extra_public: Array = []        # [[ip, port]] public addresses learned from UPnP / the relay
var _upnp_thread: Thread = null
var _upnp: UPNP = null
var upnp_status := ""
var _relay_room := ""
var _relay_key := ""
var relay_status := ""
var _relay_retry_ms := 0
var _probe_seen := false
var _prep_started_ms := 0
var invites_ready := false
var _local_queue: Array = []
var _chat_hist: Array = []
var _act_hist: Array = []
var _act_seq := 0

# joined state
var _invite := {}
var _conn = null
var _attempt_ms := 0
var _token := ""
var _reconnect_at := 0
var _reconnect_tries := 0
var _relay_hello_due := {}
var _outbox: Array = []
var _last_error := ""
var _end_at := 0
var _end_reason := ""


func _log(s: String) -> void:
	log_line.emit(s)


func _set_state(s: String, detail := "") -> void:
	state = s
	state_detail = detail
	state_changed.emit(s, detail)


func is_online() -> bool:
	return state == "hosting" or state == "connected"


func peer_name(pid: int) -> String:
	if roster.has(pid):
		return String(roster[pid].name)
	return "Peer %d" % pid


func peer_color(pid: int) -> Color:
	if roster.has(pid):
		return Util.color_of(roster[pid])
	return Color.WHITE


func can_edit() -> bool:
	return role != "viewer"


# =================================================================================================
# Hosting

func host(p_project_dir: String, p_profile: Dictionary, p_settings := {}) -> Error:
	is_host = true
	mode = "editor"
	project_dir = p_project_dir
	profile = p_profile
	settings.merge(p_settings, true)
	Util.ensure_coop_dir(project_dir)
	net = Net.new()
	var err := net.start_host(int(settings.port))
	if err != OK:
		_set_state("failed", "Couldn't open UDP port %d (in use?)" % int(settings.port))
		return err
	_wire_net()
	my_pid = 1
	role = "owner"
	_peers[1] = {
		"pid": 1, "name": profile.get("name", "Host"), "color": profile.get("color", "ffffff"),
		"email": profile.get("email", ""), "uuid": profile.get("uuid", ""), "role": "owner",
		"paths": [], "online": true, "via": "local", "mode": "editor", "token": "", "contrib": 0,
		"conn_id": "", "last_seen": Util.unix_time(),
	}
	files = FileSync.new()
	files.setup(project_dir, true, 1)
	files.init_host_manifest()
	files.send_fn = func(dest: int, msg: Dictionary): _send_pid(dest, msg, CH_FILES)
	files.can_write_fn = _can_write
	files.peers_fn = _synced_peers
	files.file_applied.connect(_on_host_file_applied)
	files.file_received.connect(_on_host_file_received)
	files.local_change.connect(_on_host_local_change)
	docs = HostDocs.new()
	docs.project_dir = project_dir
	docs.send_fn = func(pid: int, msg: Dictionary): _send_pid(pid, msg, CH_LIVE)
	docs.can_write_fn = _can_write
	docs.activity_fn = _activity
	docs.uuid_fn = func(pid: int): return str(pid)   # author key for de-duplicating resent edits
	docs.name_fn = peer_name
	var git := Git.info(project_dir)
	var v := Util.engine_version()
	host_info = {
		"project": Util.project_name_from_dir(project_dir), "host_name": profile.get("name", "Host"),
		"godot": v, "git": git, "game_port": int(settings.game_port), "files": files.base.size(),
	}
	_refresh_roster()
	_create_invite("editor")
	_create_invite("viewer")
	_prep_started_ms = Util.now_ms()
	if settings.use_upnp:
		upnp_status = "Checking router (UPnP)…"
		_upnp_thread = Thread.new()
		_upnp_thread.start(_upnp_work.bind(net.local_port))
	else:
		upnp_status = "UPnP off"
	if not String(settings.relay_host).is_empty():
		relay_status = "Connecting to relay…"
		net.connect_relay(String(settings.relay_host), int(settings.relay_port))
	else:
		relay_status = "No relay configured"
	_set_state("hosting", "")
	_log("Hosting %s on UDP %d" % [host_info.project, net.local_port])
	return OK


func _upnp_work(port: int) -> Dictionary:
	var u := UPNP.new()
	var r := u.discover(2000, 2, "InternetGatewayDevice")
	if r != UPNP.UPNP_RESULT_SUCCESS:
		return {"ok": false, "why": "no UPnP router found"}
	var gw := u.get_gateway()
	if gw == null or not gw.is_valid_gateway():
		return {"ok": false, "why": "no UPnP gateway"}
	var ip := u.query_external_address()
	var m := u.add_port_mapping(port, port, "Godot Co-op", "UDP", 0)
	if m != UPNP.UPNP_RESULT_SUCCESS:
		return {"ok": false, "ip": ip, "why": "router refused port mapping"}
	return {"ok": true, "ip": ip, "upnp": u}


func _create_invite(r: String) -> void:
	var iid := Util.random_bytes(6)
	_invites[iid.hex_encode()] = {"iid": iid, "secret": Util.random_bytes(16), "role": r, "code": "", "short": "", "revoked": false}


## New codes for new joiners. People already in the session keep working (their reconnects use a token).
func regenerate_invites() -> void:
	for k in _invites:
		_invites[k].revoked = true
	_create_invite("editor")
	_create_invite("viewer")
	_build_invites()


func _maybe_build_invites() -> void:
	if invites_ready:
		return
	var upnp_done := _upnp_thread == null
	var relay_done := String(settings.relay_host).is_empty() or (not _relay_room.is_empty() and _probe_seen) or relay_status.begins_with("Relay unreachable")
	var waited := Util.now_ms() - _prep_started_ms > 6000
	if (upnp_done and relay_done) or waited:
		_build_invites()


func _build_invites() -> void:
	_candidates.clear()
	for ip in Util.reachable_ipv4s():
		_candidates.append([Invite.KIND_LAN, ip, net.local_port])
	if settings.include_loopback or _candidates.is_empty():
		_candidates.append([Invite.KIND_LAN, "127.0.0.1", net.local_port])
	for c in _extra_public:
		var dup := false
		for e in _candidates:
			if e[1] == c[0] and e[2] == c[1]:
				dup = true
		if not dup:
			_candidates.append([Invite.KIND_PUBLIC, c[0], c[1]])
	var rh := String(settings.relay_host) if not _relay_room.is_empty() else ""
	var rp := int(settings.relay_port) if not _relay_room.is_empty() else 0
	for k in _invites:
		var inv: Dictionary = _invites[k]
		if inv.revoked:
			continue
		inv.code = Invite.encode(Invite.make(inv.secret, inv.iid, inv.role, _candidates, rh, rp, _relay_room, String(host_info.get("project", ""))))
		inv.short = ""
		if not _relay_room.is_empty() and inv.role == "editor":
			net.relay_send({"t": "short_set", "invite": inv.code})
	invites_ready = true
	invites_changed.emit()


func get_invite(r := "editor") -> Dictionary:
	for k in _invites:
		var inv: Dictionary = _invites[k]
		if inv.role == r and not inv.revoked:
			return inv
	return {}


func connection_summary() -> String:
	var parts := PackedStringArray()
	for c in _candidates:
		parts.append(("LAN " if c[0] == Invite.KIND_LAN else "Internet ") + "%s:%d" % [c[1], c[2]])
	if not _relay_room.is_empty():
		parts.append("relay %s" % settings.relay_host)
	return ", ".join(parts)


func _synced_peers() -> Array:
	var out := []
	for pid in _peers:
		if pid != 1 and _peers[pid].online:
			out.append(pid)
	return out


func _can_write(pid: int, rel: String) -> bool:
	if not _peers.has(pid):
		return false
	var rec: Dictionary = _peers[pid]
	if rec.role == "owner":
		return true
	if rec.role == "viewer":
		return false
	var allowed: Array = rec.paths
	if allowed.is_empty():
		return true
	for p in allowed:
		var prefix := Util.res_to_rel(String(p)).trim_suffix("/")
		if prefix.is_empty() or rel == prefix or rel.begins_with(prefix + "/"):
			return true
	return false


func set_peer_role(pid: int, new_role: String, new_paths := []) -> void:
	if not is_host or not _peers.has(pid) or pid == 1:
		return
	if not new_role in ["editor", "viewer"]:
		return
	_peers[pid].role = new_role
	_peers[pid].paths = new_paths
	_send_pid(pid, {"t": "role", "role": new_role, "paths": new_paths}, CH_CTRL)
	_activity(1, "set %s as %s%s" % [_peers[pid].name, new_role, (" (" + ", ".join(PackedStringArray(new_paths)) + ")") if not new_paths.is_empty() else ""], {}, "")
	_refresh_roster()


func kick(pid: int, reason := "Removed by the host") -> void:
	if not is_host or not _peers.has(pid) or pid == 1:
		return
	var rec: Dictionary = _peers[pid]
	_send_pid(pid, {"t": "kicked", "reason": reason}, CH_CTRL)
	rec.token = ""
	_activity(1, "removed %s from the session" % rec.name, {}, "")
	var conn = _conns.get(rec.conn_id)
	if conn != null:
		net.flush()
		net.close_link(conn.link)
		_conns.erase(rec.conn_id)
	_peer_offline(pid)
	_peers.erase(pid)
	_refresh_roster()


func approve(req_id: String, new_role := "", new_paths := []) -> void:
	if not _pending.has(req_id):
		return
	var p: Dictionary = _pending[req_id]
	_pending.erase(req_id)
	var conn = _conns.get(p.link_id)
	if conn == null:
		return
	var j: Dictionary = p.join
	var r := new_role if not new_role.is_empty() else String(p.invite_role)
	var pid := _next_pid
	_next_pid += 1
	_peers[pid] = {
		"pid": pid, "name": Util.short_text(String(j.get("name", "Guest")), 32), "color": String(j.get("color", "ffffff")),
		"email": String(j.get("email", "")), "uuid": String(j.get("uuid", "")), "role": r, "paths": new_paths,
		"online": true, "via": conn.link.kind, "mode": String(j.get("mode", "editor")), "token": Util.random_hex(16),
		"contrib": 0, "conn_id": conn.link.id, "last_seen": Util.unix_time(), "godot": j.get("godot", {}),
	}
	conn.pid = pid
	conn.state = "peer"
	_send_welcome(pid, false)
	_refresh_roster()
	if _peers[pid].mode == "editor":
		_activity(pid, "joined the session", {}, "")
	else:
		_activity(pid, "is downloading the project", {}, "dl:%d" % pid)


func deny(req_id: String, reason := "The host declined your request.") -> void:
	if not _pending.has(req_id):
		return
	var p: Dictionary = _pending[req_id]
	_pending.erase(req_id)
	var conn = _conns.get(p.link_id)
	if conn != null:
		_seal(conn, {"t": "denied", "reason": reason})
		net.flush()
		net.close_link(conn.link)
		_conns.erase(p.link_id)


func pending_requests() -> Array:
	var out := []
	for k in _pending:
		out.append(_pending[k].req)
	return out


func _send_welcome(pid: int, resumed: bool) -> void:
	var rec: Dictionary = _peers[pid]
	_send_pid(pid, {
		"t": "welcome", "pid": pid, "token": rec.token, "role": rec.role, "paths": rec.paths,
		"resumed": resumed, "host": host_info, "roster": _roster_list(),
		"chat": _chat_hist.slice(-50), "activity": _act_hist.slice(-100), "presence": presence,
	}, CH_CTRL)


func _roster_list() -> Array:
	var out := []
	for pid in _peers:
		var r: Dictionary = _peers[pid]
		out.append({"pid": pid, "name": r.name, "color": r.color, "role": r.role, "paths": r.paths,
			"online": r.online, "via": r.via, "mode": r.mode, "email": r.email})
	return out


func _refresh_roster() -> void:
	var list := _roster_list()
	roster.clear()
	for r in list:
		roster[int(r.pid)] = r
	roster_changed.emit()
	for pid in _peers:
		if pid != 1 and _peers[pid].online:
			_send_pid(pid, {"t": "roster", "roster": list}, CH_CTRL)


func _peer_offline(pid: int) -> void:
	if not _peers.has(pid):
		return
	_peers[pid].online = false
	_peers[pid].offline_since = Util.unix_time()
	presence.erase(pid)
	files.drop_peer(pid)
	docs.peer_left(pid)
	_deliver({"t": "peer_left", "pid": pid})
	for other in _peers:
		if other != 1 and other != pid and _peers[other].online:
			_send_pid(other, {"t": "peer_left", "pid": pid}, CH_CTRL)


## Ends the session (host: for everyone; joiner: just leaves). By default this is non-blocking:
## goodbye messages get ~0.6 s to go out while poll() keeps running. Pass immediate=true when the
## process is about to exit (e.g. the editor is closing).
func end_session(reason := "The host ended the session.", immediate := false) -> void:
	if state == "ended" or state == "ending":
		return
	if is_host:
		for pid in _peers:
			if pid != 1 and _peers[pid].online:
				_send_pid(pid, {"t": "session_end", "reason": reason}, CH_CTRL)
	elif state == "connected":
		send({"t": "bye"})
	if net != null:
		net.flush()
	_end_reason = reason
	if immediate:
		if net != null:
			net.drain(250)
		_finish_end()
	else:
		_end_at = Util.now_ms() + 600
		_set_state("ending", reason)


func _finish_end() -> void:
	_end_at = 0
	if files != null:
		files.save_state(true)
	if _upnp_thread != null:
		_upnp_thread.wait_to_finish()
		_upnp_thread = null
	if _upnp != null and net != null:
		_upnp.delete_port_mapping(net.local_port, "UDP")
		_upnp = null
	if net != null:
		net.stop()
	_set_state("ended", _end_reason)


func contributors() -> Array:
	var out := []
	for pid in _peers:
		var r: Dictionary = _peers[pid]
		if pid != 1 and int(r.contrib) > 0:
			out.append({"name": r.name, "email": r.email if not String(r.email).is_empty() else "%s@users.noreply.godot-coop" % String(r.name).to_lower().replace(" ", ".")})
	return out


static func _noteworthy(rel: String) -> bool:
	return not (rel.ends_with(".import") or rel.ends_with(".uid"))


func _on_host_file_applied(rel: String, by: int, deleted: bool) -> void:
	if by != 1 and _peers.has(by) and _noteworthy(rel):
		_activity(by, ("deleted " if deleted else "updated ") + rel, {"type": "file", "path": Util.rel_to_res(rel)}, "file:" + rel)


func _on_host_file_received(rel: String, by: int, src: String, live: bool) -> void:
	if docs.texts.has(Util.rel_to_res(rel)):
		docs.on_file_changed(rel, by, live, FileAccess.get_file_as_string(src))


func _on_host_local_change(rel: String, deleted: bool) -> void:
	if not deleted:
		docs.on_file_changed(rel, 1, docs.is_watching(1, rel))
	if not _noteworthy(rel):
		return
	_activity(1, ("deleted " if deleted else "saved ") + rel, {"type": "file", "path": Util.rel_to_res(rel)}, "file:" + rel)


func _activity(pid: int, text: String, link := {}, key := "") -> void:
	if not is_host:
		return
	var now := Util.unix_time()
	var who := String(_peers[pid].name) if _peers.has(pid) else "Someone"
	var col := String(_peers[pid].color) if _peers.has(pid) else "ffffff"
	if pid != 1 and _peers.has(pid) and not text.begins_with("joined") and not text.begins_with("is downloading"):
		_peers[pid].contrib += 1
	if not key.is_empty() and not _act_hist.is_empty():
		var last: Dictionary = _act_hist[-1]
		if last.key == key and int(last.by) == pid and now - float(last.ts) < 4.0:
			last.text = text
			last.ts = now
			_broadcast({"t": "activity", "e": last, "replace": true}, CH_CTRL)
			return
	_act_seq += 1
	var e := {"id": _act_seq, "ts": now, "by": pid, "name": who, "color": col, "text": text, "link": link, "key": key}
	_act_hist.append(e)
	if _act_hist.size() > MAX_ACTIVITY:
		_act_hist.pop_front()
	_broadcast({"t": "activity", "e": e}, CH_CTRL)


# --- host: connections --------------------------------------------------------------------------

func _wire_net() -> void:
	net.link_up.connect(_on_link_up)
	net.link_down.connect(_on_link_down)
	net.link_packet.connect(_on_link_packet)
	net.relay_message.connect(_on_relay_message)
	net.relay_state.connect(_on_relay_state)


func _on_relay_state(s: String) -> void:
	match s:
		"connected":
			if is_host:
				relay_status = "Registering with relay…"
				net.relay_register(_relay_room, _relay_key)
			else:
				net.relay_join(String(_invite.get("room", "")))
		"failed", "lost":
			if is_host:
				relay_status = "Relay unreachable. Retrying."
				_relay_retry_ms = Util.now_ms() + 5000
				_maybe_build_invites()


func _on_relay_message(msg: Dictionary) -> void:
	match String(msg.get("t", "")):
		"registered":
			var was_empty := _relay_room.is_empty()
			_relay_room = String(msg.get("room", ""))
			_relay_key = String(msg.get("key", ""))
			relay_status = "Relay ready (%s)" % settings.relay_host
			if was_empty and invites_ready:
				_build_invites()
			_maybe_build_invites()
		"short":
			for k in _invites:
				if _invites[k].role == "editor" and not _invites[k].revoked:
					_invites[k].short = String(msg.get("code", ""))
			invites_changed.emit()
		"probe_seen":
			var ep = msg.get("ep", [])
			if ep is Array and ep.size() == 2:
				var ip := Util.normalize_ip(String(ep[0]))
				var pub := [ip, int(ep[1])]
				if Util.is_ipv4(ip) and not ip.begins_with("127.") and not _extra_public.has(pub):
					_extra_public.append(pub)
					if invites_ready:
						_build_invites()
			_probe_seen = true
			_maybe_build_invites()
		"error":
			_last_error = String(msg.get("reason", "Relay error"))
			_log("Relay: " + _last_error)


func _new_conn(link: Dictionary) -> Dictionary:
	return {"link": link, "box": CryptoBox.new(), "state": "new", "pid": 0, "nonce_c": PackedByteArray(), "iid": "", "secret": PackedByteArray()}


func _on_link_up(link: Dictionary) -> void:
	var conn := _new_conn(link)
	_conns[link.id] = conn
	if is_host:
		conn.state = "wait_hello"
	else:
		if link.kind == "relay" and net.dials_pending():
			_relay_hello_due[link.id] = Util.now_ms() + RELAY_GRACE_MS
		else:
			_client_send_hello(conn)


func _on_link_down(link: Dictionary) -> void:
	var conn = _conns.get(link.id)
	_conns.erase(link.id)
	_relay_hello_due.erase(link.id)
	if conn == null:
		return
	if is_host:
		for k in _pending.keys():
			if _pending[k].link_id == link.id:
				_pending.erase(k)
				join_request_cancelled.emit(k)
		if conn.pid != 0 and _peers.has(conn.pid) and _peers[conn.pid].conn_id == link.id:
			var rec: Dictionary = _peers[conn.pid]
			_peer_offline(conn.pid)
			if rec.mode == "editor":
				_activity(conn.pid, "disconnected", {}, "")
			_refresh_roster()
	elif conn == _conn:
		_conn = null
		if state == "connected" or state == "waiting_approval":
			_start_reconnect("Connection lost")


func _on_link_packet(link: Dictionary, ch: int, data: PackedByteArray) -> void:
	var conn = _conns.get(link.id)
	if conn == null:
		return
	if is_host:
		_host_packet(conn, ch, data)
	else:
		_client_packet(conn, ch, data)


func _seal(conn: Dictionary, msg: Dictionary, ch := CH_CTRL, reliable := true) -> void:
	net.send(conn.link, ch, conn.box.seal(ch, msg), reliable)


func _plain(conn: Dictionary, msg: Dictionary) -> void:
	net.send(conn.link, CH_CTRL, CryptoBox.encode_plain(msg), true)


func _drop(conn: Dictionary, reason := "") -> void:
	if not reason.is_empty():
		_plain(conn, {"t": "error", "reason": reason})
		net.flush()
	net.close_link(conn.link)
	_conns.erase(conn.link.id)


func _host_packet(conn: Dictionary, ch: int, data: PackedByteArray) -> void:
	if conn.state == "wait_hello":
		var m = CryptoBox.decode_plain(data)
		if m == null or str(m.get("t")) != "hello" or str(m.get("magic")) != "GDCOOP":
			_drop(conn)
			return
		if int(m.get("proto", 0)) != Util.PROTOCOL_VERSION:
			_drop(conn, "Godot Co-op versions don't match. Please update.")
			return
		var iid := String(m.get("iid", ""))
		var nonce_c = m.get("nonce")
		if not _invites.has(iid) or not (nonce_c is PackedByteArray) or nonce_c.size() != 16:
			_drop(conn, "This invite is no longer valid. Ask the host for a new one.")
			return
		var nonce_h := Util.random_bytes(16)
		conn.iid = iid
		conn.box.setup(_invites[iid].secret, nonce_c, nonce_h, true)
		conn.state = "wait_join"
		_plain(conn, {"t": "hello_ack", "nonce": nonce_h})
		return
	var m = conn.box.open(ch, data)
	if m == null:
		return
	match conn.state:
		"wait_join":
			if str(m.get("t")) == "join":
				_host_on_join(conn, m)
		"peer":
			if _peers.has(conn.pid):
				_peers[conn.pid].last_seen = Util.unix_time()
				_on_peer_msg(conn.pid, m, ch)


func _host_on_join(conn: Dictionary, j: Dictionary) -> void:
	var jmode := String(j.get("mode", "editor"))
	var token := String(j.get("token", ""))
	var inv: Dictionary = _invites[conn.iid]
	if jmode == "editor":
		var theirs = j.get("godot", {})
		if not (theirs is Dictionary) or not Util.versions_match(theirs, host_info.godot):
			_seal(conn, {"t": "denied", "code": "version", "reason": "Godot version mismatch: the host uses %s, you have %s." % [Util.version_label(host_info.godot), Util.version_label(theirs if theirs is Dictionary else {})], "need": host_info.godot})
			net.flush()
			net.close_link(conn.link)
			_conns.erase(conn.link.id)
			return
	# Rejoin with a token (reconnect, or the companion handing over to the editor): no approval.
	if not token.is_empty():
		for pid in _peers:
			var rec: Dictionary = _peers[pid]
			if pid != 1 and rec.token == token:
				_resume(pid, conn, j)
				return
	if inv.revoked:
		_drop(conn, "This invite was replaced by a newer one. Ask the host for the new code.")
		return
	var req := {
		"id": Util.random_hex(6), "name": Util.short_text(String(j.get("name", "Guest")), 32),
		"color": String(j.get("color", "ffffff")), "via": conn.link.kind, "mode": jmode,
		"role": inv.role, "godot": Util.version_label(j.get("godot", {}) if j.get("godot") is Dictionary else {}),
		"email": String(j.get("email", "")),
	}
	_pending[req.id] = {"link_id": conn.link.id, "join": j, "invite_role": inv.role, "req": req}
	conn.state = "pending"
	if settings.auto_accept_all or (inv.role == "viewer" and settings.auto_accept_viewers):
		approve(req.id)
		return
	_seal(conn, {"t": "pending"})
	join_request.emit(req)


func _resume(pid: int, conn: Dictionary, j: Dictionary) -> void:
	var rec: Dictionary = _peers[pid]
	if rec.online and rec.conn_id != conn.link.id and _conns.has(rec.conn_id):
		var old = _conns[rec.conn_id]
		_conns.erase(rec.conn_id)
		net.close_link(old.link)
		_peer_offline(pid)
	var was_mode := String(rec.mode)
	rec.online = true
	rec.conn_id = conn.link.id
	rec.via = conn.link.kind
	rec.mode = String(j.get("mode", rec.mode))
	rec.name = Util.short_text(String(j.get("name", rec.name)), 32)
	rec.color = String(j.get("color", rec.color))
	conn.pid = pid
	conn.state = "peer"
	_send_welcome(pid, true)
	_refresh_roster()
	if was_mode == "download" and rec.mode == "editor":
		_activity(pid, "joined the session", {}, "")
	elif rec.mode == "editor":
		_activity(pid, "reconnected", {}, "rc:%d" % pid)


func _send_pid(pid: int, msg: Dictionary, ch := CH_CTRL, reliable := true) -> void:
	if pid == my_pid:
		_local_queue.append(msg)
		return
	if not is_host:
		return
	if not _peers.has(pid) or not _peers[pid].online:
		return
	var conn = _conns.get(_peers[pid].conn_id)
	if conn != null and conn.state == "peer":
		_seal(conn, msg, ch, reliable)


func _broadcast(msg: Dictionary, ch := CH_CTRL, except := -1, reliable := true) -> void:
	for pid in _peers:
		if pid != except and _peers[pid].online:
			if pid != 1 and _peers[pid].mode != "editor" and ch != CH_CTRL:
				continue
			_send_pid(pid, msg, ch, reliable)


## Host: a message from peer `pid` (pid 1 = the host's own editor).
func _on_peer_msg(pid: int, m: Dictionary, ch: int) -> void:
	if not _peers.has(pid):
		return
	if ch == CH_FILES:
		files.handle(pid, m)
		return
	if ch == CH_LIVE:
		docs.handle(pid, m)
		return
	var t := String(m.get("t", ""))
	var rec: Dictionary = _peers[pid]
	if ch == CH_TUNNEL:
		if t != "tun":
			return
		if pid == 1:
			var to := int(m.get("to", 0))
			if to != 1:
				_send_pid(to, {"t": "tun", "d": m.get("d")}, CH_TUNNEL, false)
		else:
			_local_queue.append({"t": "tun", "from": pid, "d": m.get("d")})
		return
	match t:
		"presence":
			var out := m.duplicate()
			out["pid"] = pid
			presence[pid] = out
			_broadcast(out, CH_CTRL, pid)
		"presence_fast":
			var out := m.duplicate()
			out["pid"] = pid
			if presence.has(pid):
				presence[pid].merge(out, true)
			_broadcast(out, CH_FAST, pid, false)
		"chat":
			var text := String(m.get("text", "")).strip_edges()
			if text.is_empty():
				return
			var e := {"by": pid, "name": rec.name, "color": rec.color, "text": text.substr(0, 2000), "ts": Util.unix_time()}
			_chat_hist.append(e)
			if _chat_hist.size() > MAX_CHAT:
				_chat_hist.pop_front()
			_broadcast({"t": "chat", "e": e}, CH_CTRL)
		"ping":
			var out := m.duplicate()
			out["by"] = pid
			_broadcast(out, CH_CTRL, pid)
		"playtest":
			if rec.role == "viewer":
				return
			var out := {"t": "playtest", "action": String(m.get("action", "start")), "scene": String(m.get("scene", "")), "by": pid, "game_port": int(settings.game_port), "net": bool(m.get("net", true))}
			_broadcast(out, CH_CTRL)
			_activity(pid, "started a playtest for everyone" if out.action == "start" else "stopped the playtest", {}, "")
		"proj_set":
			if rec.role == "viewer":
				return
			var out := m.duplicate()
			out["by"] = pid
			_broadcast(out, CH_CTRL, pid)
			_activity(pid, "changed project settings", {}, "proj")
		"proj_get":
			_local_queue.append({"t": "proj_get", "from": pid})
		"bye":
			if pid != 1:
				var conn = _conns.get(rec.conn_id)
				if conn != null:
					net.close_link(conn.link)
					_conns.erase(rec.conn_id)
				_peer_offline(pid)
				if rec.mode == "editor":
					_activity(pid, "left the session", {}, "")
				_refresh_roster()
		_:
			# Host-local helpers can address a specific peer directly.
			if pid == 1 and m.has("to"):
				var to := int(m.to)
				var out := m.duplicate()
				out.erase("to")
				_send_pid(to, out, ch)


# =================================================================================================
# Joining

func join(invite_text: String, p_profile: Dictionary, p_mode := "editor", p_project_dir := "", token := "") -> Error:
	is_host = false
	mode = p_mode
	profile = p_profile
	project_dir = p_project_dir
	_token = token
	_invite = Invite.decode(invite_text)
	if _invite.is_empty():
		_set_state("failed", "That doesn't look like a valid invite code.")
		return ERR_INVALID_DATA
	if not project_dir.is_empty():
		Util.ensure_coop_dir(project_dir)
		files = FileSync.new()
		files.setup(project_dir, false, 0)
		files.load_state()
		files.send_fn = func(_dest: int, msg: Dictionary): send(msg, CH_FILES)
		files.manage_project_godot = mode == "download"
	return _attempt()


func _attempt() -> Error:
	if net != null:
		net.stop()
	net = Net.new()
	if net.start_client() != OK:
		_set_state("failed", "Couldn't open a network socket.")
		return ERR_CANT_CREATE
	_wire_net()
	_conn = null
	_conns.clear()
	_relay_hello_due.clear()
	_last_error = ""
	_attempt_ms = Util.now_ms()
	for c in _invite.cands:
		net.dial(String(c[1]), int(c[2]))
	if not String(_invite.relay_host).is_empty() and not String(_invite.room).is_empty():
		net.connect_relay(String(_invite.relay_host), int(_invite.relay_port))
	_set_state("reconnecting" if _reconnect_tries > 0 else "connecting", "Reaching %s…" % _invite.get("project", "the host"))
	return OK


func _client_send_hello(conn: Dictionary) -> void:
	conn.nonce_c = Util.random_bytes(16)
	conn.state = "hello"
	_plain(conn, {"t": "hello", "magic": "GDCOOP", "proto": Util.PROTOCOL_VERSION, "nonce": conn.nonce_c, "iid": PackedByteArray(_invite.iid).hex_encode()})


func _client_packet(conn: Dictionary, ch: int, data: PackedByteArray) -> void:
	if conn.state == "hello":
		var m = CryptoBox.decode_plain(data)
		if m == null:
			return
		if str(m.get("t")) == "error":
			_last_error = String(m.get("reason", "Refused"))
			net.close_link(conn.link)
			_conns.erase(conn.link.id)
			if _conn == null:
				net.stop()
				_set_state("failed", _last_error)
			return
		if str(m.get("t")) != "hello_ack" or not (m.get("nonce") is PackedByteArray) or m.nonce.size() != 16:
			return
		if _conn != null:
			net.close_link(conn.link)
			_conns.erase(conn.link.id)
			return
		conn.box.setup(_invite.secret, conn.nonce_c, m.nonce, false)
		conn.state = "secure"
		_conn = conn
		connection_kind = conn.link.kind
		# Commit to this path and stop the others.
		for id in _conns.keys():
			if id != conn.link.id:
				_conns.erase(id)
		net.commit(conn.link)
		_seal(conn, {
			"t": "join", "name": profile.get("name", "Guest"), "color": profile.get("color", "ffffff"),
			"email": profile.get("email", ""), "uuid": profile.get("uuid", ""), "mode": mode,
			"godot": version_override if not version_override.is_empty() else Util.engine_version(), "token": _token,
		})
		return
	if conn != _conn:
		return
	var m = conn.box.open(ch, data)
	if m == null:
		return
	_client_msg(m, ch)


func _client_msg(m: Dictionary, ch: int) -> void:
	if ch == CH_FILES:
		if files != null:
			files.handle(1, m)
		return
	match String(m.get("t", "")):
		"pending":
			_set_state("waiting_approval", "Waiting for the host to let you in…")
		"denied":
			_reconnect_tries = 0
			var why := String(m.get("reason", "Denied"))
			_deliver({"t": "denied", "reason": why, "code": m.get("code", ""), "need": m.get("need", {})})
			net.stop()
			_set_state("failed", why)
		"welcome":
			my_pid = int(m.pid)
			_token = String(m.token)
			role = String(m.role)
			paths = PackedStringArray(m.get("paths", []))
			host_info = m.get("host", {})
			presence = m.get("presence", {})
			roster.clear()
			for r in m.get("roster", []):
				roster[int(r.pid)] = r
			chat_log = m.get("chat", [])
			activity_log = m.get("activity", [])
			_reconnect_tries = 0
			if files != null:
				files.my_id = my_pid
			_set_state("connected", "")
			roster_changed.emit()
			welcomed.emit(m)
			if mode == "editor" and files != null:
				files.begin_sync()
			for o in _outbox:
				send(o[0], o[1])
			_outbox.clear()
		"roster":
			roster.clear()
			for r in m.get("roster", []):
				roster[int(r.pid)] = r
			roster_changed.emit()
		"role":
			role = String(m.get("role", role))
			paths = PackedStringArray(m.get("paths", []))
			roster_changed.emit()
			_deliver(m)
		"kicked":
			_reconnect_tries = 0
			net.stop()
			_set_state("ended", String(m.get("reason", "Removed by the host")))
		"session_end":
			_reconnect_tries = 0
			net.stop()
			_set_state("ended", String(m.get("reason", "The host ended the session.")))
		_:
			_deliver(m)


func _start_reconnect(why: String) -> void:
	if files != null:
		files.drop_peer(1)
	_reconnect_tries += 1
	var delay := mini(1000 * int(pow(2, mini(_reconnect_tries - 1, 4))), 15000)
	_reconnect_at = Util.now_ms() + delay
	if net != null:
		net.stop()
	_set_state("reconnecting", "%s. Retrying in %ds." % [why, delay / 1000])
	_deliver({"t": "disconnected"})


## Leave (joined side) without ending the session for others.
func leave() -> void:
	end_session("You left the session.")


# =================================================================================================
# Shared API

## Send to the host (on the host itself, this is processed as coming from peer 1).
func send(msg: Dictionary, ch := CH_CTRL, reliable := true) -> void:
	if is_host:
		if state == "hosting":
			_on_peer_msg(1, msg, ch)
		return
	if state == "connected" and _conn != null:
		_seal(_conn, msg, ch, reliable)
	elif str(msg.get("t")) == "chat":
		_outbox.append([msg, ch])


func _deliver(m: Dictionary) -> void:
	match String(m.get("t", "")):
		"chat":
			var e: Dictionary = m.get("e", {})
			chat_log.append(e)
			if chat_log.size() > MAX_CHAT:
				chat_log.pop_front()
			chat_received.emit(e)
		"activity":
			var e: Dictionary = m.get("e", {})
			var replaced := bool(m.get("replace", false))
			if replaced and not activity_log.is_empty() and int(activity_log[-1].get("id", -1)) == int(e.get("id", -2)):
				activity_log[-1] = e
			else:
				replaced = false
				activity_log.append(e)
				if activity_log.size() > MAX_ACTIVITY:
					activity_log.pop_front()
			activity_received.emit(e, replaced)
		"presence", "presence_fast":
			var pid := int(m.get("pid", 0))
			if not presence.has(pid) or m.t == "presence":
				presence[pid] = m.duplicate()
			else:
				presence[pid].merge(m, true)
			message.emit(m)
		"peer_left":
			presence.erase(int(m.get("pid", 0)))
			message.emit(m)
		_:
			message.emit(m)


func poll() -> void:
	if net == null:
		return
	if _end_at > 0:
		net.poll()
		if Util.now_ms() >= _end_at:
			_finish_end()
		return
	net.poll()
	if is_host:
		_poll_host()
	else:
		_poll_client()
	if files != null and is_online():
		files.poll()
	# Local deliveries are flushed last, outside of any signal handler that queued them.
	var guard := 0
	while not _local_queue.is_empty() and guard < 2000:
		guard += 1
		_deliver(_local_queue.pop_front())


func _poll_host() -> void:
	if _upnp_thread != null and not _upnp_thread.is_alive():
		var r: Dictionary = _upnp_thread.wait_to_finish()
		_upnp_thread = null
		if r.get("ok", false):
			_upnp = r.upnp
			upnp_status = "Port %d opened on router (%s)" % [net.local_port, r.ip]
			var pub := [String(r.ip), net.local_port]
			if Util.is_ipv4(String(r.ip)) and not _extra_public.has(pub):
				_extra_public.append(pub)
			if invites_ready:
				_build_invites()
		else:
			upnp_status = "UPnP: " + String(r.get("why", "unavailable"))
	if not invites_ready:
		_maybe_build_invites()
	docs.prune()
	if _relay_retry_ms > 0 and Util.now_ms() > _relay_retry_ms:
		_relay_retry_ms = 0
		if net.relay_peer == null:
			net.connect_relay(String(settings.relay_host), int(settings.relay_port))
	# Forget peers whose reconnect window has passed.
	var now := Util.unix_time()
	for pid in _peers.keys():
		var r: Dictionary = _peers[pid]
		if pid != 1 and not r.online and now - float(r.get("offline_since", now)) > TOKEN_TTL_S:
			_peers.erase(pid)
			_refresh_roster()


func _poll_client() -> void:
	var now := Util.now_ms()
	for id in _relay_hello_due.keys():
		if now >= int(_relay_hello_due[id]) or not net.dials_pending():
			_relay_hello_due.erase(id)
			if _conns.has(id) and _conn == null:
				_client_send_hello(_conns[id])
	if (state == "connecting" or state == "reconnecting") and _conn == null:
		if _reconnect_at > 0:
			if now >= _reconnect_at:
				_reconnect_at = 0
				_attempt()
		elif now - _attempt_ms > CONNECT_TIMEOUT_MS:
			if _reconnect_tries > 0 and _reconnect_tries < 40:
				_start_reconnect("Host unreachable")
			else:
				var why := _last_error if not _last_error.is_empty() else "Couldn't reach the host. Check the code, or ask the host to enable a relay / UPnP."
				net.stop()
				_set_state("failed", why)
