@tool
extends RefCounted
## Relay + rendezvous server. Run it anywhere with a public UDP port:
##     GodotCoop.exe --headless -- --relay --port 47600
##
## * Hosts register a room; joiners ask for a room by id (from the invite).
## * The relay tells each side the other's public address (as seen by the relay) so they can
##   hole-punch a direct connection.
## * If that fails, it forwards packets between them. Everything it forwards is end-to-end
##   encrypted with keys it never sees.
## * It can also hand out short "ABCD-EFGH" codes that map to a full invite for 24 hours.

const Util := preload("res://addons/godot_coop/core/util.gd")
const Invite := preload("res://addons/godot_coop/core/invite.gd")

const CHANNELS := 5
const MAX_FORWARD := 4 * 1024 * 1024
const ORPHAN_SECONDS := 120.0
const SHORT_TTL := 86400.0

var enet: ENetConnection = null
var probe := PacketPeerUDP.new()       # raw UDP on port+1: learns public addresses for hole punching
var port := 0
var rooms := {}        # room -> {"host": peer|null, "key", "links": {n: peer}, "ep": [ip, port], "orphan": t}
var peers := {}        # peer iid -> {"peer", "kind", "room", "link"}
var shorts := {}       # code -> {"invite", "room", "expires"}
var stats := {"forwarded_bytes": 0, "rooms": 0}
var log_fn: Callable
var _next_link := 1
var _last_gc := 0.0


func _log(s: String) -> void:
	if log_fn.is_valid():
		log_fn.call(s)


func start(p_port: int, bind := "*") -> Error:
	enet = ENetConnection.new()
	var err := enet.create_host_bound(bind, p_port, 4000, CHANNELS)
	if err == OK:
		port = p_port
		if probe.bind(p_port + 1, bind) != OK:
			_log("Warning: couldn't open probe port %d - hole punching disabled" % (p_port + 1))
		_log("Relay listening on UDP %d (+%d for hole punching)" % [p_port, p_port + 1])
	return err


func stop() -> void:
	if enet != null:
		enet.destroy()
		enet = null
	probe.close()


func _ep(peer: ENetPacketPeer) -> Array:
	return [Util.normalize_ip(peer.get_remote_address()), peer.get_remote_port()]


func _ctrl(peer: ENetPacketPeer, msg: Dictionary) -> void:
	if peer == null or not peer.is_active() or peer.get_state() != ENetPacketPeer.STATE_CONNECTED:
		return
	var pkt := PackedByteArray([0x00])
	pkt.append_array(var_to_bytes(msg))
	peer.send(0, pkt, ENetPacketPeer.FLAG_RELIABLE)


func poll() -> void:
	if enet == null:
		return
	for i in 5000:
		var ev: Array = enet.service(0)
		if ev[0] == ENetConnection.EVENT_NONE:
			break
		var peer: ENetPacketPeer = ev[1]
		match int(ev[0]):
			ENetConnection.EVENT_CONNECT:
				peer.set_timeout(32, 5000, 15000)
				peers[peer.get_instance_id()] = {"peer": peer, "kind": "", "room": "", "link": 0}
			ENetConnection.EVENT_DISCONNECT:
				_on_gone(peer)
			ENetConnection.EVENT_RECEIVE:
				var flags := peer.get_packet_flags()
				var pkt := peer.get_packet()
				_on_packet(peer, int(ev[3]), pkt, flags)
	_poll_probes()
	var now := Util.unix_time()
	if now - _last_gc > 10.0:
		_last_gc = now
		_gc(now)
	enet.flush()


func _poll_probes() -> void:
	var n := 0
	while probe.get_available_packet_count() > 0 and n < 500:
		n += 1
		var pkt := probe.get_packet()
		var ep := [Util.normalize_ip(probe.get_packet_ip()), probe.get_packet_port()]
		if pkt.size() < 6 or pkt.size() > 200 or pkt.slice(0, 4).get_string_from_ascii() != "GCP1":
			continue
		var kind := pkt[4]
		var text := pkt.slice(5).get_string_from_utf8()
		if kind == 1:
			var room_id := text.get_slice(":", 0)
			var key := text.get_slice(":", 1)
			if rooms.has(room_id) and String(rooms[room_id].key) == key and rooms[room_id].host != null:
				var room: Dictionary = rooms[room_id]
				if room.get("punch_ep", []) != ep:
					room["punch_ep"] = ep
					_ctrl(room.host, {"t": "probe_seen", "ep": ep})
		elif kind == 2:
			for iid in peers:
				var info: Dictionary = peers[iid]
				if info.kind == "joiner" and String(info.get("probe", "")) == text:
					if info.get("punch_ep", []) != ep:
						info["punch_ep"] = ep
						_introduce(info)
					break


## Tell host and joiner each other's public addresses so both can punch through their NATs.
func _introduce(info: Dictionary) -> void:
	if not rooms.has(info.room):
		return
	var room: Dictionary = rooms[info.room]
	var host_ep = room.get("punch_ep", [])
	var join_ep = info.get("punch_ep", [])
	if room.host == null or host_ep.is_empty() or join_ep.is_empty():
		return
	_ctrl(room.host, {"t": "punch", "link": int(info.link), "ep": join_ep})
	_ctrl(info.peer, {"t": "punch", "ep": host_ep})


