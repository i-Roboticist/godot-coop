@tool
extends RefCounted
## Gathers the addresses where someone on another network might reach one UDP port of ours:
## local addresses (LAN, VPN, IPv6), the public address our router maps the port to (asked from
## public STUN servers) and, when the router allows it, a UPnP port mapping.
##
## Once `done`, call `release()` and bind the real (ENet) socket to `port`. The router keys its
## mapping on our local address and port, so the public address stays valid for the new socket.

const Util := preload("res://addons/godot_coop/core/util.gd")
const Stun := preload("res://addons/godot_coop/core/stun.gd")

const STUN_WAIT_MS := 1600
const RESEND_MS := [0, 400, 900]

var udp := PacketPeerUDP.new()
var port := 0
var cands: Array = []           # [ip, port], most likely to work first
var public_ip := ""
var public_ports: Array = []    # the public port each STUN server saw
var nat := "unknown"            # "easy": same public port for everyone; "strict": a new one per destination; "blocked": no answers
var done := false
var changed := false            # a candidate was added since the owner last looked
var upnp_ip := ""
var _servers: Array = []
var _started := 0
var _upnp_thread: Thread = null
var _upnp: UPNP = null
var _cleanup: Thread = null


## `upnp` is a router already discovered (the host's), null to look for one, or false to skip UPnP.
func start(want_port := 0, upnp = null) -> bool:
	if udp.bind(want_port, "*") != OK:
		return false
	port = udp.get_local_port()
	_started = Util.now_ms()
	for ip in local_addresses():
		cands.append([ip, port])
	for s in Stun.SERVERS:
		_servers.append({"host": s[0], "port": s[1], "rid": IP.resolve_hostname_queue_item(s[0], IP.TYPE_IPV4), "ip": "", "tid": PackedByteArray(), "sent": 0, "got": []})
	if not (upnp is bool):
		_upnp_thread = Thread.new()
		_upnp_thread.start(_map_port.bind(port, upnp))
	return true


## LAN and VPN IPv4 addresses, then global IPv6 ones.
static func local_addresses() -> Array:
	var out := Array(Util.reachable_ipv4s())
	var v6 := 0
	for a in IP.get_local_addresses():
		var l := String(a).to_lower()
		if l.find(":") == -1 or l.find("%") != -1 or not (l.begins_with("2") or l.begins_with("3")):
			continue
		out.append(l)
		v6 += 1
		if v6 >= 2:
			break
	return out


func poll() -> void:
	var now := Util.now_ms()
	if _upnp_thread != null and not _upnp_thread.is_alive():
		var r: Dictionary = _upnp_thread.wait_to_finish()
		_upnp_thread = null
		if r.get("ok", false):
			_upnp = r.upnp
			upnp_ip = String(r.ip)
			_add([upnp_ip, port], true)
	if done:
		return
	var answers := 0
	for s in _servers:
		if s.ip.is_empty() and s.rid >= 0:
			var st := IP.get_resolve_item_status(s.rid)
			if st == IP.RESOLVER_STATUS_DONE:
				s.ip = IP.get_resolve_item_address(s.rid)
			if st != IP.RESOLVER_STATUS_WAITING:
				IP.erase_resolve_item(s.rid)
				s.rid = -1
		if not s.ip.is_empty() and s.got.is_empty() and s.sent < RESEND_MS.size() and now - _started >= RESEND_MS[s.sent]:
			if s.tid.is_empty():
				var req := Stun.request()
				s.tid = req[0]
				s["pkt"] = req[1]
			udp.set_dest_address(s.ip, s.port)
			udp.put_packet(s.pkt)
			s.sent += 1
	while udp.get_available_packet_count() > 0:
		var pkt := udp.get_packet()
		for s in _servers:
			if s.got.is_empty() and not s.tid.is_empty():
				var m := Stun.parse(pkt, s.tid)
				if not m.is_empty():
					s.got = m
					break
	var seen: Array = []
	for s in _servers:
		if not s.got.is_empty():
			answers += 1
			seen.append(s.got)
	if answers >= 2 or now - _started >= STUN_WAIT_MS:
		_finish(seen)


func _finish(seen: Array) -> void:
	done = true
	changed = true
	for s in _servers:
		if s.rid >= 0:
			IP.erase_resolve_item(s.rid)
			s.rid = -1
	if seen.is_empty():
		nat = "blocked"
		return
	public_ip = Util.normalize_ip(String(seen[0][0]))
	for m in seen:
		if not public_ports.has(int(m[1])):
			public_ports.append(int(m[1]))
	nat = "strict" if public_ports.size() > 1 else ("easy" if seen.size() > 1 else "unknown")
	_add([public_ip, int(public_ports[-1])], false)


func _add(c: Array, front: bool) -> void:
	for e in cands:
		if e[0] == c[0] and int(e[1]) == int(c[1]):
			return
	if front:
		cands.push_front(c)
	else:
		cands.append(c)
	changed = true


## What a teammate needs to reach us.
func info() -> Dictionary:
	return {"cands": cands.duplicate(true), "nat": nat, "pub": [public_ip, public_ports.duplicate()]}


## Frees the port so the real socket can take it over.
func release() -> void:
	udp.close()


## Removes the router port mapping (in the background) and waits for helper threads.
func cleanup(wait := false) -> void:
	udp.close()
	if _upnp_thread != null:
		if not wait and _upnp_thread.is_alive():
			return
		var r: Dictionary = _upnp_thread.wait_to_finish()
		_upnp_thread = null
		if r.get("ok", false):
			_upnp = r.upnp
	if _upnp != null and _cleanup == null:
		_cleanup = Thread.new()
		_cleanup.start(_unmap.bind(_upnp, port))
		_upnp = null
	if _cleanup != null and (wait or not _cleanup.is_alive()):
		_cleanup.wait_to_finish()
		_cleanup = null


func busy() -> bool:
	return _upnp_thread != null or _cleanup != null


static func _map_port(p: int, known) -> Dictionary:
	var u: UPNP = known
	if u == null:
		u = UPNP.new()
		if u.discover(1000, 2, "InternetGatewayDevice") != UPNP.UPNP_RESULT_SUCCESS:
			return {"ok": false}
		var gw := u.get_gateway()
		if gw == null or not gw.is_valid_gateway():
			return {"ok": false}
	var ip := u.query_external_address()
	# A private "external" address means a second router in front of this one: the mapping
	# wouldn't be reachable from the internet.
	if not Util.is_ipv4(ip) or Util.is_private_ipv4(ip):
		return {"ok": false}
	var r := u.add_port_mapping(p, p, "Godot Co-op", "UDP", 7200)
	if r == UPNP.UPNP_RESULT_ONLY_PERMANENT_LEASE_SUPPORTED:
		r = u.add_port_mapping(p, p, "Godot Co-op", "UDP", 0)
	if r != UPNP.UPNP_RESULT_SUCCESS:
		return {"ok": false}
	return {"ok": true, "ip": ip, "upnp": u}


static func _unmap(u: UPNP, p: int) -> void:
	u.delete_port_mapping(p, "UDP")
