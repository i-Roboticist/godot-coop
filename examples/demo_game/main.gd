extends Node2D
## If this runs as part of a Godot Co-op "Play for everyone" playtest, every player's game
## connects to the host's automatically (see addons/godot_coop/runtime/coop_playtest.gd).

const HELPER := "res://addons/godot_coop/runtime/coop_playtest.gd"

var _coop = null


func _ready() -> void:
	if ResourceLoader.exists(HELPER):
		_coop = load(HELPER)
	if _coop != null and _coop.is_active():
		multiplayer.multiplayer_peer = _coop.create_peer()
		multiplayer.peer_connected.connect(_on_peers_changed)
		multiplayer.peer_disconnected.connect(_on_peers_changed)
	_update_label()


func _on_peers_changed(_id: int) -> void:
	_update_label()


func _update_label() -> void:
	if _coop != null and _coop.is_active():
		$Label.text = "%s (%s) · players connected: %d" % [_coop.player_name(), _coop.role(), multiplayer.get_peers().size() + 1]
	else:
		$Label.text = "Godot Co-op demo. Move with the arrow keys."