func _gc(now: float) -> void:
	for r in rooms.keys():
		var room: Dictionary = rooms[r]
		if room.host == null and now - float(room.orphan) > ORPHAN_SECONDS:
			for n in room.links:
				var jp: ENetPacketPeer = room.links[n]
				_ctrl(jp, {"t": "closed"})
				jp.peer_disconnect_later()
			rooms.erase(r)
	for c in shorts.keys():
		if float(shorts[c].expires) < now or not rooms.has(String(shorts[c].room)):
			shorts.erase(c)
	stats.rooms = rooms.size()


func _on_gone(peer: ENetPacketPeer) -> void:
	var iid := peer.get_instance_id()
	if not peers.has(iid):
		return
	var info: Dictionary = peers[iid]
	peers.erase(iid)
	if not rooms.has(info.room):
		return
	var room: Dictionary = rooms[info.room]
	if info.kind == "host" and room.host == peer:
		room.host = null
		room.orphan = Util.unix_time()
		_log("Host of room %s disconnected" % info.room)
	elif info.kind == "joiner":
		room.links.erase(int(info.link))
		if room.host != null:
			_ctrl(room.host, {"t": "link_close", "link": int(info.link)})


func _on_packet(peer: ENetPacketPeer, channel: int, pkt: PackedByteArray, flags: int) -> void:
	if pkt.is_empty():
		return
	var iid := peer.get_instance_id()
	if not peers.has(iid):
		return
	var info: Dictionary = peers[iid]
	if pkt[0] == 0x00:
		if pkt.size() > 64 * 1024:
			return
		var msg = bytes_to_var(pkt.slice(1))
		if msg is Dictionary:
			_on_ctrl(peer, info, msg)
		return
	if pkt[0] != 0x01 or pkt.size() > MAX_FORWARD or not rooms.has(info.room):
		return
	var room: Dictionary = rooms[info.room]
	if info.kind == "host":
		if pkt.size() < 5:
			return
		var n := pkt.decode_u32(1)
		if room.links.has(n):
			var out := PackedByteArray([0x01])
			out.append_array(pkt.slice(5))
			room.links[n].send(channel, out, flags)
			stats.forwarded_bytes += out.size()
	elif info.kind == "joiner" and room.host != null:
		var out := PackedByteArray([0x01])
		var hdr := PackedByteArray()
		hdr.resize(4)
		hdr.encode_u32(0, int(info.link))
		out.append_array(hdr)
		out.append_array(pkt.slice(1))
		room.host.send(channel, out, flags)
		stats.forwarded_bytes += out.size()


func _on_ctrl(peer: ENetPacketPeer, info: Dictionary, msg: Dictionary) -> void:
	match String(msg.get("t", "")):
		"register":
			var want := String(msg.get("room", ""))
			var key := String(msg.get("key", ""))
			var room_id := ""
			if rooms.has(want) and String(rooms[want].key) == key and not key.is_empty() and rooms[want].host == null:
				room_id = want
			else:
				room_id = Util.random_hex(5)
				while rooms.has(room_id):
					room_id = Util.random_hex(5)
				key = Util.random_hex(12)
				rooms[room_id] = {"host": null, "key": key, "links": {}, "ep": [], "orphan": 0.0}
			var room: Dictionary = rooms[room_id]
			room.host = peer
			room.ep = _ep(peer)
			info.kind = "host"
			info.room = room_id
			_ctrl(peer, {"t": "registered", "room": room_id, "key": key, "ep": room.ep})
			_log("Room %s registered by %s" % [room_id, "%s:%d" % room.ep])
		"join":
			var room_id := String(msg.get("room", ""))
			if not rooms.has(room_id) or rooms[room_id].host == null:
				_ctrl(peer, {"t": "error", "reason": "That session isn't running on the relay (host offline?)."})
				return
			var room: Dictionary = rooms[room_id]
			var n := _next_link
			_next_link += 1
			info.kind = "joiner"
			info.room = room_id
			info.link = n
			info["probe"] = String(msg.get("probe", ""))
			room.links[n] = peer
			_ctrl(peer, {"t": "joined", "link": n})
			_ctrl(room.host, {"t": "link_open", "link": n})
			_introduce(info)
		"close":
			if info.kind == "host" and rooms.has(info.room):
				var room: Dictionary = rooms[info.room]
				var n := int(msg.get("link", 0))
				if room.links.has(n):
					var jp: ENetPacketPeer = room.links[n]
					room.links.erase(n)
					_ctrl(jp, {"t": "closed"})
					jp.peer_disconnect_later()
		"short_set":
			if info.kind == "host":
				var inv := String(msg.get("invite", ""))
				if inv.length() > 600 or not inv.begins_with(Invite.PREFIX):
					return
				for c in shorts.keys():
					if shorts[c].room == info.room:
						shorts.erase(c)
				var code := Invite.random_short_code()
				while shorts.has(code):
					code = Invite.random_short_code()
				shorts[code] = {"invite": inv, "room": info.room, "expires": Util.unix_time() + SHORT_TTL}
				_ctrl(peer, {"t": "short", "code": code})
		"short_get":
			var code := Invite.normalize_short_code(String(msg.get("code", "")))
			if shorts.has(code):
				_ctrl(peer, {"t": "short_res", "invite": shorts[code].invite})
			else:
				_ctrl(peer, {"t": "error", "reason": "Unknown or expired code."})
		"ping":
			_ctrl(peer, {"t": "pong"})
