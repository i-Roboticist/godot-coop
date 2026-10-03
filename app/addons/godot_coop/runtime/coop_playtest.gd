extends RefCounted
## Use this in your *game* to auto-connect multiplayer instances during a Godot Co-op playtest.
##
##   const CoopPlaytest = preload("res://addons/godot_coop/runtime/coop_playtest.gd")
##
##   func _ready():
##       if CoopPlaytest.is_active():
##           multiplayer.multiplayer_peer = CoopPlaytest.create_peer()
##
## The host's game becomes the server; everyone else's game connects to it through the co-op
## tunnel. Outside of a co-op playtest is_active() is false and nothing changes.


static func _arg(name: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--" + name + "="):
			return a.substr(name.length() + 3)
	return ""


static func is_active() -> bool:
	return not _arg("coop-role").is_empty()


## "server", "client", or "" when not in a co-op playtest.
static func role() -> String:
	return _arg("coop-role")


static func is_server() -> bool:
	return role() == "server"


static func player_name() -> String:
	var n := _arg("coop-name").replace("_", " ")
	return n if not n.is_empty() else "Player"


static func port() -> int:
	var p := _arg("coop-port")
	return int(p) if p.is_valid_int() else 7777


## For clients: [address, port] to connect to.
static func address() -> Array:
	var a := _arg("coop-connect")
	if a.is_empty() or a.rfind(":") == -1:
		return ["127.0.0.1", port()]
	return [a.substr(0, a.rfind(":")), int(a.substr(a.rfind(":") + 1))]


## Ready-to-use ENet peer: a server on the host, a client everywhere else.
static func create_peer(max_clients := 16) -> ENetMultiplayerPeer:
	var peer := ENetMultiplayerPeer.new()
	if is_server():
		var err := peer.create_server(port(), max_clients)
		if err != OK:
			push_error("Co-op playtest: couldn't start server on port %d (%s)" % [port(), error_string(err)])
	else:
		var a := address()
		var err := peer.create_client(String(a[0]), int(a[1]))
		if err != OK:
			push_error("Co-op playtest: couldn't connect to %s:%d (%s)" % [a[0], a[1], error_string(err)])
	return peer
