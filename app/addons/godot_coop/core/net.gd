@tool
extends RefCounted
## Transport layer over ENet (reliable UDP).
##
## Host:   `server` socket accepts direct connections (LAN / port-forwarded / UPnP / hole-punched).
##         A separate socket keeps a connection to the relay (if configured) and the server socket
##         regularly sends a tiny probe to the relay so the relay learns its *public* address.
## Joiner: one socket per candidate address (Godot's ENet allows one outgoing connection per
##         socket), one "punch" socket that probes the relay and then dials the host's public
##         address once the relay has introduced both sides, and one socket to the relay itself,
##         which can forward everything if no direct path works.
## Internet (no relay needed): host and joiner each prepare a fresh socket per connection (a
##         "slot"), learn its public address from STUN (and UPnP), swap addresses through the
##         rendezvous services, then both keep dialing each other's addresses. Each side's
##         outgoing packets open its own router for the other's, so one direction gets through.
## Upper layers only see "links" and never care which path a link takes.

const Util := preload("res://addons/godot_coop/core/util.gd")
const P2P := preload("res://addons/godot_coop/core/p2p.gd")

signal link_up(link: Dictionary)
signal link_down(link: Dictionary)
signal link_packet(link: Dictionary, channel: int, data: PackedByteArray)
signal relay_message(msg: Dictionary)
signal relay_state(state: String)
signal p2p_ready(sid: String, info: Dictionary)

const CH_CTRL := 0
const CH_LIVE := 1
const CH_FILES := 2
const CH_FAST := 3
const CH_TUNNEL := 4
const CHANNELS := 5

const RELAY_CTRL := 0x00
const RELAY_DATA := 0x01
const MAX_PACKET := 4 * 1024 * 1024
const PROBE_MAGIC := "GCP1"
const SLOT_WAIT_MS := 45000
const SLOT_DIAL_MS := 30000
const DIAL_DWELL_MS := 1200
const PUNCH := [0xFF, 0x47, 0x43]

var is_host := false
var local_port := 0
var links := {}                      # link id -> link

var server: ENetConnection = null    # host only
var relay_enet: ENetConnection = null
var relay_peer: ENetPacketPeer = null
var relay_connected := false
var relay_host := ""
var relay_port := 0
var relay_ip := ""
var relay_room := ""
var relay_key := ""
var _dials: Array = []               # joiner: [{"enet", "peer", "ip", "port"}]
var punch_enet: ENetConnection = null
var _punch_dialing := false
var _probe_token := ""
var _probe_until := 0
var _next_probe := 0
var _punches: Array = []             # host: [due_ms, ip, port]
var _relay_links := {}               # host: relay link number -> link id
var _peer_link := {}                 # ENetPacketPeer instance id -> link id
var _link_seq := 0
var _gen := 0                        # bumped by stop(); event loops bail out when it changes
var _dead: Array = []                # [socket, destroy_at_ms]: retired sockets get a moment to say goodbye
var _slots := {}                     # internet connection id -> slot (see p2p_open)
var _gone_gathers: Array = []        # closed slots still removing their router port mapping
var p2p_upnp = false                 # for new slots: a known UPNP router, null to look for one, false for none


func start_host(port: int) -> Error:
	is_host = true
	server = ENetConnection.new()
	var err := ERR_CANT_CREATE
	for p in range(port, port + 20):
		err = server.create_host_bound("*", p, 64, CHANNELS)
		if err == OK:
			local_port = p
			break
	return err


## Keeps pumping the sockets for a moment so final messages (session ended, kicked…) get out
## before we disconnect. Disconnecting immediately makes ENet drop data still in flight.
func drain(ms: int) -> void:
	for id in links:
		var l: Dictionary = links[id]
		if l.kind == "direct" and l.peer != null and l.peer.is_active():
			l.peer.peer_disconnect_later()
	var end := Util.now_ms() + ms
	while Util.now_ms() < end:
		for e in _all_enets():
			e.service(0)
		OS.delay_msec(5)


func start_client() -> Error:
	is_host = false
	return OK


