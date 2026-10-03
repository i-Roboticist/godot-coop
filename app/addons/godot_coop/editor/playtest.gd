@tool
extends RefCounted
## Synced playtests: one button runs the game on every machine in the session. If your game is
## multiplayer, instances connect to each other automatically - the host's game is the server,
## and every other player's game reaches it through an encrypted tunnel inside the co-op
## connection (so it works even through the relay, with no port forwarding).
##
## Your game reads the details with addons/godot_coop/runtime/coop_playtest.gd.

const Util := preload("res://addons/godot_coop/core/util.gd")
const Net := preload("res://addons/godot_coop/core/net.gd")

var plugin
var auto_connect := true
var active := false
var _run_args := PackedStringArray()
var _game_port := 7777
var _client_udp: PacketPeerUDP = null      # joiner: local proxy the game connects to
var _client_game_addr := ["", 0]
var _host_udps := {}                        # host: peer id -> PacketPeerUDP toward the local game server
var _stopped_since := 0


func _session():
	return plugin.session


func setup(p) -> void:
	plugin = p


func teardown() -> void:
	_close_tunnels()


func play_for_everyone(scene := "") -> void:
	_session().send({"t": "playtest", "action": "start", "scene": scene, "net": auto_connect})


func stop_for_everyone() -> void:
	_session().send({"t": "playtest", "action": "stop"})


func on_message(m: Dictionary) -> void:
	match String(m.get("t", "")):
		"playtest":
			if String(m.get("action", "")) == "stop":
				if EditorInterface.is_playing_scene():
					EditorInterface.stop_playing_scene()
				_close_tunnels()
				active = false
				return
			_start(m)
		"tun":
			_on_tunnel(m)


func _start(m: Dictionary) -> void:
	prepare(m)
	if EditorInterface.is_playing_scene():
		EditorInterface.stop_playing_scene()
	var scene := String(m.get("scene", ""))
	if scene.is_empty():
		EditorInterface.play_main_scene()
	elif ResourceLoader.exists(scene):
		EditorInterface.play_custom_scene(scene)
	var by := int(m.get("by", 0))
	if by != _session().my_pid:
		plugin.toast("%s started a playtest for everyone." % _session().peer_name(by), 0)


## Sets up the game's command line and the tunnel for a playtest.
func prepare(m: Dictionary) -> void:
	var s = _session()
	_game_port = int(m.get("game_port", 7777))
	_close_tunnels()
	_run_args = PackedStringArray()
	var net_on := bool(m.get("net", true))
	_run_args.append("--coop-name=" + String(s.profile.get("name", "Player")).replace(" ", "_"))
	_run_args.append("--coop-peer=%d" % s.my_pid)
	if net_on:
		if s.is_host:
			_run_args.append("--coop-role=server")
			_run_args.append("--coop-port=%d" % _game_port)
		else:
			_client_udp = PacketPeerUDP.new()
			if _client_udp.bind(0, "127.0.0.1") == OK:
				_run_args.append("--coop-role=client")
				_run_args.append("--coop-connect=127.0.0.1:%d" % _client_udp.get_local_port())
			else:
				_client_udp = null
	active = true
	_stopped_since = Util.now_ms() + 60000


## EditorPlugin._run_scene hook: add our arguments to the game's command line.
func run_args(args: PackedStringArray) -> PackedStringArray:
	if not active or _run_args.is_empty():
		return args
	var out := args.duplicate()
	if not out.has("--") and not out.has("++"):
		out.append("--")
	out.append_array(_run_args)
	return out


func _on_tunnel(m: Dictionary) -> void:
	var d = m.get("d")
	if not (d is PackedByteArray) or d.size() > 65000:
		return
	var s = _session()
	if s.is_host:
		var from := int(m.get("from", 0))
		var udp: PacketPeerUDP = _host_udps.get(from)
		if udp == null:
			udp = PacketPeerUDP.new()
			udp.connect_to_host("127.0.0.1", _game_port)
			_host_udps[from] = udp
		udp.put_packet(d)
	elif _client_udp != null and _client_game_addr[1] != 0:
		_client_udp.set_dest_address(_client_game_addr[0], _client_game_addr[1])
		_client_udp.put_packet(d)


func process() -> void:
	var s = _session()
	if _client_udp != null:
		var n := 0
		while _client_udp.get_available_packet_count() > 0 and n < 256:
			n += 1
			var pkt := _client_udp.get_packet()
			_client_game_addr = [_client_udp.get_packet_ip(), _client_udp.get_packet_port()]
			s.send({"t": "tun", "d": pkt}, Net.CH_TUNNEL, false)
	for pid in _host_udps:
		var udp: PacketPeerUDP = _host_udps[pid]
		var n := 0
		while udp.get_available_packet_count() > 0 and n < 256:
			n += 1
			s.send({"t": "tun", "to": pid, "d": udp.get_packet()}, Net.CH_TUNNEL, false)
	# The game takes a moment to start; once it has stopped for a few seconds, close the tunnel.
	if active and not EditorInterface.is_playing_scene():
		if _stopped_since == 0:
			_stopped_since = Util.now_ms()
		elif Util.now_ms() - _stopped_since > 3000:
			active = false
			_close_tunnels()
	elif active:
		_stopped_since = 0


func _close_tunnels() -> void:
	if _client_udp != null:
		_client_udp.close()
		_client_udp = null
	for pid in _host_udps:
		_host_udps[pid].close()
	_host_udps.clear()