func stop() -> void:
	_gen += 1
	for id in links.keys():
		var l: Dictionary = links[id]
		if l.kind == "direct" and l.peer != null and l.peer.is_active():
			l.peer.peer_disconnect_now()
	links.clear()
	_peer_link.clear()
	_relay_links.clear()
	if relay_peer != null and relay_peer.is_active():
		relay_peer.peer_disconnect_now()
	relay_peer = null
	relay_connected = false
	for e in _all_enets():
		e.flush()
		e.destroy()
	for d in _dead:
		d[0].flush()
		d[0].destroy()
	_dead.clear()
	server = null
	relay_enet = null
	punch_enet = null
	_dials.clear()
	for sid in _slots:
		_gone_gathers.append(_slots[sid].gather)
	_slots.clear()
	for g in _gone_gathers:
		g.cleanup(true)
	_gone_gathers.clear()


func _all_enets() -> Array:
	var out := []
	if server != null:
		out.append(server)
	if relay_enet != null:
		out.append(relay_enet)
	if punch_enet != null:
		out.append(punch_enet)
	for d in _dials:
		out.append(d.enet)
	for sid in _slots:
		if _slots[sid].enet != null:
			out.append(_slots[sid].enet)
	return out


func _new_link(kind: String, remote: String) -> Dictionary:
	_link_seq += 1
	var link := {"id": "%s%d" % [kind[0], _link_seq], "kind": kind, "remote": remote, "peer": null, "enet": null, "rlink": 0}
	links[link.id] = link
	return link


static func _tune(peer: ENetPacketPeer) -> void:
	peer.set_timeout(32, 4000, 12000)
	peer.ping_interval(500)


func _resolve(host: String) -> String:
	if Util.is_ipv4(host) or host.find(":") != -1:
		return host
	var ip := IP.resolve_hostname(host, IP.TYPE_IPV4)
	return ip


# --- joiner: dialing -----------------------------------------------------------------------------

func dial(ip: String, port: int) -> void:
	for d in _dials:
		if d.ip == ip and d.port == port:
			return
	var e := ENetConnection.new()
	if e.create_host_bound("*", 0, 2, CHANNELS) != OK:
		return
	var peer := e.connect_to_host(ip, port, CHANNELS)
	if peer == null:
		e.destroy()
		return
	_tune(peer)
	_dials.append({"enet": e, "peer": peer, "ip": ip, "port": port})


func dials_pending() -> bool:
	for d in _dials:
		if d.peer != null and d.peer.get_state() != ENetPacketPeer.STATE_CONNECTED:
			return true
	for sid in _slots:
		if _slots[sid].linked == 0:
			return true
	return _punch_dialing


## Joiner: keep only the socket that carries `link`, drop every other path.
func commit(link: Dictionary) -> void:
	var keep: ENetConnection = link.enet if link.kind == "direct" else relay_enet
	for d in _dials:
		if d.enet != keep:
			_retire(d.enet)
	_dials = _dials.filter(func(d): return d.enet == keep)
	if punch_enet != null and punch_enet != keep:
		_retire(punch_enet)
		punch_enet = null
	for sid in _slots.keys():
		var slot: Dictionary = _slots[sid]
		if slot.enet == null or slot.enet != keep:
			_close_slot(sid)
			continue
		slot.committed = link.peer
		for p in slot.enet.get_peers():
			if p != link.peer and p.is_active():
				p.peer_disconnect_now()
		slot.attempt = null
	_punch_dialing = false
	_probe_until = 0
	if link.kind == "direct" and relay_enet != null:
		if relay_peer != null:
			relay_peer.peer_disconnect_now()
		_retire(relay_enet)
		relay_enet = null
		relay_peer = null
		relay_connected = false
	for id in links.keys():
		if id != link.id:
			var other: Dictionary = links[id]
			links.erase(id)
			if other.kind == "direct" and other.peer != null:
				_peer_link.erase(other.peer.get_instance_id())


func _retire(e: ENetConnection) -> void:
	for p in e.get_peers():
		if p.is_active():
			p.peer_disconnect_later()
	_dead.append([e, Util.now_ms() + 400])


# --- relay ----------------------------------------------------------------------------------------

func connect_relay(host: String, port: int) -> bool:
	if host.is_empty() or port <= 0:
		return false
	relay_host = host
	relay_port = port
	relay_ip = _resolve(host)
	if relay_enet != null:
		_retire(relay_enet)
	relay_enet = ENetConnection.new()
	relay_connected = false
	if relay_enet.create_host_bound("*", 0, 2, CHANNELS) != OK:
		relay_enet = null
		relay_state.emit("failed")
		return false
	relay_peer = relay_enet.connect_to_host(host, port, CHANNELS)
	if relay_peer == null:
		_retire(relay_enet)
		relay_enet = null
		relay_state.emit("failed")
		return false
	_tune(relay_peer)
	return true


func disconnect_relay() -> void:
	if relay_peer != null:
		relay_peer.peer_disconnect_later()
	for id in links.keys():
		if links[id].kind == "relay":
			var l: Dictionary = links[id]
			links.erase(id)
			link_down.emit(l)
	_relay_links.clear()
	relay_peer = null
	relay_connected = false


func relay_send(msg: Dictionary) -> void:
	if relay_peer == null or not relay_connected:
		return
	var pkt := PackedByteArray([RELAY_CTRL])
	pkt.append_array(var_to_bytes(msg))
	relay_peer.send(CH_CTRL, pkt, ENetPacketPeer.FLAG_RELIABLE)


func relay_register(room: String, key: String) -> void:
	relay_send({"t": "register", "room": room, "key": key})


## Joiner: ask the relay for the room and start probing from the punch socket.
func relay_join(room: String) -> void:
	_probe_token = Util.random_hex(8)
	relay_send({"t": "join", "room": room, "probe": _probe_token})
	if punch_enet == null:
		punch_enet = ENetConnection.new()
		if punch_enet.create_host_bound("*", 0, 2, CHANNELS) != OK:
			punch_enet = null
			return
	_probe_until = Util.now_ms() + 5000
	_next_probe = 0


func _probe_packet(kind: int, text: String) -> PackedByteArray:
	var p := PROBE_MAGIC.to_ascii_buffer()
	p.append(kind)
	p.append_array(text.to_utf8_buffer())
	return p


## Host: open the NAT toward a joiner the relay told us about.
func punch(ip: String, port: int) -> void:
	if ip.is_empty() or port <= 0:
		return
	var now := Util.now_ms()
	for d in [0, 60, 150, 300, 600, 1000, 1600, 2500, 3500]:
		_punches.append([now + d, ip, port])


# --- internet connections ----------------------------------------------------------------------------

## Prepares a slot: a socket for one internet connection (on the host, one per joiner). Emits
## p2p_ready with our addresses once they're known, and again whenever one is added.
func p2p_open(sid: String) -> bool:
	if _slots.has(sid):
		var s: Dictionary = _slots[sid]
		if s.enet != null:
			p2p_ready.emit(sid, s.gather.info())
		return true
	var g := P2P.new()
	if not g.start(0, p2p_upnp):
		return false
	var now := Util.now_ms()
	_slots[sid] = {
		"sid": sid, "gather": g, "enet": null, "remote": [], "remote_nat": "", "remote_pub": [],
		"attempt": null, "dial_i": 0, "next_punch": 0, "punch_round": 0, "until": now + SLOT_WAIT_MS,
		"dial_until": 0, "linked": 0, "link_peers": {}, "had_link": false, "committed": null,
	}
	return true


## The other side's addresses (its p2p_ready info, delivered through the rendezvous).
func p2p_set_remote(sid: String, cands, nat, pub) -> void:
	if not _slots.has(sid) or not (cands is Array):
		return
	var s: Dictionary = _slots[sid]
	# Public IPv4 first (most likely to work from another network), then IPv6, then LAN ones.
	var tiers := [[], [], []]
	for c in cands:
		if c is Array and c.size() == 2 and int(c[1]) > 0 and int(c[1]) < 65536:
			var ip := Util.normalize_ip(String(c[0]))
			if Util.is_ipv4(ip) and not ip.begins_with("127."):
				tiers[2 if Util.is_private_ipv4(ip) else 0].append([ip, int(c[1])])
			elif ip.find(":") != -1 and ip != "::1":
				tiers[1].append([ip, int(c[1])])
	s.remote = (tiers[0] + tiers[1] + tiers[2]).slice(0, 12)
	s.dial_i = 0
	s.remote_nat = String(nat) if nat is String else ""
	s.remote_pub = pub if pub is Array and pub.size() == 2 and pub[1] is Array else []
	var now := Util.now_ms()
	s.dial_until = now + SLOT_DIAL_MS
	s.until = maxi(int(s.until), now + SLOT_DIAL_MS + 5000)
	s.punch_round = 0
	s.next_punch = 0


func p2p_count() -> int:
	return _slots.size()


func p2p_has(sid: String) -> bool:
	return _slots.has(sid)


func p2p_info(sid: String) -> Dictionary:
	return _slots[sid].gather.info() if _slots.has(sid) else {}


func _close_slot(sid: String) -> void:
	if not _slots.has(sid):
		return
	var s: Dictionary = _slots[sid]
	_slots.erase(sid)
	if s.enet != null:
		for p in s.enet.get_peers():
			var iid: int = p.get_instance_id()
			if _peer_link.has(iid):
				var id: String = _peer_link[iid]
				_peer_link.erase(iid)
				if links.has(id):
					var l: Dictionary = links[id]
					links.erase(id)
					link_down.emit(l)
		_retire(s.enet)
	s.gather.release()
	_gone_gathers.append(s.gather)


func _slot_of(e: ENetConnection):
	for sid in _slots:
		if _slots[sid].enet == e:
			return _slots[sid]
	return null


func _poll_slots(now: int) -> void:
	for sid in _slots.keys():
		if not _slots.has(sid):
			continue
		var s: Dictionary = _slots[sid]
		var g = s.gather
		g.poll()
		if s.enet == null:
			if not g.done:
				continue
			g.release()
			var e := ENetConnection.new()
			if e.create_host_bound("*", g.port, 32, CHANNELS) != OK:
				_close_slot(sid)
				continue
			s.enet = e
			g.changed = false
			p2p_ready.emit(sid, g.info())
			continue
		if g.changed:
			g.changed = false
			p2p_ready.emit(sid, g.info())
		if not _slots.has(sid):
			continue
		if s.linked == 0 and (now > int(s.until) or s.had_link):
			_close_slot(sid)
			continue
		if s.linked == 0 and not s.remote.is_empty() and now < int(s.dial_until):
			_drive_slot(s, now)
	if not _gone_gathers.is_empty():
		for g in _gone_gathers:
			g.cleanup()
		_gone_gathers = _gone_gathers.filter(func(g): return g.busy())


## Keeps both routers open toward each other and keeps offering a handshake on every address.
func _drive_slot(s: Dictionary, now: int) -> void:
	var e: ENetConnection = s.enet
	if now >= int(s.next_punch):
		for c in s.remote:
			e.socket_send(c[0], c[1], PackedByteArray(PUNCH))
		# A "strict" router picks a new public port for every destination, so the one it will use
		# toward us is unknown. Such routers usually count upward: open ours for the next few.
		if s.remote_nat == "strict" and s.punch_round < 6 and not s.remote_pub.is_empty():
			var top := 0
			for p in s.remote_pub[1]:
				top = maxi(top, int(p))
			if top > 0 and Util.is_ipv4(String(s.remote_pub[0])):
				for k in range(1, 49):
					if top + k < 65536:
						e.socket_send(String(s.remote_pub[0]), top + k, PackedByteArray(PUNCH))
		s.punch_round += 1
		s.next_punch = now + (150 if s.punch_round < 10 else 1000)
	# Godot's ENet only dials out from a socket that has no other peers, so the addresses are
	# tried one at a time, round and round. Connections from the other side are accepted anytime.
	var a = s.attempt
	if a != null and a.peer.is_active():
		if a.peer.get_state() != ENetPacketPeer.STATE_CONNECTING or now - int(a.t) < DIAL_DWELL_MS:
			return
		a.peer.reset()
		s.attempt = null
		return      # the socket drops it on its next service, then the next address gets a turn
	s.attempt = null
	for p in e.get_peers():
		if p.is_active():
			return  # the other side is connecting to us
	var c: Array = s.remote[int(s.dial_i) % s.remote.size()]
	s.dial_i += 1
	var peer := e.connect_to_host(c[0], c[1], CHANNELS)
	if peer != null:
		peer.set_timeout(32, 3000, 6000)
		s.attempt = {"peer": peer, "t": now}


# --- sending ---------------------------------------------------------------------------------------

func send(link: Dictionary, channel: int, data: PackedByteArray, reliable := true) -> void:
	var flags := ENetPacketPeer.FLAG_RELIABLE if reliable else ENetPacketPeer.FLAG_UNRELIABLE_FRAGMENT
	if link.kind == "direct":
		var peer: ENetPacketPeer = link.peer
		if peer != null and peer.get_state() == ENetPacketPeer.STATE_CONNECTED:
			peer.send(channel, data, flags)
	elif relay_peer != null and relay_connected:
		var pkt := PackedByteArray([RELAY_DATA])
		if is_host:
			var hdr := PackedByteArray()
			hdr.resize(4)
			hdr.encode_u32(0, int(link.rlink))
			pkt.append_array(hdr)
		pkt.append_array(data)
		relay_peer.send(channel, pkt, flags)


func flush() -> void:
	for e in _all_enets():
		e.flush()


func close_link(link: Dictionary) -> void:
	if not links.has(link.id):
		return
	links.erase(link.id)
	if link.kind == "direct":
		var peer: ENetPacketPeer = link.peer
		if peer != null:
			_peer_link.erase(peer.get_instance_id())
			peer.peer_disconnect_later()
	elif is_host:
		_relay_links.erase(int(link.rlink))
		relay_send({"t": "close", "link": int(link.rlink)})
	else:
		disconnect_relay()


func link_rtt(link: Dictionary) -> int:
	if link.kind == "direct" and link.peer != null:
		return int(link.peer.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME))
	if relay_peer != null:
		return int(relay_peer.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME)) * 2
	return -1


# --- event loop --------------------------------------------------------------------------------------

func poll() -> void:
	var now := Util.now_ms()
	if not _punches.is_empty() and server != null:
		var keep: Array = []
		for p in _punches:
			if p[0] <= now:
				server.socket_send(p[1], p[2], PackedByteArray([0xFF, 0x47, 0x43]))
			else:
				keep.append(p)
		_punches = keep
	if now >= _next_probe and not relay_ip.is_empty() and relay_connected:
		if is_host and server != null and not relay_room.is_empty():
			server.socket_send(relay_ip, relay_port + 1, _probe_packet(1, relay_room + ":" + relay_key))
			_next_probe = now + 3000
		elif not is_host and punch_enet != null and now < _probe_until and not _punch_dialing:
			punch_enet.socket_send(relay_ip, relay_port + 1, _probe_packet(2, _probe_token))
			_next_probe = now + 250
	_poll_slots(now)
	var gen := _gen
	if server != null:
		_service(server, "server")
	if relay_enet != null and gen == _gen:
		_service(relay_enet, "relay")
	if punch_enet != null and gen == _gen:
		_service(punch_enet, "punch")
	for d in _dials.duplicate():
		if gen != _gen:
			return
		_service(d.enet, "dial")
	for sid in _slots.keys():
		if gen != _gen:
			return
		if _slots.has(sid) and _slots[sid].enet != null:
			_service(_slots[sid].enet, "p2p")
	if gen != _gen:
		return
	if not _dead.is_empty():
		var alive: Array = []
		for d in _dead:
			d[0].service(0)
			if now >= int(d[1]):
				d[0].flush()
				d[0].destroy()
			else:
				alive.append(d)
		_dead = alive
	flush()


func _service(e: ENetConnection, role: String) -> void:
	var gen := _gen
	for i in 2000:
		if e == null or gen != _gen:
			return
		var ev: Array = e.service(0)
		var type: int = ev[0]
		if type == ENetConnection.EVENT_NONE:
			return
		var peer: ENetPacketPeer = ev[1]
		match type:
			ENetConnection.EVENT_CONNECT:
				_on_connect(e, peer, role)
			ENetConnection.EVENT_DISCONNECT:
				_on_disconnect(peer, role)
			ENetConnection.EVENT_RECEIVE:
				var pkt := peer.get_packet()
				_on_receive(peer, int(ev[3]), pkt, role)
			ENetConnection.EVENT_ERROR:
				return


func _remote_of(peer: ENetPacketPeer) -> String:
	return "%s:%d" % [Util.normalize_ip(peer.get_remote_address()), peer.get_remote_port()]


func _on_connect(e: ENetConnection, peer: ENetPacketPeer, role: String) -> void:
	if role == "relay":
		if peer == relay_peer:
			relay_connected = true
			_next_probe = 0
			relay_state.emit("connected")
		return
	var path := "lan"
	if role == "punch":
		_punch_dialing = false
		path = "internet"
	elif role == "p2p":
		var s = _slot_of(e)
		if s == null or (s.committed != null and s.committed != peer):
			peer.peer_disconnect_now()
			return
		s.link_peers[peer.get_instance_id()] = true
		s.linked = s.link_peers.size()
		s.had_link = true
		if s.attempt != null:
			var a: ENetPacketPeer = s.attempt.peer
			if a != peer and a.is_active() and a.get_state() != ENetPacketPeer.STATE_CONNECTED:
				a.reset()
			s.attempt = null
		path = "internet"
	_tune(peer)
	var link := _new_link("direct", _remote_of(peer))
	link.peer = peer
	link.enet = e
	link["path"] = path
	_peer_link[peer.get_instance_id()] = link.id
	link_up.emit(link)


func _on_disconnect(peer: ENetPacketPeer, role: String) -> void:
	if role == "relay":
		if peer != relay_peer:
			return
		relay_peer = null
		relay_connected = false
		for id in links.keys():
			if links[id].kind == "relay":
				var l: Dictionary = links[id]
				links.erase(id)
				link_down.emit(l)
		_relay_links.clear()
		relay_state.emit("lost")
		return
	if role == "punch":
		_punch_dialing = false
	var iid := peer.get_instance_id()
	if role == "p2p":
		for sid in _slots:
			var lp: Dictionary = _slots[sid].link_peers
			if lp.erase(iid):
				_slots[sid].linked = lp.size()
	if _peer_link.has(iid):
		var id: String = _peer_link[iid]
		_peer_link.erase(iid)
		if links.has(id):
			var l: Dictionary = links[id]
			links.erase(id)
			link_down.emit(l)


func _on_receive(peer: ENetPacketPeer, channel: int, pkt: PackedByteArray, role: String) -> void:
	if pkt.size() > MAX_PACKET:
		return
	if role == "relay":
		if peer == relay_peer:
			_on_relay_packet(channel, pkt)
		return
	var iid := peer.get_instance_id()
	if _peer_link.has(iid) and links.has(_peer_link[iid]):
		link_packet.emit(links[_peer_link[iid]], channel, pkt)


func _on_relay_packet(channel: int, pkt: PackedByteArray) -> void:
	if pkt.is_empty():
		return
	if pkt[0] == RELAY_CTRL:
		var msg = bytes_to_var(pkt.slice(1))
		if msg is Dictionary:
			_on_relay_ctrl(msg)
		return
	if pkt[0] != RELAY_DATA:
		return
	if is_host:
		if pkt.size() < 5:
			return
		var rl := pkt.decode_u32(1)
		if _relay_links.has(rl) and links.has(_relay_links[rl]):
			link_packet.emit(links[_relay_links[rl]], channel, pkt.slice(5))
	else:
		for id in links:
			if links[id].kind == "relay":
				link_packet.emit(links[id], channel, pkt.slice(1))
				return


func _on_relay_ctrl(msg: Dictionary) -> void:
	match String(msg.get("t", "")):
		"registered":
			relay_room = String(msg.get("room", ""))
			relay_key = String(msg.get("key", ""))
			_next_probe = 0
		"link_open":
			if is_host:
				var rl := int(msg.get("link", 0))
				var link := _new_link("relay", "relay")
				link.rlink = rl
				_relay_links[rl] = link.id
				link_up.emit(link)
		"link_close":
			if is_host:
				var rl := int(msg.get("link", 0))
				if _relay_links.has(rl):
					var id: String = _relay_links[rl]
					_relay_links.erase(rl)
					if links.has(id):
						var l: Dictionary = links[id]
						links.erase(id)
						link_down.emit(l)
		"punch":
			var ep = msg.get("ep", [])
			if ep is Array and ep.size() == 2:
				var ip := Util.normalize_ip(String(ep[0]))
				if is_host:
					punch(ip, int(ep[1]))
				elif punch_enet != null and not _punch_dialing and punch_enet.get_peers().is_empty():
					var peer := punch_enet.connect_to_host(ip, int(ep[1]), CHANNELS)
					if peer != null:
						_tune(peer)
						_punch_dialing = true
		"joined":
			if not is_host:
				var link := _new_link("relay", "relay")
				link_up.emit(link)
		"closed":
			if not is_host:
				disconnect_relay()
	relay_message.emit(msg)
